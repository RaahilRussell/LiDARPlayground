//
//  DepthGeometry.swift
//  test
//
//  LiDAR depth → world points, "can the camera see this point?", and the floor
//  height under the user. Pure and nonisolated: runs off the main actor and in tests.
//

import CoreGraphics
import CoreVideo
import simd

/// Pinhole model of one frame at depth-buffer resolution.
nonisolated struct CameraProjection: Sendable {
    let fx: Float, fy: Float, cx: Float, cy: Float
    let width: Int, height: Int
    let cameraToWorld: simd_float4x4
    let worldToCamera: simd_float4x4
    /// LiDAR stops being useful beyond ~5 m.
    var maxRange: Float = 5

    /// Intrinsics are given for the captured-image resolution; scale them to the depth buffer.
    init(intrinsics k: simd_float3x3, imageResolution: CGSize, depthWidth: Int, depthHeight: Int,
         cameraTransform: simd_float4x4) {
        let sx = Float(depthWidth) / Float(imageResolution.width)
        let sy = Float(depthHeight) / Float(imageResolution.height)
        fx = k[0][0] * sx; fy = k[1][1] * sy
        cx = k[2][0] * sx; cy = k[2][1] * sy
        width = depthWidth; height = depthHeight
        cameraToWorld = cameraTransform
        worldToCamera = cameraTransform.inverse
    }

    /// Depth pixel + metric depth → world point (ARKit camera space: −z forward, +y up in landscape).
    func unproject(x: Int, y: Int, depth d: Float) -> SIMD3<Float> {
        let camera = SIMD4<Float>((Float(x) - cx) * d / fx, -(Float(y) - cy) * d / fy, -d, 1)
        let w = cameraToWorld * camera
        return SIMD3<Float>(w.x, w.y, w.z)
    }

    /// True when the point is in front of the camera, within LiDAR range, and inside the frame.
    func isVisible(_ world: SIMD3<Float>) -> Bool {
        let c = worldToCamera * SIMD4<Float>(world, 1)
        let d = -c.z
        guard d > 0.2, d < maxRange else { return false }
        let u = c.x * fx / d + cx
        let v = -c.y * fy / d + cy
        return u >= 1 && u < Float(width - 1) && v >= 1 && v < Float(height - 1)
    }
}

nonisolated enum DepthSampler {
    /// World points for every `stride`-th depth pixel with confidence ≥ `minConfidence`
    /// (ARConfidenceLevel raw: 0 low, 1 medium, 2 high) and depth within range.
    static func worldPoints(depthMap: CVPixelBuffer, confidenceMap: CVPixelBuffer?,
                            projection: CameraProjection, stride: Int = 4,
                            minConfidence: UInt8 = 1) -> [SIMD3<Float>] {
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
        if let c = confidenceMap { CVPixelBufferLockBaseAddress(c, .readOnly) }
        defer { if let c = confidenceMap { CVPixelBufferUnlockBaseAddress(c, .readOnly) } }
        guard let dbase = CVPixelBufferGetBaseAddress(depthMap) else { return [] }
        let drb = CVPixelBufferGetBytesPerRow(depthMap)
        let cbase = confidenceMap.flatMap { CVPixelBufferGetBaseAddress($0) }
        let crb = confidenceMap.map { CVPixelBufferGetBytesPerRow($0) } ?? 0

        var points: [SIMD3<Float>] = []
        points.reserveCapacity((projection.width / stride + 1) * (projection.height / stride + 1))
        var y = 0
        while y < projection.height {
            let drow = dbase.advanced(by: y * drb).assumingMemoryBound(to: Float32.self)
            let crow = cbase?.advanced(by: y * crb).assumingMemoryBound(to: UInt8.self)
            var x = 0
            while x < projection.width {
                let d = drow[x]
                if d.isFinite, d > 0.2, d < projection.maxRange, (crow?[x] ?? 2) >= minConfidence {
                    points.append(projection.unproject(x: x, y: y, depth: d))
                }
                x += stride
            }
            y += stride
        }
        return points
    }
}

nonisolated enum FloorEstimator {
    /// World y of the floor under the user, or nil if no convincing floor is in view.
    /// RANSAC returns the DOMINANT level plane, which can be a large table or bed,
    /// so after each fit we look again below it: the lowest convincing level plane
    /// within `minDrop`…`maxDrop` under the camera is the floor. Each pass keeps only
    /// points more than 15 cm below the fitted plane itself (not below its height at
    /// the camera, which on a ramp would keep refitting the same plane forever), so
    /// every pass drops the previous plane's inliers and the loop terminates.
    static func floorY<G: RandomNumberGenerator>(points: [SIMD3<Float>], camera: SIMD3<Float>,
                                                 minDrop: Float = 0.6, maxDrop: Float = 2.2,
                                                 using rng: inout G) -> Float? {
        var candidates = points.filter { camera.y - $0.y >= minDrop && camera.y - $0.y <= maxDrop + 0.2 }
        var lowest: Float?
        while let plane = SpatialAlgorithms.estimateFloor(points: candidates, using: &rng), plane.normal.y > 0.97 {
            let y = -(plane.normal.x * camera.x + plane.normal.z * camera.z + plane.d) / plane.normal.y
            lowest = y
            candidates = candidates.filter { plane.signedDistance($0) < -0.15 }
        }
        guard let lowest, camera.y - lowest >= minDrop, camera.y - lowest <= maxDrop else { return nil }
        return lowest
    }

    static func floorY(points: [SIMD3<Float>], camera: SIMD3<Float>) -> Float? {
        var rng = SystemRandomNumberGenerator()
        return floorY(points: points, camera: camera, using: &rng)
    }
}
