//
//  BenchmarkProfiler.swift
//  test
//
//  Phase 7 — drives REAL inference through the shared VisionInferenceEngine on
//  live ARKit frames and records what actually happened. It never synthesizes a
//  number: every statistic comes from VisionInferenceEngine.instrumentationTap
//  samples, ARFrame delivery timestamps, and ProcessInfo thermal state.
//
//  Lifecycle guarantees:
//   • The engine configuration (model, compute units, rate, threshold, on/off)
//     is captured before a run and restored on finish, cancel, failure,
//     backgrounding, AR interruption, or leaving the Bench tab.
//   • Taps carry only numbers; no ARFrame or pixel buffer is retained.
//   • Storage is bounded (per-variant sample cap, fixed-size graph buffer).
//

import Foundation
import Observation
import QuartzCore

@MainActor
@Observable
final class BenchmarkProfiler {
    enum Phase: Equatable {
        case idle
        case loading(ModelVariant)
        case warmingUp(ModelVariant)
        case measuring(ModelVariant)
        case finished
        case cancelled(String)
        case failed(String)
    }

    static let graphCapacity = 360
    /// Give up on a variant whose model doesn't load / warm up in this time.
    static let loadTimeout: Double = 45
    static let warmupTimeout: Double = 20

    private(set) var phase: Phase = .idle
    private(set) var plan: BenchmarkPlan?
    private(set) var results: [VariantBenchmarkResult] = []
    private(set) var graph = BoundedBuffer<FrameTimePoint>(capacity: BenchmarkProfiler.graphCapacity)
    /// 0...1 across the whole plan (measurement windows only).
    private(set) var progress: Double = 0
    private(set) var currentWindowElapsed: Double = 0
    private(set) var liveSampleCount = 0
    private(set) var liveLastEndToEndMs: Double?
    private(set) var liveThermal: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState

    var isRunning: Bool {
        switch phase {
        case .loading, .warmingUp, .measuring: return true
        default: return false
        }
    }

    private unowned let vision: VisionInferenceEngine
    private weak var ar: ARSessionManager?
    @ObservationIgnored private var savedConfiguration: VisionInferenceEngine.Configuration?
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var accumulator: VariantAccumulator?
    @ObservationIgnored private var runStart: Double = 0
    @ObservationIgnored private var nextGraphId = 0
    @ObservationIgnored private var currentLoadMs: Double?
    @ObservationIgnored private var currentCompute = ""

    init(vision: VisionInferenceEngine) { self.vision = vision }

    func attach(ar: ARSessionManager) { self.ar = ar }

    // MARK: - Control

    func start(_ plan: BenchmarkPlan) {
        guard !isRunning else { return }
        guard let ar, ar.supportsWorldTracking else {
            phase = .failed("Benchmarks need a physical ARKit device (live camera frames).")
            return
        }
        guard vision.sdkAvailable else {
            phase = .failed("UltralyticsYOLO package unavailable — nothing real to measure.")
            return
        }
        if ar.runState != .running { ar.start() }

        self.plan = plan
        results = []
        graph.removeAll()
        progress = 0
        nextGraphId = 0
        runStart = CACurrentMediaTime()
        savedConfiguration = vision.captureConfiguration()
        installTaps()
        runTask = Task { [weak self] in await self?.run(plan) }
    }

    /// Stops a run, keeps a partial result for the variant in progress (marked
    /// cancelled), and restores the engine configuration.
    func cancel(reason: String) {
        guard isRunning else { return }
        runTask?.cancel()
        runTask = nil
        finishCurrentVariant(outcome: .cancelled(reason))
        teardown()
        phase = .cancelled(reason)
    }

    // MARK: - Run

