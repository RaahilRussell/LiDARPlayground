//
//  BenchmarkStats.swift
//  test
//
//  Phase 7 — pure, deterministic statistics behind the Benchmarks tab. Nothing
//  here touches ARKit, Core ML, or the clock: inputs are measured numbers fed in
//  by the profiler, so every figure on screen traces back to a real measurement
//  and every rule below is fixture-tested (testTests).
//
//  Definitions (also shown in the UI):
//   • Missed camera frames — inferred from gaps between consecutive ARFrame
//     timestamps. A gap longer than 1.5 × the nominal frame interval counts as
//     round(gap / nominal) − 1 missed frames. ARKit does not report drops
//     directly; this is an inference from delivery timestamps.
//   • Skipped inference slots — target-rate slots in which no inference could
//     start because the previous (single in-flight) inference was still running:
//     floor(inferenceCycle / targetInterval) − 1, clamped at 0.
//   • Not-ready ticks — loop ticks where no inference ran (model not loaded,
//     session not running, no frame). Counted separately, never as latency.
//

import Foundation

// MARK: - Bounded ring buffer

/// Fixed-capacity FIFO. Appending past capacity overwrites the oldest element, so
/// graph/history storage can never grow unbounded.
nonisolated struct BoundedBuffer<Element> {
    let capacity: Int
    private var storage: [Element] = []
    private var head = 0
    /// Total appends ever, including overwritten ones.
    private(set) var totalAppended = 0

    init(capacity: Int) {
        precondition(capacity > 0, "BoundedBuffer capacity must be positive")
        self.capacity = capacity
        storage.reserveCapacity(capacity)
    }

    mutating func append(_ element: Element) {
        totalAppended += 1
        if storage.count < capacity {
            storage.append(element)
        } else {
            storage[head] = element
            head = (head + 1) % capacity
        }
    }

    /// Oldest → newest.
    var elements: [Element] {
        guard storage.count == capacity, head != 0 else { return storage }
        return Array(storage[head...] + storage[..<head])
    }

    var count: Int { storage.count }
    var isEmpty: Bool { storage.isEmpty }
    var last: Element? { storage.isEmpty ? nil : storage[(head + storage.count - 1) % storage.count] }

    mutating func removeAll() {
        storage.removeAll(keepingCapacity: true)
        head = 0
        totalAppended = 0
    }
}

extension BoundedBuffer: Sendable where Element: Sendable {}

// MARK: - Latency statistics

nonisolated struct LatencyStats: Equatable, Sendable {
    let count: Int
    let mean: Double
    let min: Double
    let max: Double
    let p50: Double
    let p95: Double
    let p99: Double
    /// Population standard deviation.
    let stdDev: Double

    /// Returns nil when there are no finite samples — never a fabricated zero.
    init?(samples: [Double]) {
        let finite = samples.filter { $0.isFinite }.sorted()
        guard let first = finite.first, let lastValue = finite.last else { return nil }
        let n = Double(finite.count)
        let mean = finite.reduce(0, +) / n
        let variance = finite.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / n
        self.count = finite.count
        self.mean = mean
        self.min = first
        self.max = lastValue
        self.p50 = Self.percentile(sorted: finite, 0.50)
        self.p95 = Self.percentile(sorted: finite, 0.95)
        self.p99 = Self.percentile(sorted: finite, 0.99)
        self.stdDev = variance.squareRoot()
    }

    /// Linear interpolation between closest ranks (the common "R-7"/NumPy default).
    static func percentile(sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return .nan }
        let clamped = Swift.min(1, Swift.max(0, p))
        let rank = clamped * Double(sorted.count - 1)
        let lo = Int(rank.rounded(.down))
        let hi = Swift.min(sorted.count - 1, lo + 1)
        let frac = rank - Double(lo)
        return sorted[lo] + (sorted[hi] - sorted[lo]) * frac
    }
}

// MARK: - Frame cadence (missed camera frames)

nonisolated struct FrameCadenceCounter: Sendable {
    static let gapFactor = 1.5

    /// Seconds between frames at the configured video format rate (e.g. 1/60).
    let nominalInterval: Double
    private(set) var framesDelivered = 0
    private(set) var missedFrames = 0
    private(set) var longestGap: Double = 0
    private var lastTimestamp: Double?

    init(nominalInterval: Double) { self.nominalInterval = nominalInterval }

    mutating func record(timestamp: Double) {
        framesDelivered += 1
        defer { lastTimestamp = timestamp }
        guard let last = lastTimestamp else { return }
        let gap = timestamp - last
        guard gap > 0 else { return }   // duplicate or out-of-order: not a gap
        longestGap = Swift.max(longestGap, gap)
        missedFrames += Self.missedSlots(gap: gap, nominal: nominalInterval)
    }

    static func missedSlots(gap: Double, nominal: Double) -> Int {
        guard nominal > 0, gap.isFinite, gap > nominal * gapFactor else { return 0 }
        return Swift.max(1, Int((gap / nominal).rounded()) - 1)
    }
}

