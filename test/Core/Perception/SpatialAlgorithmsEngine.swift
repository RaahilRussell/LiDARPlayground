//
//  SpatialAlgorithmsEngine.swift
//  test
//
//  Phase 4 — drives floor-plane estimation, ground/elevated split, clustering,
//  occupancy, and object tracking on the live frame, and publishes a snapshot
//  for the 3D debug scene. Runs on its own throttled path.
//

import ARKit
import Observation
import QuartzCore
import simd

/// Immutable snapshot consumed by the SceneKit debug view.
struct SpatialSnapshot {
    var groundPoints: [SIMD3<Float>] = []
    var elevatedPoints: [SIMD3<Float>] = []
    var clusters: [PointCluster] = []
    var floor: FloorPlane?
    var cameraTransform: simd_float4x4 = matrix_identity_float4x4
    var tracked: [TrackedObject] = []
}

@MainActor
@Observable
final class SpatialAlgorithmsEngine {
    private(set) var floor: FloorPlane?
    private(set) var clusters: [PointCluster] = []
    private(set) var occupancy: [RegionOccupancy] = []
    private(set) var tracked: [TrackedObject] = []
    private(set) var snapshot = SpatialSnapshot()
    private(set) var lastMs: Double = 0
    var stride: Int = 6

    private weak var provider: ARSensorProvider?
    private weak var fusion: SpatialFusionEngine?
    private var tracker = ObjectTracker()
    private var loopTask: Task<Void, Never>?
    private var isWorking = false

    func attach(provider: ARSensorProvider, fusion: SpatialFusionEngine) {
        self.provider = provider
        self.fusion = fusion
    }

    var isRunning: Bool { loopTask != nil }

    func start() {
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in await self?.loop() }
    }
    func stop() {
        loopTask?.cancel(); loopTask = nil
        tracker.reset(); tracked = []
    }

    private func loop() async {
        while !Task.isCancelled {
            await tick()
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    private func tick() async {
        guard !isWorking, let provider, provider.isRunning, let frame = provider.snapshot(),
              let depthMap = frame.smoothedDepthMap ?? frame.depthMap else { return }
        isWorking = true
        defer { isWorking = false }

        // Reset tracker if tracking degraded (don't emit confident motion on bad pose).
        if !frame.trackingIsNormal { tracker.reset() }

        let s = self.stride
        let start = CACurrentMediaTime()
        let computed = await Self.compute(frame: frame, depthMap: depthMap, stride: s)
        lastMs = (CACurrentMediaTime() - start) * 1000

        floor = computed.floor
        clusters = computed.clusters
        occupancy = computed.occupancy

        let now = CACurrentMediaTime()
        let obs = fusion?.observations ?? []
        tracked = tracker.update(with: obs, now: now)

        snapshot = SpatialSnapshot(groundPoints: computed.ground, elevatedPoints: computed.elevated,
                                   clusters: computed.clusters, floor: computed.floor,
                                   cameraTransform: frame.cameraTransform, tracked: tracked)
    }

    // MARK: - Off-main compute

    private struct Computed {
        var ground: [SIMD3<Float>]; var elevated: [SIMD3<Float>]
        var clusters: [PointCluster]; var floor: FloorPlane?; var occupancy: [RegionOccupancy]
    }

    nonisolated private static func compute(frame: SensorFrame, depthMap: CVPixelBuffer,
                                            stride: Int) async -> Computed {
        await Task.detached(priority: .userInitiated) {
            let dw = CVPixelBufferGetWidth(depthMap)
            let dh = CVPixelBufferGetHeight(depthMap)
            CVPixelBufferLockBaseAddress(depthMap, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
            if let c = frame.confidenceMap { CVPixelBufferLockBaseAddress(c, .readOnly) }
            defer { if let c = frame.confidenceMap { CVPixelBufferUnlockBaseAddress(c, .readOnly) } }

            guard let dbase = CVPixelBufferGetBaseAddress(depthMap) else {
                return Computed(ground: [], elevated: [], clusters: [], floor: nil, occupancy: [])
            }
            let drb = CVPixelBufferGetBytesPerRow(depthMap)
            let cbase = frame.confidenceMap.flatMap { CVPixelBufferGetBaseAddress($0) }
            let crb = frame.confidenceMap.map { CVPixelBufferGetBytesPerRow($0) } ?? 0

            let sx = Float(dw) / Float(frame.imageResolution.width)
            let sy = Float(dh) / Float(frame.imageResolution.height)
            let fx = frame.intrinsics[0][0] * sx, fy = frame.intrinsics[1][1] * sy
            let cx = frame.intrinsics[2][0] * sx, cy = frame.intrinsics[2][1] * sy
            let T = frame.cameraTransform
            let useWorld = frame.trackingIsNormal

            var worldPoints = [SIMD3<Float>](), cameraPoints = [SIMD3<Float>](), confs = [Float]()
            var y = 0
            while y < dh {
                let drow = dbase.advanced(by: y * drb).assumingMemoryBound(to: Float32.self)
                let crow = cbase?.advanced(by: y * crb).assumingMemoryBound(to: UInt8.self)
                var x = 0
                while x < dw {
                    let d = drow[x]
                    if d.isFinite && d > 0 {
                        let xc = (Float(x) - cx) * d / fx
                        let yc = (Float(y) - cy) * d / fy
                        let cam = SIMD3<Float>(xc, -yc, -d)
                        // Occupancy reads x as left/right and y as up. ARKit camera
                        // axes are fixed to the sensor, so in portrait camera +y is
                        // the user's right and camera −x is up: rotate into that view frame.
                        cameraPoints.append(SIMD3<Float>(cam.y, -cam.x, cam.z))
                        confs.append(crow.map { Float($0[x]) / 2 } ?? 1)
                        if useWorld {
                            let w = T * SIMD4<Float>(cam, 1)
                            worldPoints.append(SIMD3(w.x, w.y, w.z))
                        }
                    }
                    x += stride
                }
                y += stride
            }

            let pointsForGeom = useWorld ? worldPoints : cameraPoints
            let floor = SpatialAlgorithms.estimateFloor(points: pointsForGeom)
            var ground = [SIMD3<Float>](), elevated = pointsForGeom
            if let floor {
                let split = SpatialAlgorithms.classifyGround(points: pointsForGeom, floor: floor)
                ground = split.ground; elevated = split.elevated
            }
            let clusters = SpatialAlgorithms.cluster(points: elevated)
            let occupancy = SpatialAlgorithms.occupancy(cameraPoints: cameraPoints, confidences: confs)
            return Computed(ground: ground, elevated: elevated, clusters: clusters,
                            floor: floor, occupancy: occupancy)
        }.value
    }
}
