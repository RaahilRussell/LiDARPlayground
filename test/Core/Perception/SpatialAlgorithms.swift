//
//  SpatialAlgorithms.swift
//  test
//
//  Phase 4 — experimental geometric processing on the LiDAR point cloud:
//  RANSAC floor-plane fit, ground vs elevated classification, voxel clustering,
//  and an honest per-region occupancy summary that preserves the distinction
//  between observed-free, occupied, unknown, and low-confidence. Unobserved space
//  is NEVER assumed empty.
//

import simd

struct FloorPlane {
    var normal: SIMD3<Float>   // unit, pointing up
    var d: Float               // plane: dot(normal, p) + d = 0
    var inliers: Int
    func signedDistance(_ p: SIMD3<Float>) -> Float { simd_dot(normal, p) + d }
}

struct PointCluster: Identifiable {
    let id: Int
    var centroid: SIMD3<Float>
    var count: Int
    var minBound: SIMD3<Float>
    var maxBound: SIMD3<Float>
}

/// Per-direction occupancy summary (camera-relative).
struct RegionOccupancy: Identifiable {
    let id: SpatialRegion
    var nearestMeters: Float?
    var meanConfidence: Float
    var sampleCount: Int
    var occupancy: OccupancyClass
}

enum SpatialAlgorithms {

    // MARK: - RANSAC floor plane

    /// Fits the dominant near-horizontal plane. Returns nil if none is convincing.
    static func estimateFloor(points: [SIMD3<Float>], iterations: Int = 80,
                              threshold: Float = 0.04, minInlierFraction: Float = 0.2) -> FloorPlane? {
        guard points.count >= 50 else { return nil }
        var rng = SystemRandomNumberGenerator()
        var best: FloorPlane?
        for _ in 0..<iterations {
            let a = points[Int.random(in: 0..<points.count, using: &rng)]
            let b = points[Int.random(in: 0..<points.count, using: &rng)]
            let c = points[Int.random(in: 0..<points.count, using: &rng)]
            var n = simd_cross(b - a, c - a)
            let len = simd_length(n)
            if len < 1e-5 { continue }
            n /= len
            if n.y < 0 { n = -n }                 // point "up"
            if n.y < 0.85 { continue }            // keep only near-horizontal planes
            let d = -simd_dot(n, a)
            var inliers = 0
            for p in points where abs(simd_dot(n, p) + d) < threshold { inliers += 1 }
            if inliers > (best?.inliers ?? 0) {
                best = FloorPlane(normal: n, d: d, inliers: inliers)
            }
        }
        if let best, Float(best.inliers) / Float(points.count) >= minInlierFraction { return best }
        return nil
    }

    /// Splits points into (ground, elevated) using the floor plane.
    static func classifyGround(points: [SIMD3<Float>], floor: FloorPlane,
                               groundBand: Float = 0.06) -> (ground: [SIMD3<Float>], elevated: [SIMD3<Float>]) {
        var ground = [SIMD3<Float>](), elevated = [SIMD3<Float>]()
        for p in points {
            let s = floor.signedDistance(p)
            if abs(s) <= groundBand { ground.append(p) }
            else if s > groundBand { elevated.append(p) }
        }
        return (ground, elevated)
    }

    // MARK: - Voxel clustering (connected components over an occupied voxel grid)

    static func cluster(points: [SIMD3<Float>], voxel: Float = 0.15, minPoints: Int = 10) -> [PointCluster] {
        guard !points.isEmpty else { return [] }
        struct Key: Hashable { let x: Int; let y: Int; let z: Int }
        func key(_ p: SIMD3<Float>) -> Key {
            Key(x: Int(floor(p.x / voxel)), y: Int(floor(p.y / voxel)), z: Int(floor(p.z / voxel)))
        }
        var buckets: [Key: [Int]] = [:]
        for (i, p) in points.enumerated() { buckets[key(p), default: []].append(i) }

        var visited = Set<Key>()
        var clusters: [PointCluster] = []
        var clusterId = 0
        for startKey in buckets.keys where !visited.contains(startKey) {
            // BFS over 26-neighborhood.
            var stack = [startKey]; visited.insert(startKey)
            var indices: [Int] = []
            while let k = stack.popLast() {
                if let pts = buckets[k] { indices.append(contentsOf: pts) }
                for dx in -1...1 { for dy in -1...1 { for dz in -1...1 {
                    if dx == 0 && dy == 0 && dz == 0 { continue }
                    let nk = Key(x: k.x + dx, y: k.y + dy, z: k.z + dz)
                    if buckets[nk] != nil && !visited.contains(nk) { visited.insert(nk); stack.append(nk) }
                }}}
            }
            guard indices.count >= minPoints else { continue }
            var sum = SIMD3<Float>(repeating: 0)
            var lo = points[indices[0]], hi = points[indices[0]]
            for i in indices {
                let p = points[i]; sum += p
                lo = simd_min(lo, p); hi = simd_max(hi, p)
            }
            clusters.append(PointCluster(id: clusterId, centroid: sum / Float(indices.count),
                                         count: indices.count, minBound: lo, maxBound: hi))
            clusterId += 1
        }
        return clusters.sorted { $0.count > $1.count }
    }

    // MARK: - Honest occupancy per region

    /// Summarizes occupancy for L/C/R using camera-space points + confidences.
    /// A region with no valid samples is `unknown`, never `observedFree`.
    static func occupancy(cameraPoints: [SIMD3<Float>], confidences: [Float],
                          occupiedThreshold: Float = 1.0,
                          lowConfidenceLevel: Float = 0.5) -> [RegionOccupancy] {
        var near: [SpatialRegion: Float] = [:]
        var confSum: [SpatialRegion: Float] = [:]
        var counts: [SpatialRegion: Int] = [:]

        for (i, p) in cameraPoints.enumerated() {
            let azimuth = atan2(p.x, -p.z)              // radians, +right
            let region: SpatialRegion = azimuth < -0.26 ? .left : (azimuth > 0.26 ? .right : .center)
            let dist = -p.z                              // forward distance
            guard dist > 0 else { continue }
            counts[region, default: 0] += 1
            confSum[region, default: 0] += (i < confidences.count ? confidences[i] : 1)
            if dist < (near[region] ?? .greatestFiniteMagnitude) { near[region] = dist }
        }

        return [SpatialRegion.left, .center, .right].map { region in
            let count = counts[region] ?? 0
            let meanConf = count > 0 ? (confSum[region] ?? 0) / Float(count) : 0
            let nearest = near[region]
            let cls: OccupancyClass
            if count < 5 { cls = .unknown }
            else if meanConf < lowConfidenceLevel { cls = .lowConfidence }
            else if let n = nearest, n < occupiedThreshold { cls = .occupied }
            else { cls = .observedFree }
            return RegionOccupancy(id: region, nearestMeters: nearest, meanConfidence: meanConf,
                                   sampleCount: count, occupancy: cls)
        }
    }
}
