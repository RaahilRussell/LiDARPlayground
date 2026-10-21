//
//  WorldHazardMap.swift
//  test
//
//  The camera + LiDAR only see a narrow forward FOV, but a walker can clip
//  something beside them or one that already left view. This keeps a short-lived
//  WORLD-ANCHORED memory of hazards (fused CV objects + LiDAR clusters), then each
//  tick re-projects them into the user's CURRENT heading and reports the nearest
//  hazard per side (left / center / right) plus the nearest in the walking
//  corridor. So an obstacle panned past still warns from the side until it decays.
//
//  World memory only accumulates while tracking is nominal; everything ages out so
//  stale/moved geometry is never treated as current truth.
//

import Foundation
import Observation
import QuartzCore
import simd

@MainActor
@Observable
final class WorldHazardMap {

    struct Hazard: Identifiable {
        let id: Int
        var world: SIMD3<Float>
        var radius: Float
        var label: String?
        var confidence: Float
        var lastSeen: TimeInterval
        var lastRange: Float? = nil
        var closingSpeed: Float = 0   // m/s toward the user (smoothed)
        var minHeight: Float? = nil   // metres above floor (bottom of the object)
        var maxHeight: Float? = nil   // metres above floor (top of the object)
    }

    /// Nearest hazard in a direction, expressed relative to the current pose.
    struct ZoneHazard: Identifiable {
        var id: SpatialRegion { region }
        var region: SpatialRegion
        var distance: Float       // horizontal metres
        var bearingDeg: Float     // + = right
        var label: String?
        var confidence: Float
        var ttc: Float?           // seconds to collision (nil if not closing)
        var closingSpeed: Float   // m/s
        var height: ObstacleHeight = .unknown
    }

    // Published view of the current situation.
    private(set) var hazards: [Hazard] = []
    private(set) var zones: [ZoneHazard] = []        // nearest per L/C/R (persistent)
    private(set) var corridorNearest: ZoneHazard?    // nearest in the body-width path
    /// Archived context is retained for display/export, never live proximity.
    private(set) var savedContext: [SavedPerceptionHazard] = []

    // Tunables.
    var maxAge: TimeInterval = 5
    var mergeRadius: Float = 0.4
    var corridorHalfWidth: Float = 0.5
    var centerHalfAngleDeg: Float = 25
    var rearCutoffDeg: Float = 100   // ignore hazards behind this bearing
    var maxHazards = 80

    private unowned let fusion: SpatialFusionEngine
    private unowned let spatial: SpatialAlgorithmsEngine
    private weak var provider: ARSensorProvider?
    private var loopTask: Task<Void, Never>?
    private var nextId = 0
    private var lastRecomputeTime: TimeInterval = 0
    private var sessionGeneration: Int = -1
    private var lastFusionTimestamp: TimeInterval = -1
    private var lastSpatialTimestamp: TimeInterval = -1

    init(fusion: SpatialFusionEngine, spatial: SpatialAlgorithmsEngine) {
        self.fusion = fusion
        self.spatial = spatial
    }

    func attach(provider: ARSensorProvider) { self.provider = provider }
    var isRunning: Bool { loopTask != nil }

