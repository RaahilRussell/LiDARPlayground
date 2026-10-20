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
    private(set) var measuredInferenceMs: Double = 0
    private(set) var measuredEndToEndMs: Double = 0
    private(set) var measuredRateHz: Double = 0

    // MARK: - Private
    private weak var provider: ARSensorProvider?
    private var loopTask: Task<Void, Never>?
    private var isInferring = false
    private var lastResultTime: TimeInterval = 0

    #if canImport(UltralyticsYOLO)
    private var models: [ModelVariant: YOLO] = [:]
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
        if models[variant] != nil { loadState = .loaded; return }
        loadState = .loading
        let useGpu = (computeOption == .all || computeOption == .cpuAndGPU)
        YOLO(variant.rawValue, task: .segment, useGpu: useGpu) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success(let model):
                    self.models[variant] = model
                    self.loadState = (self.selectedVariant == variant) ? .loaded : self.loadState
                case .failure(let error):
                    self.loadState = .failed(error.localizedDescription)
                }
            }
        }
        #endif
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
    }

    /// Switches model at runtime; any in-flight inference finishes and is discarded.
    func switchModel(to variant: ModelVariant) {
        selectedVariant = variant
        latestResult = nil
        loadSelectedModel()
    }

    private func runLoop() async {
        while !Task.isCancelled && isEnabled {
            let interval = max(0.03, 1.0 / max(1, targetHz))
            await tick()
            try? await Task.sleep(for: .seconds(interval))
        }
    }

    private func tick() async {
        guard !isInferring, loadState == .loaded else { return }
        guard let provider, provider.isRunning, let frame = provider.snapshot() else { return }
        isInferring = true
        defer { isInferring = false }

        let variant = selectedVariant
        let threshold = confidenceThreshold
        let startWall = CACurrentMediaTime()

        #if canImport(UltralyticsYOLO)
        guard let model = models[variant] else { return }
        // Zero-copy from the ARFrame; orient to match the portrait display.
        let ciImage = CIImage(cvPixelBuffer: frame.capturedImage).oriented(.right)
        let result = await runInference(model: model, image: ciImage)
        let detection = convert(result, frame: frame, variant: variant,
                                threshold: threshold, startWall: startWall)
        publish(detection)
        #else
        _ = (variant, threshold, startWall)
        loadState = .sdkUnavailable
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
            modelVariant: variant,
            maskDegenerate: degenerate)
    }
    #endif
}
