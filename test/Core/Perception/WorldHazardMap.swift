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
    }

    // Published view of the current situation.
    private(set) var hazards: [Hazard] = []
    private(set) var zones: [ZoneHazard] = []        // nearest per L/C/R (persistent)
    private(set) var corridorNearest: ZoneHazard?    // nearest in the body-width path

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

    init(fusion: SpatialFusionEngine, spatial: SpatialAlgorithmsEngine) {
        self.fusion = fusion
        self.spatial = spatial
    }

    func attach(provider: ARSensorProvider) { self.provider = provider }

    func start() {
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in await self?.loop() }
    }
    func stop() {
        loopTask?.cancel(); loopTask = nil
        hazards = []; zones = []; corridorNearest = nil
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
        guard let frame = provider?.snapshot() else { decay(now); return }
        let transform = frame.cameraTransform

        if frame.trackingIsNormal {
            // Ingest fused CV objects (already in world coordinates).
            for obs in fusion.observations where !obs.uncertain && obs.nearestMeters.isFinite {
                if let world = obs.positionWorld {
                    upsert(world: world, radius: 0.25, label: obs.label,
                           confidence: obs.confidence, now: now)
                }
            }
            // Ingest elevated LiDAR clusters (unlabeled geometry — covers walls, poles…).
            for cluster in spatial.clusters {
                let extent = cluster.maxBound - cluster.minBound
                let radius = max(0.15, simd_length(extent) * 0.5)
                upsert(world: cluster.centroid, radius: radius, label: nil,
                       confidence: 0.5, now: now)
            }
        }

        decay(now)
        recomputeZones(cameraTransform: transform, now: now)
    }

    private func upsert(world: SIMD3<Float>, radius: Float, label: String?,
                        confidence: Float, now: TimeInterval) {
        if let idx = hazards.firstIndex(where: { simd_distance($0.world, world) < mergeRadius }) {
            // Smooth position; keep the most informative label.
            hazards[idx].world = 0.6 * hazards[idx].world + 0.4 * world
            hazards[idx].radius = max(hazards[idx].radius, radius)
            hazards[idx].confidence = max(hazards[idx].confidence, confidence)
            hazards[idx].lastSeen = now
            if hazards[idx].label == nil { hazards[idx].label = label }
        } else {
            hazards.append(Hazard(id: nextId, world: world, radius: radius,
                                  label: label, confidence: confidence, lastSeen: now))
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
                                       ttc: ttc, closingSpeed: closingSpeed)
            // Prefer the riskier candidate per region (smaller TTC, else smaller distance).
            if isRiskier(candidate, than: best[region]) { best[region] = candidate }
            if abs(lx) <= corridorHalfWidth, forward > 0, isRiskier(candidate, than: corridor) {
                corridor = candidate
            }
        }

        zones = [SpatialRegion.left, .center, .right].compactMap { best[$0] }
        corridorNearest = corridor
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
