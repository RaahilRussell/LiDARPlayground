//
//  PerceptionSystem.swift
//  test
//
//  Composition root for the AI Perception layer. Owns the engines and wires them
//  to the single ARSession (via ARSensorProvider). Injected once through the
//  SwiftUI environment. Phase 7 adds the benchmark profiler; Phase 8 the
//  perception inspector (live metadata + deterministic demo mode).
//

import Observation

@MainActor
@Observable
final class PerceptionSystem {
    let vision = VisionInferenceEngine()
    let depth = DepthRefinementEngine()
    let fusion = SpatialFusionEngine()
    let spatial = SpatialAlgorithmsEngine()
    let haptics = HapticCoordinator()
    let speech = SpeechCoordinator()
    let spatialCue = SpatialCueCoordinator()
    let feedback: FeedbackCoordinator
    let proximity: ProximityEvaluator
    let proximityDriver: ProximityDriver
    let hazardMap: WorldHazardMap
    let profiler: BenchmarkProfiler
    let inspector: PerceptionInspector
    let guidance: GuidanceEngine

    private(set) var provider: ARSensorProvider?
    private var configured = false
    private(set) var mappingPerceptionRunning = false

    init() {
        feedback = FeedbackCoordinator(haptics: haptics, spatialCue: spatialCue)
        proximity = ProximityEvaluator(haptics: haptics)
        proximityDriver = ProximityDriver(proximity: proximity, spatial: spatial)
        hazardMap = WorldHazardMap(fusion: fusion, spatial: spatial)
        profiler = BenchmarkProfiler(vision: vision)
        inspector = PerceptionInspector()
        guidance = GuidanceEngine(speech: speech, haptics: haptics, spatialCue: spatialCue,
                                  proximity: proximity,
                                  proximityDriver: proximityDriver, spatial: spatial,
                                  fusion: fusion, vision: vision, hazardMap: hazardMap)
    }

    /// Connects the perception engines to the one and only ARSession owner.
    func configure(with manager: ARSessionManager) {
        guard !configured else { return }
        let provider = ARSensorProvider(manager: manager)
        self.provider = provider
        vision.attach(provider: provider)
        depth.attach(provider: provider)
        fusion.attach(provider: provider, vision: vision)
        spatial.attach(provider: provider, fusion: fusion)
        hazardMap.attach(provider: provider)
        proximityDriver.attach(provider: provider, fusion: fusion, hazardMap: hazardMap, feedback: feedback)
        profiler.attach(ar: manager)
        inspector.attach(provider: provider, system: self)
        guidance.attach(ar: manager)
        configured = true
    }

    /// Starts the model/depth/fusion stack alongside MappingCoordinator. Both
    /// consumers read the same ARSession; mapping never creates a second camera.
    func startForMapping() {
        guard configured else { return }
        mappingPerceptionRunning = true
        // Mapping is the durable pass, so prefer the highest bundled detector
        // rather than the low-latency preview variant used by the live console.
        vision.selectedVariant = .medium
        vision.start()
        depth.start()
        fusion.start()
        spatial.start()
        hazardMap.start()
    }

    /// Releases GPU/Metal-backed work when iOS backgrounds the app. The AR
    /// session is paused by ARSessionManager; these loops must be paused too.
    func stopForMapping() {
        mappingPerceptionRunning = false
        hazardMap.stop()
        spatial.stop()
        fusion.stop()
        depth.stop()
        vision.stop()
    }

    /// Leaving the foreground invalidates measurements and live inputs: cancel the
    /// profiler (which restores inference configuration) and pause the inspector.
    func handleLeftForeground() {
        profiler.cancel(reason: "App left the foreground")
        inspector.pause()
        guidance.stop()
        stopForMapping()
        vision.clearResults()
        fusion.clearResults()
        spatial.clearResults()
        hazardMap.clearResults()
        feedback.stop()
        speech.stopAll()
    }

    /// Stops feedback for route/map transitions while leaving the shared
    /// perception pipeline alive for mapping.
    func pauseForMapping() {
        profiler.cancel(reason: "Opened Maps")
        inspector.pause()
        proximity.reset()
        feedback.stop()
        spatialCue.stop()
        speech.stopAll()
    }
}
