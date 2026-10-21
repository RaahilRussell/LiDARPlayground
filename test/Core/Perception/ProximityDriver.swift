//
//  ProximityDriver.swift
//  test
//
//  Phase 6 — feeds the ProximityEvaluator. Two sources:
//   • .fusedObjects — nearest STABLE fused CV+LiDAR object (label-aware), with a
//     raw-geometry (occupancy) fallback when no object qualifies.
//   • .occupancy — pure geometry per region (no model needed).
//
//  Noise control is layered so alerts don't over-fire:
//   1. per-object gates (confidence, valid-depth coverage, not-uncertain)
//   2. stability gate (object must persist N frames before it can alert)
//   3. distance EMA smoothing (kills per-frame jitter)
//   4. state-machine hysteresis + cooldown (in ProximityEvaluator)
//   5. transitions-only alert log (recentAlerts) so the UI list stays readable
//
//  A Training/Demo mode injects mock obstacles, always flagged as simulated.
//

import Foundation
import Observation
import QuartzCore

@MainActor
@Observable
final class ProximityDriver {
    enum Source: String, CaseIterable, Identifiable { case fusedObjects = "Fused", occupancy = "Geometry"; var id: String { rawValue } }

    var running = false
    var demoMode = false
    var source: Source = .occupancy
    var mockDistance: Float = 0.8
    var mockRegion: SpatialRegion = .center

    // Noise-control knobs (user-tunable in the Fused panel).
    var minObjectConfidence: Float = 0.45
    var minCoverage: Float = 0.2
    var minStableFrames: Int = 3
    var distanceSmoothing: Float = 0.5     // weight on previous estimate (0 = none)

    // Live "primary hazard" for the UI header.
    private(set) var primaryLabel: String?
    private(set) var primaryDistance: Float?
    private(set) var primaryRegion: SpatialRegion?
    private(set) var primaryTTC: Float?
    private(set) var recentAlerts: [ProximityEvent] = []
    private(set) var inputStatus: AlertInputStatus = .stopped
    var statusText: String { inputStatus.message }

    private unowned let proximity: ProximityEvaluator
    private unowned let spatial: SpatialAlgorithmsEngine
    private weak var fusion: SpatialFusionEngine?
    private weak var provider: ARSensorProvider?
    private weak var hazardMap: WorldHazardMap?
    private weak var feedback: FeedbackCoordinator?
    private var loopTask: Task<Void, Never>?

    // Smoothing / stability state.
    private var smoothedDistance: Float?
    private var primaryKey: String?
    private var stableFrames = 0
    private var lastLoggedState: ProximityState?
    private var smoothedUrgency: Float = 0
    private var smoothedBearing: Float = 0
    private var sessionGeneration: Int = -1

    init(proximity: ProximityEvaluator, spatial: SpatialAlgorithmsEngine) {
        self.proximity = proximity
        self.spatial = spatial
    }

    func attach(provider: ARSensorProvider, fusion: SpatialFusionEngine,
                hazardMap: WorldHazardMap, feedback: FeedbackCoordinator) {
        self.provider = provider
        self.fusion = fusion
        self.hazardMap = hazardMap
        self.feedback = feedback
    }

    func start() {
        guard loopTask == nil else { return }
        running = true
        inputStatus = .waitingForCamera
        loopTask = Task { [weak self] in await self?.loop() }
    }

    func stop() {
        running = false
        inputStatus = .stopped
        loopTask?.cancel(); loopTask = nil
        feedback?.stop()
        resetFilters()
    }

    private func resetFilters() {
        smoothedDistance = nil; primaryKey = nil; stableFrames = 0
        smoothedUrgency = 0; smoothedBearing = 0
        primaryLabel = nil; primaryDistance = nil; primaryRegion = nil
        primaryTTC = nil
    }

    private func loop() async {
        while !Task.isCancelled {
            if running { step() }
            try? await Task.sleep(for: .milliseconds(150))
        }
    }

