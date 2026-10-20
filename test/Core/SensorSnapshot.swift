//
//  SensorSnapshot.swift
//  test
//
//  Feature 7 — a lightweight, copied snapshot of the current frame's raw numeric
//  sensor data for the Data Inspector. Sampling is small (an 8×8 grid), so this
//  is cheap enough to build a few times per second on the main actor.
//

import ARKit
import simd

struct SensorSnapshot {
    var timestamp: TimeInterval
    var intrinsics: simd_float3x3
    var transform: simd_float4x4
    var imageResolution: CGSize
    var depthWidth: Int
    var depthHeight: Int
    var trackingQuality: String
    /// 8×8 grid of depth values in metres (-1 == invalid).
    var sampleDepthGrid: [[Float]]
    /// Example 3D points (world space, metres) from the grid.
    var samplePoints: [SIMD3<Float>]
}

extension ARSessionManager {

    /// Builds a display snapshot from the current frame, or nil if none yet.
    func liveSnapshot(gridSize: Int = 8) -> SensorSnapshot? {
        guard let frame = session.currentFrame else { return nil }
        let depthData = frame.smoothedSceneDepth ?? frame.sceneDepth
        let depthMap = depthData?.depthMap
        let dw = depthMap.map { CVPixelBufferGetWidth($0) } ?? 0
        let dh = depthMap.map { CVPixelBufferGetHeight($0) } ?? 0

        let intrinsics = frame.camera.intrinsics
        let transform = frame.camera.transform
        let imageRes = frame.camera.imageResolution

        var grid = [[Float]](repeating: [Float](repeating: -1, count: gridSize), count: gridSize)
        var points = [SIMD3<Float>]()

        if let depthMap {
            for gy in 0..<gridSize {
                for gx in 0..<gridSize {
                    let nx = (CGFloat(gx) + 0.5) / CGFloat(gridSize)
                    let ny = (CGFloat(gy) + 0.5) / CGFloat(gridSize)
                    if let d = DepthProcessing.sampleDistance(depth: depthMap,
                                                              normalizedPoint: CGPoint(x: nx, y: ny)) {
                        grid[gy][gx] = d
                        let world = Self.unprojectToWorld(nx: Float(nx), ny: Float(ny), depth: d,
                                                          intrinsics: intrinsics,
                                                          depthWidth: dw, depthHeight: dh,
                                                          imageResolution: imageRes,
                                                          cameraTransform: transform)
                        points.append(world)
                    }
                }
            }
        }

        return SensorSnapshot(
            timestamp: frame.timestamp,
            intrinsics: intrinsics,
            transform: transform,
            imageResolution: imageRes,
            depthWidth: dw, depthHeight: dh,
            trackingQuality: ARSessionManager.describe(frame.camera.trackingState),
            sampleDepthGrid: grid,
            samplePoints: points)
    }

    /// Unprojects a normalized depth-buffer point + depth into ARKit world space.
    static func unprojectToWorld(nx: Float, ny: Float, depth d: Float,
                                 intrinsics: simd_float3x3,
                                 depthWidth: Int, depthHeight: Int,
                                 imageResolution: CGSize,
                                 cameraTransform: simd_float4x4) -> SIMD3<Float> {
        let sx = Float(depthWidth) / Float(imageResolution.width)
        let sy = Float(depthHeight) / Float(imageResolution.height)
        let fx = intrinsics[0][0] * sx
        let fy = intrinsics[1][1] * sy
        let cx = intrinsics[2][0] * sx
        let cy = intrinsics[2][1] * sy
        let u = nx * Float(depthWidth)
        let v = ny * Float(depthHeight)
        let xc = (u - cx) * d / fx
        let yc = (v - cy) * d / fy
        let camPoint = SIMD3<Float>(xc, -yc, -d)
        let world = cameraTransform * SIMD4<Float>(camPoint, 1)
        return SIMD3<Float>(world.x, world.y, world.z)
    }
}
