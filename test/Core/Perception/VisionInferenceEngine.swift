//
//  VisionInferenceEngine.swift
//  test
//
//  Phase 1 — runs real Ultralytics YOLO26 instance segmentation on the live
//  ARKit frame (ARFrame.capturedImage, as a zero-copy CIImage). Acts as the
//  model manager: selection, load state, compute units, confidence threshold,
//  mask opacity, inference frequency, and ACTUAL measured latency.
//
//  The Ultralytics usage is wrapped in `#if canImport(UltralyticsYOLO)` so the
//  project keeps building before the Swift Package is added in Xcode. Until then
//  the engine reports `.sdkUnavailable` instead of faking detections.
//
//  Bounded, single-in-flight: we never queue a backlog of stale frames — each
//  tick reads the LATEST frame and skips if an inference is already running.
//
//  Phase 7 instrumentation: an optional `instrumentationTap` receives one event
//  per loop tick (a real completed inference, or why none ran). Events carry
//  only numbers — never the ARFrame or pixel buffers. The loop paces
//  start-to-start so `targetHz` is the rate actually requested.
//

import CoreGraphics
import CoreImage
import Foundation
import Observation
import QuartzCore

#if canImport(UltralyticsYOLO)
import UltralyticsYOLO
#endif

@MainActor
@Observable
final class VisionInferenceEngine {

    // MARK: - Observable configuration / state
    var selectedVariant: ModelVariant = .nano
    var computeOption: ComputeUnitOption = .cpuAndNeuralEngine   // prefer ANE
    var confidenceThreshold: Float = 0.35
    var maskOpacity: Double = 0.5
    /// Target inference rate; actual rate adapts to latency/thermals.
    var targetHz: Double = 10
    var isEnabled: Bool = false

    private(set) var loadState: ModelLoadState = .notLoaded
    private(set) var modelPresence: [ModelVariant: Bool] = [:]
    private(set) var latestResult: DetectionResult?
    /// Exactly one source snapshot, paired with latestResult for synchronized
    /// RGB/depth/pose fusion. Never retain a queue of ARKit frame buffers.
    private(set) var latestFrame: SensorFrame?
    private(set) var resultSessionGeneration: Int = -1
    private(set) var measuredInferenceMs: Double = 0
    private(set) var measuredEndToEndMs: Double = 0
    private(set) var measuredRateHz: Double = 0
    /// Measured wall-clock load time per variant (first load this app session).
    private(set) var lastLoadMs: [ModelVariant: Double] = [:]

    /// Benchmark/inspector tap. Called on the main actor; must stay cheap.
    @ObservationIgnored var instrumentationTap: ((InferenceTickEvent) -> Void)?

    // MARK: - Private
    private weak var provider: ARSensorProvider?
    private var loopTask: Task<Void, Never>?
    private var isInferring = false
    private var lastResultTime: TimeInterval = 0

    /// Loaded models are keyed by variant AND the SDK acceleration flag, so changing
    /// compute units really reloads instead of silently reusing the old config.
    private struct ModelKey: Hashable { let variant: ModelVariant; let useGpu: Bool }

    #if canImport(UltralyticsYOLO)
    private var models: [ModelKey: YOLO] = [:]
    /// In-flight loads. The SDK loads asynchronously; if we don't hold a strong
    /// reference to the instance it can be deallocated and the completion never
    /// fires — leaving the UI stuck on "Loading" forever.
    private var pending: [ModelKey: YOLO] = [:]
    #endif

    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    init() {
        refreshModelPresence()
    }

    func attach(provider: ARSensorProvider) { self.provider = provider }

    // MARK: - Model presence / loading

    /// Checks which models are actually bundled (compiled to .mlmodelc at build).
    func refreshModelPresence() {
        for variant in ModelVariant.allCases {
            let present = Bundle.main.url(forResource: variant.rawValue, withExtension: "mlmodelc") != nil
                || Bundle.main.url(forResource: variant.rawValue, withExtension: "mlpackage") != nil
            modelPresence[variant] = present
        }
    }

