//
//  SpatialAlgorithmTests.swift
//  testTests
//
//  Phase 9 — floor fitting, ground split, clustering, honest occupancy,
//  unprojection math, and short-term tracking on deterministic fixtures.
//

import CoreGraphics
import Foundation
import simd
import Testing
@testable import test

@MainActor
@Suite("Spatial algorithms")
struct SpatialAlgorithmTests {

    // MARK: Floor

    @Test func ransacFindsFloorDespiteOutliers() throws {
        var points = Fixtures.floorPoints(y: -1.2)                       // 400 floor points
        points += Fixtures.blob(at: SIMD3(0, -0.4, -1.5), n: 4)          // 64 elevated outliers
        var rng = SeededGenerator(seed: 42)
        let floor = try #require(SpatialAlgorithms.estimateFloor(points: points, iterations: 120, using: &rng))
        #expect(floor.normal.y > 0.99)
        #expect(abs(floor.d - 1.2) < 0.02)          // n·p + d = 0 → y = −1.2
        #expect(floor.inliers >= 400)
    }

    @Test func ransacIsDeterministicWithSameSeed() {
        let points = Fixtures.floorPoints() + Fixtures.blob(at: SIMD3(0.3, -0.6, -1), n: 4)
        var a = SeededGenerator(seed: 7), b = SeededGenerator(seed: 7)
        let fa = SpatialAlgorithms.estimateFloor(points: points, using: &a)
        let fb = SpatialAlgorithms.estimateFloor(points: points, using: &b)
        #expect(fa?.inliers == fb?.inliers)
        #expect(fa?.d == fb?.d)
    }

    @Test func ransacRejectsTooFewPointsAndWalls() {
        var rng = SeededGenerator(seed: 1)
        #expect(SpatialAlgorithms.estimateFloor(points: Array(Fixtures.floorPoints().prefix(49)), using: &rng) == nil)
        // A vertical wall (z = −2) has a horizontal normal → never a floor.
        let wall = Fixtures.floorPoints().map { SIMD3<Float>($0.x, $0.z + 2, -2) }
        #expect(SpatialAlgorithms.estimateFloor(points: wall, using: &rng) == nil)
    }

    @Test func groundSplitUsesSignedDistance() {
        let floor = FloorPlane(normal: SIMD3(0, 1, 0), d: 1.2, inliers: 100)
        let split = SpatialAlgorithms.classifyGround(points: [SIMD3(0, -1.2, -1), SIMD3(0, -0.5, -1), SIMD3(0, -1.6, -1)],
                                                     floor: floor)
        #expect(split.ground.count == 1)
        #expect(split.elevated == [SIMD3(0, -0.5, -1)])  // below-floor point is neither
    }

    // MARK: Clustering

    @Test func clusteringSeparatesBlobsAndDropsSmallOnes() {
        let a = Fixtures.blob(at: SIMD3(0, 0, -1), n: 3)           // 27 pts
        let b = Fixtures.blob(at: SIMD3(1.5, 0, -1), n: 3)         // 27 pts, far away
        let speck = Array(Fixtures.blob(at: SIMD3(-2, 0, -1), n: 2).prefix(3))
        let clusters = SpatialAlgorithms.cluster(points: a + b + speck, voxel: 0.15, minPoints: 10)
        #expect(clusters.count == 2)
        #expect(clusters.allSatisfy { $0.count == 27 })
        #expect(SpatialAlgorithms.cluster(points: []).isEmpty)
    }

    // MARK: Occupancy (unobserved is never free)

    @Test func emptyInputIsUnknownEverywhere() {
        let occ = SpatialAlgorithms.occupancy(cameraPoints: [], confidences: [])
        #expect(occ.map(\.occupancy) == [.unknown, .unknown, .unknown])
        #expect(occ.allSatisfy { $0.nearestMeters == nil })
    }