nonisolated enum BenchmarkMath {
    static func skippedInferenceSlots(cycleSeconds: Double, targetInterval: Double) -> Int {
        guard targetInterval > 0, cycleSeconds.isFinite, cycleSeconds > targetInterval else { return 0 }
        return Swift.max(0, Int((cycleSeconds / targetInterval).rounded(.down)) - 1)
    }

    /// Achieved result rate from first/last completion times: (n − 1) / span.
    static func achievedRateHz(sampleCount: Int, firstTime: Double?, lastTime: Double?) -> Double? {
        guard sampleCount >= 2, let firstTime, let lastTime, lastTime > firstTime else { return nil }
        return Double(sampleCount - 1) / (lastTime - firstTime)
    }
}

// MARK: - Thermal tracking

nonisolated struct ThermalTracker: Sendable {
    private(set) var start: ProcessInfo.ThermalState?
    private(set) var latest: ProcessInfo.ThermalState?
    private(set) var worst: ProcessInfo.ThermalState?
    private(set) var transitions = 0

    mutating func record(_ state: ProcessInfo.ThermalState) {
        if start == nil { start = state }
        if let latest, latest != state { transitions += 1 }
        latest = state
        if let w = worst, w.rawValue >= state.rawValue { return }
        worst = state
    }
}

// MARK: - Instrumentation events (emitted by VisionInferenceEngine)

nonisolated enum NotReadyReason: String, CaseIterable, Sendable {
    case sdkUnavailable = "SDK unavailable"
    case modelNotLoaded = "Model not loaded"
    case sessionNotRunning = "AR session not running"
    case noFrame = "No frame"
}

/// One real, completed inference. All durations are measured, in milliseconds.
nonisolated struct InferenceSample: Sendable {
    var variant: ModelVariant
    /// Host clock (CACurrentMediaTime) when the result was ready.
    var completedAt: Double
    var frameTimestamp: Double
    var preprocessMs: Double
    var inferenceMs: Double
    var postprocessMs: Double
    var endToEndMs: Double
    var captureToResultMs: Double
    var objectCount: Int
    var skippedSlots: Int
}

nonisolated enum InferenceTickEvent: Sendable {
    case completed(InferenceSample)
    case notReady(NotReadyReason)
}

// MARK: - Plan + per-variant accumulation

nonisolated struct BenchmarkPlan: Equatable, Sendable {
    var name: String
    var variants: [ModelVariant]
    var secondsPerVariant: Double
    /// First N completed inferences per variant are excluded (ANE specialization, caches).
    var warmupSamples: Int
    /// Requested inference rate; 30 Hz ≈ "as fast as single-in-flight allows".
    var targetHz: Double

    var totalSeconds: Double { secondsPerVariant * Double(variants.count) }

    static let compareAll = BenchmarkPlan(name: "Compare n/s/m (3 × 20 s)", variants: ModelVariant.allCases,
                                          secondsPerVariant: 20, warmupSamples: 5, targetHz: 30)
    static func profile(_ variant: ModelVariant) -> BenchmarkPlan {
        BenchmarkPlan(name: "Profile \(variant.displayName) (60 s)", variants: [variant],
                      secondsPerVariant: 60, warmupSamples: 5, targetHz: 30)
    }
}

