//
//  DepthRefinementEngine.swift
//  test
//
//  Phase 2 — drives the depth filters on the live frame and publishes four
//  comparison images (RGB, raw depth, refined depth, edges) plus valid-pixel
//  stats. Temporal state resets on tracking loss or large camera motion. Runs
//  on its OWN path, independent of YOLO inference.
//

import Observation
import QuartzCore
import simd

@MainActor
@Observable
final class DepthRefinementEngine {
    var mode: DepthFilterMode = .jointBilateral
    var params = FilterParams()
    var rangeMax: Float = 5

    private(set) var rgbImage: CGImage?
    private(set) var rawImage: CGImage?
    private(set) var refinedImage: CGImage?
    private(set) var edgeImage: CGImage?
    private(set) var validBefore: Double = 0
    private(set) var validAfter: Double = 0
    private(set) var lastProcessMs: Double = 0

    private weak var provider: ARSensorProvider?
    private var loopTask: Task<Void, Never>?
    private var isProcessing = false

    // Temporal state
    private var previousRefined: [Float]?
    private var previousTranslation: SIMD3<Float>?
    private var sessionGeneration: Int = -1

    func attach(provider: ARSensorProvider) { self.provider = provider }
    var isRunning: Bool { loopTask != nil }

    func start() {
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in await self?.loop() }
    }
    func stop() {
        loopTask?.cancel(); loopTask = nil
        previousRefined = nil; previousTranslation = nil
    }

    private func loop() async {
        while !Task.isCancelled {
            await tick()
            try? await Task.sleep(for: .milliseconds(120)) // ~8 Hz; analysis, not proximity
        }
    }

    private func tick() async {
        guard !isProcessing, let provider, provider.isRunning,
              let frame = provider.cameraSnapshot(), frame.depthMap != nil else { return }
        if sessionGeneration != provider.sessionGeneration {
            previousRefined = nil; previousTranslation = nil
            sessionGeneration = provider.sessionGeneration
        }
        let generation = provider.sessionGeneration
        isProcessing = true
        defer { isProcessing = false }

        // Decide whether temporal state is still valid (reset on big motion / lost tracking).
        let translation = SIMD3<Float>(frame.cameraTransform.columns.3.x,
                                       frame.cameraTransform.columns.3.y,
                                       frame.cameraTransform.columns.3.z)
        var carryPrevious = previousRefined
        if !frame.trackingIsNormal { carryPrevious = nil }
        if let prev = previousTranslation, simd_distance(prev, translation) > 0.15 { carryPrevious = nil }

        let mode = self.mode
        let params = self.params
        let range = self.rangeMax

        let start = CACurrentMediaTime()
        let output = await Self.process(frame: frame, mode: mode, params: params,
                                        range: range, previous: carryPrevious)
        guard !Task.isCancelled, provider.isRunning,
              provider.sessionGeneration == generation,
              ARSensorProvider.isFresh(timestamp: frame.timestamp, now: CACurrentMediaTime()) else { return }
        lastProcessMs = (CACurrentMediaTime() - start) * 1000

        rgbImage = output.rgb
        rawImage = output.raw
        refinedImage = output.refined
        edgeImage = output.edges
        validBefore = output.validBefore
        validAfter = output.validAfter

        previousRefined = output.refinedArray
        previousTranslation = translation
    }

    // MARK: - Off-main processing

    private struct Output {
        var rgb: CGImage?; var raw: CGImage?; var refined: CGImage?; var edges: CGImage?
        var validBefore: Double; var validAfter: Double; var refinedArray: [Float]
    }

    nonisolated private static func process(frame: SensorFrame, mode: DepthFilterMode,
                                            params: FilterParams, range: Float,
                                            previous: [Float]?) async -> Output {
        await Task.detached(priority: .userInitiated) {
            guard let depthMap = frame.depthMap else {
                return Output(rgb: nil, raw: nil, refined: nil, edges: nil,
                              validBefore: 0, validAfter: 0, refinedArray: [])
            }
            let rawField = DepthRefinement.field(from: depthMap, confidence: frame.rawConfidenceMap)
            let w = rawField.width, h = rawField.height
            let guide = DepthRefinement.rgbGuide(frame.capturedImage, width: w, height: h)

            let baseField: DepthField
            if mode == .smoothed, let sm = frame.smoothedDepthMap {
                baseField = DepthRefinement.field(from: sm, confidence: frame.confidenceMap)
            } else {
                baseField = rawField
            }

            let refined: [Float]
            switch mode {
            case .raw, .smoothed:
                refined = baseField.depth
            case .confidenceMedian:
                refined = DepthRefinement.confidenceMedian(baseField, params: params)
            case .jointBilateral:
                refined = DepthRefinement.jointBilateral(baseField, guide: guide, params: params)
            case .temporal:
                refined = DepthRefinement.temporal(baseField, previous: previous, params: params)
            case .combined:
                let a = DepthRefinement.confidenceMedian(baseField, params: params)
                var fA = baseField; fA.depth = a
                let b = DepthRefinement.jointBilateral(fA, guide: guide, params: params)
                var fB = baseField; fB.depth = b
                refined = DepthRefinement.temporal(fB, previous: previous, params: params)
            }

            let edges = DepthRefinement.edges(refined, width: w, height: h,
                                              threshold: params.discontinuityThreshold)
            var refinedField = baseField; refinedField.depth = refined

            return Output(
                rgb: DepthRefinement.rgbImage(guide, width: w, height: h),
                raw: DepthRefinement.colorize(rawField.depth, width: w, height: h, range: 0...range),
                refined: DepthRefinement.colorize(refined, width: w, height: h, range: 0...range),
                edges: DepthRefinement.edgeImage(edges, width: w, height: h),
                validBefore: rawField.validFraction,
                validAfter: refinedField.validFraction,
                refinedArray: refined)
        }.value
    }
}