    var sdkAvailable: Bool {
        #if canImport(UltralyticsYOLO)
        return true
        #else
        return false
        #endif
    }

    /// Loads (or re-loads) the selected model. Safe to call repeatedly.
    func loadSelectedModel() {
        let variant = selectedVariant
        guard sdkAvailable else { loadState = .sdkUnavailable; return }
        guard modelPresence[variant] == true else { loadState = .missing; return }

        #if canImport(UltralyticsYOLO)
        let key = currentKey
        if models[key] != nil { loadState = .loaded; return }
        if pending[key] != nil { loadState = .loading; return }   // already loading this config
        loadState = .loading
        let loadStart = CACurrentMediaTime()
        let instance = YOLO(variant.rawValue, task: .segment, useGpu: key.useGpu) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.pending[key] = nil
                switch result {
                case .success(let model):
                    self.models[key] = model
                    self.lastLoadMs[variant] = (CACurrentMediaTime() - loadStart) * 1000
                    if self.currentKey == key { self.loadState = .loaded }
                case .failure(let error):
                    if self.currentKey == key { self.loadState = .failed(error.localizedDescription) }
                }
            }
        }
        // Retain the in-flight instance so its async load can actually finish.
        pending[key] = instance
        #endif
    }

    private var currentKey: ModelKey { ModelKey(variant: selectedVariant, useGpu: computeOption.sdkUseGpu) }

    // MARK: - Configuration snapshot (restored after profiling)

    struct Configuration: Equatable {
        var variant: ModelVariant
        var computeOption: ComputeUnitOption
        var targetHz: Double
        var confidenceThreshold: Float
        var isEnabled: Bool
    }

    func captureConfiguration() -> Configuration {
        Configuration(variant: selectedVariant, computeOption: computeOption, targetHz: targetHz,
                      confidenceThreshold: confidenceThreshold, isEnabled: isEnabled)
    }

    func restore(_ c: Configuration) {
        targetHz = c.targetHz
        confidenceThreshold = c.confidenceThreshold
        computeOption = c.computeOption
        if selectedVariant != c.variant {
            switchModel(to: c.variant)
        } else {
            loadSelectedModel()
        }
        if !c.isEnabled { stop() }
    }

    // MARK: - Run loop

    func start() {
        guard !isEnabled else { return }
        isEnabled = true
        loadSelectedModel()
        loopTask = Task { [weak self] in await self?.runLoop() }
    }

    func stop() {
        isEnabled = false
        loopTask?.cancel()
        loopTask = nil
        clearResults()
    }

    func clearResults() {
        latestResult = nil
        latestFrame = nil
    }

    /// Switches model at runtime; any in-flight inference finishes and is discarded.
    func switchModel(to variant: ModelVariant) {
        selectedVariant = variant
        clearResults()
        loadSelectedModel()
    }

    private func runLoop() async {
        while !Task.isCancelled && isEnabled {
            let interval = max(0.03, 1.0 / max(1, targetHz))
            let started = CACurrentMediaTime()
            await tick(interval: interval)
            // Start-to-start pacing; always yield briefly so we never busy-spin.
            let elapsed = CACurrentMediaTime() - started
            try? await Task.sleep(for: .seconds(max(0.005, interval - elapsed)))
        }
    }

    private func report(_ event: InferenceTickEvent) { instrumentationTap?(event) }

    private func tick(interval: Double) async {
        guard !isInferring else { return }
        if let provider, resultSessionGeneration != provider.sessionGeneration {
            clearResults()
        }
        if let frame = latestFrame,
           !ARSensorProvider.isFresh(timestamp: frame.timestamp, now: CACurrentMediaTime()) {
            clearResults()
        }
        guard sdkAvailable else { loadState = .sdkUnavailable; report(.notReady(.sdkUnavailable)); return }
        guard loadState == .loaded else { report(.notReady(.modelNotLoaded)); return }
        guard let provider, provider.isRunning else {
            clearResults(); report(.notReady(.sessionNotRunning)); return
        }
        guard let frame = provider.cameraSnapshot() else {
            clearResults(); report(.notReady(.noFrame)); return
        }
        let generation = provider.sessionGeneration
        isInferring = true
        defer { isInferring = false }

        let variant = selectedVariant
        let threshold = confidenceThreshold
        let startWall = CACurrentMediaTime()

        #if canImport(UltralyticsYOLO)
        guard let model = models[currentKey] else { report(.notReady(.modelNotLoaded)); return }
        // Zero-copy from the ARFrame; orient to match the portrait display.
        let ciImage = CIImage(cvPixelBuffer: frame.capturedImage).oriented(.right)
        let result = await runInference(model: model, image: ciImage)
        let detection = convert(result, frame: frame, variant: variant,
                                threshold: threshold, startWall: startWall)
        let cycle = CACurrentMediaTime() - startWall
        report(.completed(InferenceSample(
            variant: variant, completedAt: CACurrentMediaTime(), frameTimestamp: detection.frameTimestamp,
            preprocessMs: detection.preprocessMs, inferenceMs: detection.inferenceMs,
            postprocessMs: detection.postprocessMs, endToEndMs: detection.endToEndMs,
            captureToResultMs: detection.captureToResultMs, objectCount: detection.objects.count,
            skippedSlots: BenchmarkMath.skippedInferenceSlots(cycleSeconds: cycle, targetInterval: interval))))
        // A model switched away mid-flight: the measurement is real, the overlay is stale.
        guard !Task.isCancelled, isEnabled, variant == selectedVariant,
              provider.isRunning, provider.sessionGeneration == generation,
              ARSensorProvider.isFresh(timestamp: frame.timestamp, now: CACurrentMediaTime()) else { return }
        latestFrame = frame
        resultSessionGeneration = generation
        publish(detection)
        #else
        _ = (variant, threshold, startWall, frame)
        #endif
    }

    private func publish(_ detection: DetectionResult) {
        latestResult = detection
        measuredInferenceMs = detection.inferenceMs
        measuredEndToEndMs = detection.endToEndMs
        let now = CACurrentMediaTime()
        if lastResultTime > 0 {
            let dt = now - lastResultTime
            if dt > 0 { measuredRateHz = measuredRateHz * 0.8 + (1.0 / dt) * 0.2 }
        }
        lastResultTime = now
    }

    #if canImport(UltralyticsYOLO)
    /// Runs the (synchronous) SDK inference off the main actor.
    private nonisolated func runInference(model: YOLO, image: CIImage) async -> YOLOResult {
        await Task.detached(priority: .userInitiated) {
            model(image)
        }.value
    }

    /// Maps the SDK result into our SDK-agnostic DetectionResult, applying the
    /// confidence threshold and measuring true end-to-end latency.
    private func convert(_ r: YOLOResult, frame: SensorFrame, variant: ModelVariant,
                         threshold: Float, startWall: TimeInterval) -> DetectionResult {
        var objects: [DetectedObject] = []
        for (i, box) in r.boxes.enumerated() where box.conf >= threshold {
            objects.append(DetectedObject(
                id: i,
                label: box.cls,
                confidence: box.conf,
                boxNormalized: box.xywhn,
                mask: nil))   // per-instance masks assembled in Phase 3
        }
        let now = CACurrentMediaTime()
        // Known YOLO26 Core ML pitfall: prototype mask tensor all-zero → no masks.
        let degenerate = !r.boxes.isEmpty && r.masks == nil
        return DetectionResult(
            objects: objects,
            classNames: r.names,
            combinedMask: r.masks?.combinedMask,
            frameTimestamp: frame.timestamp,
            preprocessMs: r.preMs,
            inferenceMs: r.inferenceMs,
            postprocessMs: r.postMs,
            endToEndMs: (now - startWall) * 1000,
            captureToResultMs: (now - frame.timestamp) * 1000,
            modelVariant: variant,
            maskDegenerate: degenerate)
    }
    #endif
}
