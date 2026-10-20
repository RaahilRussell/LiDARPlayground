//
//  ObjectTracker.swift
//  test
//
//  Phase 4 — short-term object tracking by geometric nearest-neighbour
//  association, with velocity estimated from timestamped positions. Tracks that
//  go unseen briefly are dropped. This is experimental association, not a
//  validated multi-object tracker.
//

import Foundation
import simd

struct TrackedObject: Identifiable {
    let id: Int
    var label: String
    var position: SIMD3<Float>       // world if available, else camera
    var velocity: SIMD3<Float>
    var speed: Float { simd_length(velocity) }
    var lastSeen: TimeInterval
    var hits: Int
    var nearestMeters: Float
    var uncertain: Bool
}

struct ObjectTracker {
    var gate: Float = 0.6            // metres for association
    var maxAge: TimeInterval = 0.7   // drop tracks unseen longer than this
    private var tracks: [TrackedObject] = []
    private var nextId = 0

    var current: [TrackedObject] { tracks }

    mutating func update(with observations: [ObjectObservation], now: TimeInterval) -> [TrackedObject] {
        var matchedTrackIndices = Set<Int>()

        for obs in observations {
            let pos = obs.positionWorld ?? obs.positionCamera
            // Nearest unmatched track within the gate.
            var bestIdx = -1
            var bestDist = gate
            for (i, t) in tracks.enumerated() where !matchedTrackIndices.contains(i) {
                let dist = simd_distance(t.position, pos)
                if dist < bestDist { bestDist = dist; bestIdx = i }
            }
            if bestIdx >= 0 {
                matchedTrackIndices.insert(bestIdx)
                var t = tracks[bestIdx]
                let dt = max(1e-3, now - t.lastSeen)
                t.velocity = (pos - t.position) / Float(dt)
                t.position = pos
                t.label = obs.label
                t.lastSeen = now
                t.hits += 1
                t.nearestMeters = obs.nearestMeters
                t.uncertain = obs.uncertain
                tracks[bestIdx] = t
            } else {
                tracks.append(TrackedObject(id: nextId, label: obs.label, position: pos,
                                            velocity: .zero, lastSeen: now, hits: 1,
                                            nearestMeters: obs.nearestMeters, uncertain: obs.uncertain))
                nextId += 1
            }
        }

        tracks.removeAll { now - $0.lastSeen > maxAge }
        return tracks
    }

    mutating func reset() { tracks.removeAll() }
}