nonisolated struct VariantAccumulator: Sendable {
    /// Hard cap on stored samples (60 s × 30 Hz = 1800, so this is generous).
    static let maxSamples = 4096

    let variant: ModelVariant
    let warmupSamples: Int
    private(set) var warmupDiscarded = 0
    private(set) var measurementStart: Double?
    private(set) var inferenceMs: [Double] = []
    private(set) var endToEndMs: [Double] = []
    private(set) var captureToResultMs: [Double] = []
    private(set) var objectTotal = 0
    private(set) var skippedSlots = 0
    private(set) var samplesOverCap = 0
    private(set) var foreignSamplesIgnored = 0
    private(set) var notReady: [NotReadyReason: Int] = [:]
    private(set) var firstMeasuredAt: Double?
    private(set) var lastMeasuredAt: Double?
    private(set) var cadence: FrameCadenceCounter
    private(set) var thermal = ThermalTracker()

    init(variant: ModelVariant, warmupSamples: Int, nominalFrameInterval: Double) {
        self.variant = variant
        self.warmupSamples = max(0, warmupSamples)
        self.cadence = FrameCadenceCounter(nominalInterval: nominalFrameInterval)
    }

    var isMeasuring: Bool { measurementStart != nil }
    var measuredCount: Int { inferenceMs.count }

    /// Returns true if the sample was counted toward statistics.
    @discardableResult
    mutating func ingest(_ event: InferenceTickEvent) -> Bool {
        switch event {
        case .notReady(let reason):
            notReady[reason, default: 0] += 1
            return false
        case .completed(let s):
            guard s.variant == variant else { foreignSamplesIgnored += 1; return false }
            if measurementStart == nil {
                if warmupDiscarded < warmupSamples { warmupDiscarded += 1 }
                if warmupDiscarded >= warmupSamples { measurementStart = s.completedAt }
                // The sample that completes warm-up only opens the window.
                if warmupSamples > 0 { return false }
            }
            guard inferenceMs.count < Self.maxSamples else { samplesOverCap += 1; return false }
            inferenceMs.append(s.inferenceMs)
            endToEndMs.append(s.endToEndMs)
            captureToResultMs.append(s.captureToResultMs)
            objectTotal += s.objectCount
            skippedSlots += s.skippedSlots
            if firstMeasuredAt == nil { firstMeasuredAt = s.completedAt }
            lastMeasuredAt = s.completedAt
            return true
        }
    }

    /// Camera frame timestamps only count inside the measurement window.
    mutating func recordFrame(timestamp: Double) {
        guard isMeasuring else { return }
        cadence.record(timestamp: timestamp)
    }

    mutating func recordThermal(_ state: ProcessInfo.ThermalState) { thermal.record(state) }

    func summary(windowSeconds: Double, loadMs: Double?, computeDescription: String,
                 outcome: VariantBenchmarkResult.Outcome) -> VariantBenchmarkResult {
        VariantBenchmarkResult(
            variant: variant,
            outcome: outcome,
            computeDescription: computeDescription,
            loadMs: loadMs,
            windowSeconds: windowSeconds,
            warmupDiscarded: warmupDiscarded,
            measuredSamples: inferenceMs.count,
            inference: LatencyStats(samples: inferenceMs),
            endToEnd: LatencyStats(samples: endToEndMs),
            captureToResult: LatencyStats(samples: captureToResultMs),
            achievedHz: BenchmarkMath.achievedRateHz(sampleCount: inferenceMs.count,
                                                     firstTime: firstMeasuredAt, lastTime: lastMeasuredAt),
            meanObjects: inferenceMs.isEmpty ? nil : Double(objectTotal) / Double(inferenceMs.count),
            skippedSlots: skippedSlots,
            notReadyTicks: notReady.values.reduce(0, +),
            cameraFramesDelivered: cadence.framesDelivered,
            cameraFramesMissed: cadence.missedFrames,
            longestFrameGapMs: cadence.framesDelivered > 1 ? cadence.longestGap * 1000 : nil,
            thermalStart: thermal.start,
            thermalEnd: thermal.latest,
            thermalWorst: thermal.worst)
    }
}

nonisolated enum BenchmarkOutcome: Equatable, Sendable {
    case completed
    case cancelled(String)
    case failed(String)
}

nonisolated struct VariantBenchmarkResult: Identifiable, Sendable {
    typealias Outcome = BenchmarkOutcome

    var id: String { variant.rawValue }
    let variant: ModelVariant
    let outcome: Outcome
    let computeDescription: String
    /// nil when the model was already cached in memory (no load was measured).
    let loadMs: Double?
    let windowSeconds: Double
    let warmupDiscarded: Int
    let measuredSamples: Int
    let inference: LatencyStats?
    let endToEnd: LatencyStats?
    let captureToResult: LatencyStats?
    let achievedHz: Double?
    let meanObjects: Double?
    let skippedSlots: Int
    let notReadyTicks: Int
    let cameraFramesDelivered: Int
    let cameraFramesMissed: Int
    let longestFrameGapMs: Double?
    let thermalStart: ProcessInfo.ThermalState?
    let thermalEnd: ProcessInfo.ThermalState?
    let thermalWorst: ProcessInfo.ThermalState?

    static func failed(_ variant: ModelVariant, reason: String, computeDescription: String) -> VariantBenchmarkResult {
        VariantAccumulator(variant: variant, warmupSamples: 0, nominalFrameInterval: 1.0 / 60)
            .summary(windowSeconds: 0, loadMs: nil, computeDescription: computeDescription,
                     outcome: .failed(reason))
    }
}

/// A point on the bounded frame-time graph.
nonisolated struct FrameTimePoint: Identifiable, Sendable {
    let id: Int
    /// Seconds since the profile run started.
    let t: Double
    let endToEndMs: Double
    let inferenceMs: Double
    let variant: ModelVariant
    let isWarmup: Bool
}