    private func step() {
        let now = CACurrentMediaTime()

        if demoMode {
            inputStatus = .demo
            let inPath = abs(mockRegion == .center ? 0 : 45) <= 30   // center = in path
            let event = proximity.evaluate(nearest: mockDistance, confidence: 1.0, region: mockRegion,
                                           label: "mock", isSimulated: true, inputTimestamp: now,
                                           ttc: nil, bearing: mockRegion == .left ? -45 : (mockRegion == .right ? 45 : 0),
                                           inPath: inPath)
            primaryLabel = "mock"; primaryDistance = mockDistance; primaryRegion = mockRegion; primaryTTC = nil
            updateFeedback(state: event.state, distance: mockDistance, ttc: nil,
                           inPath: inPath,
                           bearing: mockRegion == .left ? -45 : (mockRegion == .right ? 45 : 0),
                           now: now)
            log(event); return
        }

        if sessionGeneration != provider?.sessionGeneration {
            sessionGeneration = provider?.sessionGeneration ?? -1
            resetFilters()
        }
        let frame = provider?.cameraSnapshot()
        let geometryCurrent = provider.map {
            spatial.sessionGeneration == $0.sessionGeneration &&
            $0.isCurrentObservation(timestamp: spatial.frameTimestamp)
        } ?? false
        inputStatus = AlertInputStatus.evaluate(cameraAvailable: frame != nil,
            depthAvailable: frame?.depthMap != nil || frame?.smoothedDepthMap != nil,
            geometryCurrent: geometryCurrent, worldTrackingValid: frame?.trackingIsNormal == true)
        guard inputStatus.hasCurrentMeasurements else {
            resetFilters()
            let event = proximity.evaluate(nearest: nil, confidence: nil, region: nil, label: nil,
                                           isSimulated: false, inputTimestamp: now)
            // Drop stale cues immediately; the loop and the user's request stay
            // active and will consume the next fresh camera/depth observation.
            feedback?.stop()
            log(event)
            return
        }

        let hazard: Hazard?
        switch source {
        case .fusedObjects:
            hazard = frame?.trackingIsNormal == true ? (fusedHazard() ?? occupancyHazard()) : occupancyHazard()
        case .occupancy:    hazard = occupancyHazard()
        }

        if let h = hazard {
            // Only the forward walking corridor is "in path". A side object can show
            // a positive TTC while the user naturally walks past it; that is a side cue,
            // not a stop condition.
            let inPath = abs(h.bearing) <= 30
            primaryLabel = h.label; primaryDistance = h.distance
            primaryRegion = h.region; primaryTTC = h.ttc
            let event = proximity.evaluate(nearest: h.distance, confidence: h.confidence,
                                           region: h.region, label: h.label,
                                           isSimulated: false, inputTimestamp: now,
                                           ttc: h.ttc, bearing: h.bearing, inPath: inPath,
                                           obstacleHeight: h.height)
            updateFeedback(state: event.state, distance: h.distance, ttc: h.ttc,
                           inPath: inPath, bearing: h.bearing, now: now)
            log(event)
        } else {
            // No hazard: observed-free space is CLEAR; never-observed space is UNCERTAIN.
            let forwardObservedFree = spatial.occupancy.contains { $0.id == .center && $0.occupancy == .observedFree }
            let event = forwardObservedFree
                ? proximity.evaluate(nearest: 10, confidence: 1, region: nil, label: nil,
                                     isSimulated: false, inputTimestamp: now)
                : proximity.evaluate(nearest: nil, confidence: nil, region: nil, label: nil,
                                     isSimulated: false, inputTimestamp: now)
            primaryLabel = nil; primaryDistance = nil; primaryRegion = nil; primaryTTC = nil
            updateFeedback(state: event.state, distance: nil, ttc: nil,
                           inPath: true, bearing: 0, now: now)
            log(event)
        }
    }

    /// Normalized urgency 0…1 from distance + time-to-collision. Lateral (not in
    /// path) hazards are strongly attenuated so walking alongside stays gentle.
    private func urgency(distance: Float?, ttc: Float?, inPath: Bool) -> Float {
        var u: Float = 0
        if let d = distance, d.isFinite {
            let caution = proximity.cautionDistance, critical = proximity.criticalDistance
            var du = (caution - d) / max(0.01, caution - critical)
            du = max(0, min(1, du))
            if !inPath { du *= 0.4 }
            u = max(u, du)
        }
        if let t = ttc, t.isFinite, t > 0 {
            let tu = (4.0 - t) / (4.0 - 1.5)   // ttcCaution … ttcCritical
            u = max(u, Float(max(0, min(1, tu))))
        }
        return u
    }