    private func run(_ plan: BenchmarkPlan) async {
        vision.targetHz = plan.targetHz
        if !vision.isEnabled { vision.start() }
        let measuredTotal = plan.totalSeconds

        for (index, variant) in plan.variants.enumerated() {
            guard !Task.isCancelled else { return }

            // 1. Load (measured by the engine; nil if it was already resident).
            phase = .loading(variant)
            vision.switchModel(to: variant)
            // switchModel resolves synchronously to .loaded only when already resident.
            let wasCached = vision.loadState == .loaded
            currentCompute = vision.computeOption.effectiveDescription
            let loadOK = await waitForLoad(variant)
            guard !Task.isCancelled else { return }
            if let failure = loadOK {
                results.append(.failed(variant, reason: failure, computeDescription: currentCompute))
                continue
            }
            currentLoadMs = wasCached ? nil : vision.lastLoadMs[variant]

            // 2. Warm up, then measure a fixed window.
            accumulator = VariantAccumulator(variant: variant, warmupSamples: plan.warmupSamples,
                                             nominalFrameInterval: 1.0 / Double(ar?.nominalFramesPerSecond ?? 60))
            phase = .warmingUp(variant)
            let warmStart = CACurrentMediaTime()
            while !Task.isCancelled {
                if let reason = interruptionReason() { cancel(reason: reason); return }
                accumulator?.recordThermal(ProcessInfo.processInfo.thermalState)
                liveThermal = ProcessInfo.processInfo.thermalState
                let now = CACurrentMediaTime()
                if let start = accumulator?.measurementStart {
                    if case .warmingUp = phase { phase = .measuring(variant) }
                    currentWindowElapsed = now - start
                    progress = min(1, (Double(index) * plan.secondsPerVariant + currentWindowElapsed) / measuredTotal)
                    if currentWindowElapsed >= plan.secondsPerVariant { break }
                } else if now - warmStart > Self.warmupTimeout {
                    finishCurrentVariant(outcome: .failed("No completed inferences within \(Int(Self.warmupTimeout)) s"))
                    break
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard !Task.isCancelled else { return }
            if accumulator != nil { finishCurrentVariant(outcome: .completed) }
        }

        progress = 1
        teardown()
        phase = .finished
    }

    /// Returns nil once loaded, or a failure description.
    private func waitForLoad(_ variant: ModelVariant) async -> String? {
        let deadline = CACurrentMediaTime() + Self.loadTimeout
        while !Task.isCancelled {
            switch vision.loadState {
            case .loaded: return nil
            case .missing: return "Model file not bundled"
            case .sdkUnavailable: return "SDK unavailable"
            case .failed(let message): return "Load failed: \(message)"
            case .loading, .notLoaded: break
            }
            if CACurrentMediaTime() > deadline { return "Load timed out" }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return "Cancelled"
    }

    /// Measurements across an interruption would be meaningless — stop instead.
    private func interruptionReason() -> String? {
        guard let ar else { return "AR session unavailable" }
        switch ar.runState {
        case .running: return nil
        case .interrupted: return "AR session interrupted"
        case .paused: return "AR session paused"
        case .idle, .unsupported: return "AR session stopped"
        }
    }

    private func finishCurrentVariant(outcome: BenchmarkOutcome) {
        guard let acc = accumulator else { return }
        let window = acc.measurementStart.map { CACurrentMediaTime() - $0 } ?? 0
        results.append(acc.summary(windowSeconds: window, loadMs: currentLoadMs,
                                   computeDescription: currentCompute, outcome: outcome))
        accumulator = nil
        currentLoadMs = nil
        liveSampleCount = 0
        liveLastEndToEndMs = nil
        currentWindowElapsed = 0
    }

    // MARK: - Taps

    private func installTaps() {
        vision.instrumentationTap = { [weak self] event in self?.handle(event) }
        ar?.frameTimestampTap = { [weak self] timestamp in self?.accumulator?.recordFrame(timestamp: timestamp) }
    }

    private func teardown() {
        vision.instrumentationTap = nil
        ar?.frameTimestampTap = nil
        if let saved = savedConfiguration { vision.restore(saved) }
        savedConfiguration = nil
        accumulator = nil
    }

    private func handle(_ event: InferenceTickEvent) {
        guard accumulator != nil else { return }
        let wasMeasuring = accumulator?.isMeasuring ?? false
        let counted = accumulator?.ingest(event) ?? false
        guard case .completed(let sample) = event, sample.variant == accumulator?.variant else { return }
        graph.append(FrameTimePoint(id: nextGraphId, t: sample.completedAt - runStart,
                                    endToEndMs: sample.endToEndMs, inferenceMs: sample.inferenceMs,
                                    variant: sample.variant, isWarmup: !wasMeasuring && !counted))
        nextGraphId += 1
        if counted {
            liveSampleCount += 1
            liveLastEndToEndMs = sample.endToEndMs
        }
    }
}
