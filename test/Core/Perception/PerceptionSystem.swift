//
//  PerceptionSystem.swift
//  test
//
//  Composition root for the AI Perception layer. Owns the engines and wires them
//  to the single ARSession (via ARSensorProvider). Injected once through the
//  SwiftUI environment. Later phases add depth-refinement, fusion, tracker,
//  proximity, haptics, and diagnostics here.
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

    private(set) var provider: ARSensorProvider?
    private var configured = false

    init() {
        proximity = ProximityEvaluator(haptics: haptics)
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
        configured = true
    }
}