    @Test func occupancyClassesPerRegion() {
        let left = Fixtures.pointsAhead(3.0, azimuth: -0.5)                 // far → observed free
        let center = Fixtures.pointsAhead(0.6)                              // near → occupied
        let right = Fixtures.pointsAhead(0.8, azimuth: 0.5)                 // near but low confidence
        let confs = [Float](repeating: 1, count: 20) + [Float](repeating: 0.2, count: 10)
        let occ = SpatialAlgorithms.occupancy(cameraPoints: left + center + right, confidences: confs)
        let byRegion = Dictionary(uniqueKeysWithValues: occ.map { ($0.id, $0) })
        #expect(byRegion[.left]?.occupancy == .observedFree)
        #expect(byRegion[.center]?.occupancy == .occupied)
        #expect(byRegion[.right]?.occupancy == .lowConfidence)
        #expect(abs((byRegion[.center]?.nearestMeters ?? 0) - 0.6) < 1e-5)
    }

    @Test func pointsBehindCameraAndSparseRegionsStayUnknown() {
        let behind = (0..<10).map { _ in SIMD3<Float>(0, 0, 1) }           // z > 0 → behind
        let sparse = Fixtures.pointsAhead(0.5, count: 4)                    // < 5 samples
        let occ = SpatialAlgorithms.occupancy(cameraPoints: behind + sparse,
                                              confidences: [Float](repeating: 1, count: 14))
        #expect(occ.first { $0.id == .center }?.occupancy == .unknown)
    }

    // MARK: Unprojection

    @Test func principalPointUnprojectsOnAxis() {
        let K = simd_float3x3(SIMD3(1000, 0, 0), SIMD3(0, 1000, 0), SIMD3(960, 720, 1))
        let p = SpatialFusionEngine.unprojectCamera(nx: 0.5, ny: 0.5, depth: 2, intrinsics: K,
                                                    dw: 256, dh: 192, imageRes: CGSize(width: 1920, height: 1440))
        #expect(abs(p.x) < 1e-4 && abs(p.y) < 1e-4)
        #expect(p.z == -2)
    }

    @Test func worldUnprojectionAppliesCameraTranslation() {
        let K = simd_float3x3(SIMD3(1000, 0, 0), SIMD3(0, 1000, 0), SIMD3(960, 720, 1))
        var T = matrix_identity_float4x4
        T.columns.3 = SIMD4(1, 2, 3, 1)
        let w = ARSessionManager.unprojectToWorld(nx: 0.5, ny: 0.5, depth: 2, intrinsics: K,
                                                  depthWidth: 256, depthHeight: 192,
                                                  imageResolution: CGSize(width: 1920, height: 1440),
                                                  cameraTransform: T)
        #expect(simd_distance(w, SIMD3(1, 2, 1)) < 1e-4)
    }

    @Test func percentileClampsAndIndexes() {
        let sorted: [Float] = [1, 2, 3, 4, 5]
        #expect(SpatialFusionEngine.percentile(sorted, 0) == 1)
        #expect(SpatialFusionEngine.percentile(sorted, 0.5) == 3)
        #expect(SpatialFusionEngine.percentile(sorted, 2) == 5)
        #expect(SpatialFusionEngine.percentile([], 0.5).isNaN)
    }

    // MARK: Tracking

    @Test func trackerAssociatesEstimatesVelocityAndExpires() {
        var tracker = ObjectTracker()
        let first = tracker.update(with: [Fixtures.observation(id: 0, at: SIMD3(0, 0, -2))], now: 10)
        #expect(first.count == 1)
        let id = first[0].id

        let moved = tracker.update(with: [Fixtures.observation(id: 0, at: SIMD3(0.3, 0, -2))], now: 10.5)
        #expect(moved.count == 1 && moved[0].id == id && moved[0].hits == 2)
        #expect(abs(moved[0].speed - 0.6) < 1e-4)

        let jumped = tracker.update(with: [Fixtures.observation(id: 1, at: SIMD3(5, 0, -2))], now: 10.6)
        #expect(jumped.count == 2, "outside the gate → new track")

        let expired = tracker.update(with: [], now: 12)
        #expect(expired.isEmpty, "tracks unseen longer than maxAge are dropped")
    }
}