    /// Smooth the continuous cue separately from the discrete state machine. This
    /// prevents a single noisy depth sample from causing an abrupt audio or haptic
    /// jump while preserving immediate state escalation.
    private func updateFeedback(state: ProximityState, distance: Float?, ttc: Float?,
                                inPath: Bool, bearing: Float, now: TimeInterval) {
        let targetUrgency = urgency(distance: distance, ttc: ttc, inPath: inPath)
        let alpha: Float = state == .critical ? 0.65 : 0.28
        smoothedUrgency += alpha * (targetUrgency - smoothedUrgency)
        smoothedBearing += 0.3 * (bearing - smoothedBearing)
        feedback?.update(state: state, urgency: smoothedUrgency,
                         bearingDeg: smoothedBearing, inPath: inPath, now: now)
    }

    // MARK: - Hazard selection

    private struct Hazard {
        let distance: Float; let confidence: Float; let region: SpatialRegion
        let label: String?; let ttc: Float?; let bearing: Float; let height: ObstacleHeight
    }

    /// Most pressing hazard from the WORLD-ANCHORED memory (persists out of FOV,
    /// covers left/center/right), with stability + distance smoothing.
    private func fusedHazard() -> Hazard? {
        guard let primary = hazardMap?.primaryHazard(),
              primary.confidence >= minObjectConfidence else {
            resetFilters(); return nil
        }
        let key = "\((primary.label ?? "obstacle"))|\(primary.region.rawValue)"
        if key != primaryKey {
            primaryKey = key; smoothedDistance = primary.distance; stableFrames = 1
        } else {
            stableFrames += 1
            let a = max(0, min(1, distanceSmoothing))
            smoothedDistance = a * (smoothedDistance ?? primary.distance) + (1 - a) * primary.distance
        }
        guard stableFrames >= minStableFrames, let d = smoothedDistance else { return nil }
        return Hazard(distance: d, confidence: primary.confidence, region: primary.region,
                      label: primary.label, ttc: primary.ttc, bearing: primary.bearingDeg,
                      height: primary.height)
    }

    /// Raw geometry uses the measured distance even when the occupancy grid's
    /// fixed one-metre threshold labels a cell free. Proximity thresholds remain
    /// independently configurable (the default caution distance is two metres).
    private func occupancyHazard() -> Hazard? {
        guard let nearest = Self.occupancyInput(from: spatial.occupancy,
                                                cautionDistance: proximity.cautionDistance) else { return nil }
        let bearing: Float
        switch nearest.region {
        case .left: bearing = -45
        case .right: bearing = 45
        case .center: bearing = 0
        }
        return Hazard(distance: nearest.meters, confidence: nearest.confidence, region: nearest.region,
                      label: nil, ttc: nil, bearing: bearing, height: .unknown)
    }

    nonisolated static func occupancyInput(from regions: [RegionOccupancy], cautionDistance: Float)
        -> (meters: Float, confidence: Float, region: SpatialRegion)? {
        // A distant side sample must not assert that an unobserved forward path
        // is clear. Nearby side hazards may still produce a caution cue.
        let candidates = regions.filter { region in
            guard let distance = region.nearestMeters, distance.isFinite, distance > 0,
                  region.meanConfidence.isFinite else { return false }
            return region.id == .center || distance <= cautionDistance
        }
        return ProximityInputSelector.select(from: candidates)
    }

    // MARK: - Clean alert log (transitions only)

    private func log(_ event: ProximityEvent) {
        guard event.state != lastLoggedState else { return }
        lastLoggedState = event.state
        recentAlerts.insert(event, at: 0)
        if recentAlerts.count > 30 { recentAlerts.removeLast(recentAlerts.count - 30) }
    }
}
