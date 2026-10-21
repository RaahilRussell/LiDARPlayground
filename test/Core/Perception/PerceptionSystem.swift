//
//  PerceptionSystem.swift
//  test
//
//  Composition root for the AI Perception layer. Owns the engines and wires them
//  to the single ARSession (via ARSensorProvider). Injected once through the
//  SwiftUI environment. `navigation` is the Wearer Mode pipeline; the other
//  engines back the developer tabs (and supply object labels to navigation).
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
    let navigation: NavigationEngine
    let profiler: BenchmarkProfiler
    let inspector: PerceptionInspector

    private(set) var provider: ARSensorProvider?
    private var configured = false

    init() {
        navigation = NavigationEngine(haptics: haptics, speech: speech, vision: vision, fusion: fusion)
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
        navigation.attach(provider: provider, ar: manager)
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