    func start() {
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in await self?.loop() }
    }
    func stop() {
        loopTask?.cancel(); loopTask = nil
        clearResults()
    }

    func clearResults() {
        hazards = []; zones = []; corridorNearest = nil
        lastRecomputeTime = 0; lastFusionTimestamp = -1; lastSpatialTimestamp = -1
    }

    /// Exports only stable, high-confidence world results for map persistence.
    /// Motion-derived fields are intentionally omitted and rebuilt on revisit.
    func persistentSnapshot() -> [SavedPerceptionHazard] {
        if let provider, sessionGeneration != provider.sessionGeneration { return [] }
        let live = hazards.filter { $0.confidence >= 0.45 }.compactMap { hazard -> SavedPerceptionHazard? in
            let position = MapPosition(x: hazard.world.x, y: hazard.world.y, z: hazard.world.z)
            guard position.isValid else { return nil }
            return SavedPerceptionHazard(
                position: position,
                radius: hazard.radius,
                label: hazard.label,
                confidence: hazard.confidence,
                minHeight: hazard.minHeight,
                maxHeight: hazard.maxHeight,
                height: ObstacleHeight.classify(minHeight: hazard.minHeight, maxHeight: hazard.maxHeight))
        }
        let historical = savedContext.filter { saved in
            !live.contains { current in
                simd_distance(SIMD3(saved.position.x, saved.position.y, saved.position.z),
                              SIMD3(current.position.x, current.position.y, current.position.z)) < mergeRadius
            }
        }
        return Array((live + historical).prefix(200))
    }

    /// Saved observations have no current sensor evidence. They stay separate
    /// from live hazards until the camera/LiDAR observes this location again.
    func restorePersistentSnapshot(_ snapshot: [SavedPerceptionHazard]) {
        clearResults()
        savedContext = Array(snapshot.prefix(200).filter { saved in
            guard saved.position.isValid, saved.radius.isFinite, saved.radius >= 0,
                  saved.radius <= 100, saved.confidence.isFinite, (0...1).contains(saved.confidence),
                  [saved.minHeight, saved.maxHeight].compactMap({ $0 }).allSatisfy({ $0.isFinite && abs($0) <= 100 }) else { return false }
            return true
        })
        sessionGeneration = provider?.sessionGeneration ?? sessionGeneration
    }

    private func loop() async {
        while !Task.isCancelled {
            update()
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    // MARK: - Update

    private func update() {
        let now = CACurrentMediaTime()
        guard let provider else { clearResults(); return }
        if sessionGeneration != provider.sessionGeneration {
            clearResults()
            savedContext = []
            sessionGeneration = provider.sessionGeneration
        }
        guard let frame = provider.snapshot(), frame.trackingIsNormal else {
            clearResults()
            return
        }
        let transform = frame.cameraTransform

        if frame.trackingIsNormal {
            // Ingest fused CV objects (already in world coordinates).
            for obs in fusion.observations where !obs.uncertain && obs.nearestMeters.isFinite
                && fusion.sessionGeneration == sessionGeneration
                && obs.timestamp > lastFusionTimestamp
                && provider.isCurrentObservation(timestamp: obs.timestamp) {
                if let world = obs.positionWorld {
                    let heights = heightBounds(points: obs.boundsCornersWorld)
                    upsert(world: world, radius: 0.25, label: obs.label,
                           confidence: obs.confidence, now: obs.timestamp,
                           minHeight: heights?.min, maxHeight: heights?.max)
                }
            }
            if let timestamp = fusion.observations.map(\.timestamp).max() {
                lastFusionTimestamp = max(lastFusionTimestamp, timestamp)
            }
            // Ingest elevated LiDAR clusters (unlabeled geometry — covers walls, poles…).
            if spatial.hasWorldCoordinates, spatial.sessionGeneration == sessionGeneration,
               spatial.frameTimestamp > lastSpatialTimestamp,
               provider.isCurrentObservation(timestamp: spatial.frameTimestamp) {
                for cluster in spatial.clusters {
                    let extent = cluster.maxBound - cluster.minBound
                    let radius = max(0.15, simd_length(extent) * 0.5)
                    let heights = heightBounds(for: cluster, floor: spatial.floor)
                    upsert(world: cluster.centroid, radius: radius, label: nil,
                           confidence: 0.5, now: spatial.frameTimestamp,
                           minHeight: heights?.min, maxHeight: heights?.max)
                }
                lastSpatialTimestamp = spatial.frameTimestamp
            }
        }

        decay(now)
        recomputeZones(cameraTransform: transform, now: now)
    }

    private func upsert(world: SIMD3<Float>, radius: Float, label: String?,
                        confidence: Float, now: TimeInterval,
                        minHeight: Float? = nil, maxHeight: Float? = nil) {
        if let idx = hazards.firstIndex(where: { simd_distance($0.world, world) < mergeRadius }) {
            // Smooth position; keep the most informative label.
            hazards[idx].world = 0.6 * hazards[idx].world + 0.4 * world
            hazards[idx].radius = max(hazards[idx].radius, radius)
            hazards[idx].confidence = max(hazards[idx].confidence, confidence)
            hazards[idx].lastSeen = now
            if hazards[idx].label == nil { hazards[idx].label = label }
            if let minHeight { hazards[idx].minHeight = minHeight }
            if let maxHeight { hazards[idx].maxHeight = maxHeight }
        } else {
            hazards.append(Hazard(id: nextId, world: world, radius: radius,
                                  label: label, confidence: confidence, lastSeen: now,
                                  minHeight: minHeight, maxHeight: maxHeight))
            nextId += 1
        }
    }

    private func decay(_ now: TimeInterval) {
        hazards.removeAll { now - $0.lastSeen > maxAge }
        if hazards.count > maxHazards {
            hazards.sort { $0.lastSeen > $1.lastSeen }
            hazards.removeLast(hazards.count - maxHazards)
        }
    }

    // MARK: - Re-project into current heading

    private func recomputeZones(cameraTransform: simd_float4x4, now: TimeInterval) {
        let inverse = cameraTransform.inverse
        let dt = lastRecomputeTime > 0 ? Float(now - lastRecomputeTime) : 0
        lastRecomputeTime = now
        var best: [SpatialRegion: ZoneHazard] = [:]
        var corridor: ZoneHazard?

        for i in hazards.indices {
            let localH = inverse * SIMD4<Float>(hazards[i].world, 1)
            let lx = localH.x, lz = localH.z
            let forward = -lz                                      // metres in front (−Z is forward)
            let distance = max(0, hypotf(lx, lz) - hazards[i].radius)
            let bearing = atan2(lx, forward) * 180 / .pi           // + right

            // Range rate → closing speed → time-to-collision (ADAS-style).
            if let last = hazards[i].lastRange, dt > 0 {
                let rate = (distance - last) / dt                  // + moving away, − approaching
                let closing = max(0, -rate)
                hazards[i].closingSpeed = 0.6 * hazards[i].closingSpeed + 0.4 * closing
            }
            hazards[i].lastRange = distance
            let closingSpeed = hazards[i].closingSpeed
            let ttc: Float? = closingSpeed > 0.05 ? distance / closingSpeed : nil

            if abs(bearing) > rearCutoffDeg { continue }
            if forward < -0.5 { continue }

            let region: SpatialRegion = bearing < -centerHalfAngleDeg ? .left
                : (bearing > centerHalfAngleDeg ? .right : .center)
            let candidate = ZoneHazard(region: region, distance: distance, bearingDeg: bearing,
                                       label: hazards[i].label, confidence: hazards[i].confidence,
                                       ttc: ttc, closingSpeed: closingSpeed,
                                       height: ObstacleHeight.classify(minHeight: hazards[i].minHeight,
                                                                       maxHeight: hazards[i].maxHeight))
            // Prefer the riskier candidate per region (smaller TTC, else smaller distance).
            if isRiskier(candidate, than: best[region]) { best[region] = candidate }
            if abs(lx) <= corridorHalfWidth, forward > 0, isRiskier(candidate, than: corridor) {
                corridor = candidate
            }
        }

        zones = [SpatialRegion.left, .center, .right].compactMap { best[$0] }
        corridorNearest = corridor
    }

    private func heightBounds(points: [SIMD3<Float>]) -> (min: Float, max: Float)? {
        guard spatial.hasWorldCoordinates, spatial.sessionGeneration == sessionGeneration,
              provider?.isCurrentObservation(timestamp: spatial.frameTimestamp) == true,
              let floor = spatial.floor, !points.isEmpty else { return nil }
        let distances = points.map(floor.signedDistance)
        guard distances.allSatisfy({ $0.isFinite }), let min = distances.min(), let max = distances.max() else {
            return nil
        }
        return (min, max)
    }

    private func heightBounds(for cluster: PointCluster, floor: FloorPlane?) -> (min: Float, max: Float)? {
        guard let floor else { return nil }
        let distances = [cluster.minBound.x, cluster.maxBound.x].flatMap { x in
            [cluster.minBound.y, cluster.maxBound.y].flatMap { y in
                [cluster.minBound.z, cluster.maxBound.z].map { z in floor.signedDistance(SIMD3(x, y, z)) }
            }
        }
        guard distances.allSatisfy({ $0.isFinite }), let min = distances.min(), let max = distances.max() else {
            return nil
        }
        return (min, max)
    }

    /// Risk ordering: a closing hazard (finite TTC) outranks non-closing; among
    /// closing, smaller TTC wins; otherwise smaller distance wins.
    private func isRiskier(_ a: ZoneHazard, than b: ZoneHazard?) -> Bool {
        guard let b else { return true }
        switch (a.ttc, b.ttc) {
        case let (x?, y?): return x < y
        case (_?, nil): return true
        case (nil, _?): return false
        default: return a.distance < b.distance
        }
    }

    // MARK: - Query for the proximity driver

    /// The single primary hazard for feedback. The walking corridor always wins
    /// over a side object: path safety is the urgent channel, while side objects
    /// are handled as sparse directional awareness cues.
    func primaryHazard() -> ZoneHazard? {
        if let corridor = corridorNearest { return corridor }
        return zones.min { lhs, rhs in
            switch (lhs.ttc, rhs.ttc) {
            case let (left?, right?): return left < right
            case (_?, nil): return true
            case (nil, _?): return false
            default: return lhs.distance < rhs.distance
            }
        }
    }
}
