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
    let proximity: ProximityEvaluator
    let proximityDriver: ProximityDriver
    let profiler: BenchmarkProfiler
    let inspector: PerceptionInspector

    private(set) var provider: ARSensorProvider?
    private var configured = false

    init() {
        proximity = ProximityEvaluator(haptics: haptics)
        proximityDriver = ProximityDriver(proximity: proximity, spatial: spatial)
        profiler = BenchmarkProfiler(vision: vision)
        inspector = PerceptionInspector()
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
        proximityDriver.attach(provider: provider)
        profiler.attach(ar: manager)
        inspector.attach(provider: provider, system: self)
        configured = true
    }

    /// Leaving the foreground invalidates measurements and live inputs: cancel the
    /// profiler (which restores inference configuration) and pause the inspector.
    func handleLeftForeground() {
        profiler.cancel(reason: "App left the foreground")
        inspector.pause()
    }
}
