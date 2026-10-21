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
import Foundation

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
    private var foregroundActive = true
    private var resumeProximity = false
    private var demands = PerceptionPipelineDemand()
    private let guidanceConsumer = UUID()

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
        guidance.activatePipelines = { [weak self] in
            guard let self else { return }
            if !self.vision.isEnabled { self.vision.targetHz = 6 }
            if !self.proximityDriver.running { self.proximityDriver.source = .fusedObjects }
            self.proximityDriver.demoMode = false
            self.acquire(.guidance, for: self.guidanceConsumer)
        }
        guidance.deactivatePipelines = { [weak self] in
            guard let self else { return }
            self.release(self.guidanceConsumer)
        }
    }

    func acquire(_ pipelines: PerceptionPipelines, for consumer: UUID) {
        // A benchmark restores its saved inference configuration on cancellation.
        // Finish that restoration before the incoming screen requests engines.
        profiler.cancel(reason: "Started another perception feature")
        var running: PerceptionPipelines = []
        if vision.isEnabled { running.insert(.vision) }
        if fusion.isRunning { running.insert(.fusion) }
        if spatial.isRunning { running.insert(.spatial) }
        if proximityDriver.running || resumeProximity { running.insert(.proximity) }
        if depth.isRunning { running.insert(.depth) }
        apply(demands.acquire(pipelines, for: consumer, running: running))
    }

    func release(_ consumer: UUID) { apply(demands.release(consumer)) }

    private func apply(_ change: PerceptionPipelineDemand.Changes) {
        if change.stop.contains(.proximity) {
            resumeProximity = false; proximityDriver.stop(); proximity.reset()
        }
        if change.stop.contains(.spatial) { spatial.stop() }
        if change.stop.contains(.fusion) { fusion.stop() }
        if change.stop.contains(.vision) { vision.stop() }
        if change.stop.contains(.depth) { depth.stop() }
        if change.start.contains(.vision) { vision.start() }
        if change.start.contains(.fusion) { fusion.start() }
        if change.start.contains(.spatial) { spatial.start() }
        if change.start.contains(.depth) { depth.start() }
        if change.start.contains(.proximity) {
            if foregroundActive { proximityDriver.start() } else { resumeProximity = true }
        }
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

    /// Leaving the foreground invalidates measurements and live inputs: cancel the
    /// profiler (which restores inference configuration) and pause the inspector.
    func handleLeftForeground() {
        guard foregroundActive else { return }
        foregroundActive = false
        guidance.setForegroundActive(false)
        profiler.cancel(reason: "App left the foreground")
        inspector.pause()
        resumeProximity = proximityDriver.running
        proximityDriver.stop()
        vision.clearResults()
        depth.clearResults()
        fusion.clearResults()
        spatial.clearResults()
        hazardMap.clearResults()
        feedback.stop()
        speech.stopAll()
    }

    func handleEnteredForeground() {
        foregroundActive = true
        guidance.setForegroundActive(true)
        if resumeProximity { proximityDriver.start(); resumeProximity = false }
    }

    /// Starting route speech must not disable CV, LiDAR processing or the
    /// proximity feedback that the user enabled in another feature.
    func beginNavigationSpeech() {
        guidance.setNavigationSpeechActive(true)
        speech.stopAll()
    }

    func endNavigationSpeech() { guidance.setNavigationSpeechActive(false) }
}
