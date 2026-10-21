import CoreGraphics
import CoreVideo
import Foundation
import Testing
import simd
@testable import test

@MainActor
@Suite("Perception freshness and confidence")
struct PerceptionFreshnessTests {
    @Test func staleFutureAndInvalidTimestampsAreRejected() {
        #expect(ARSensorProvider.isFresh(timestamp: 10, now: 10.2))
        #expect(!ARSensorProvider.isFresh(timestamp: 10, now: 10.6))
        #expect(!ARSensorProvider.isFresh(timestamp: 11, now: 10))
        #expect(!ARSensorProvider.isFresh(timestamp: .nan, now: 10))
        #expect(!ARSensorProvider.isFresh(timestamp: 10, now: .infinity))
    }

    private func confidenceBuffer(_ confidence: UInt8) throws -> CVPixelBuffer {
        var result: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, 4, 4, kCVPixelFormatType_OneComponent8,
                                        nil, &result)
        #expect(status == kCVReturnSuccess)
        let buffer = try #require(result)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = try #require(CVPixelBufferGetBaseAddress(buffer))
        for row in 0..<4 {
            base.advanced(by: row * CVPixelBufferGetBytesPerRow(buffer))
                .assumingMemoryBound(to: UInt8.self).initialize(repeating: confidence, count: 4)
        }
        return buffer
    }

    private func observations(confidence: UInt8?, tracking: Bool = true,
                              box: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)) throws -> [ObjectObservation] {
        let depth = try #require(Fixtures.depthBuffer(width: 4, height: 4,
                                                     values: Array(repeating: 2, count: 16)))
        let frame = SensorFrame(capturedImage: depth, depthMap: depth,
            confidenceMap: try confidence.map { try confidenceBuffer($0) }, rawConfidenceMap: nil,
            smoothedDepthMap: nil,
            intrinsics: simd_float3x3(columns: (SIMD3(4, 0, 0), SIMD3(0, 4, 0), SIMD3(2, 2, 1))),
            imageResolution: CGSize(width: 4, height: 4), cameraTransform: matrix_identity_float4x4,
            timestamp: 10, trackingIsNormal: tracking)
        let object = DetectedObject(id: 1, label: "chair", confidence: 0.9,
                                    boxNormalized: box, mask: nil)
        return SpatialFusionEngine.fuse(objects: [object], frame: frame, depthMap: depth,
                                        erosion: 0, minCoverage: 0.2, nearPct: 0.15)
    }

    private func fuse(confidence: UInt8?, tracking: Bool = true) throws -> ObjectObservation {
        try #require(observations(confidence: confidence, tracking: tracking).first)
    }

    @Test func lowAndMissingConfidenceCannotProduceWorldHazards() throws {
        let levels: [UInt8?] = [0, nil]
        for confidence in levels {
            let observation = try fuse(confidence: confidence)
            #expect(observation.uncertain)
            #expect(observation.validDepthCoverage == 0)
            #expect(observation.nearestMeters.isNaN)
            #expect(observation.positionWorld == nil)
        }
    }

    @Test func confidentDepthUsesMetricCameraCoordinates() throws {
        let observation = try fuse(confidence: 2)
        #expect(!observation.uncertain)
        #expect(observation.nearestMeters == 2)
        #expect(observation.validDepthCoverage == 1)
        #expect(observation.positionWorld == SIMD3<Float>(0, 0, -2))
        #expect(try fuse(confidence: 2, tracking: false).positionWorld == nil)
    }

    @Test func malformedDetectorBoxesAreRejectedBeforePixelIndexing() throws {
        #expect(try observations(confidence: 2,
                                 box: CGRect(x: CGFloat.nan, y: 0, width: 1, height: 1)).isEmpty)
        #expect(try observations(confidence: 2,
                                 box: CGRect(x: 5, y: 5, width: 1, height: 1)).isEmpty)
        let clipped = try #require(observations(confidence: 2,
            box: CGRect(x: -0.5, y: -0.5, width: 2, height: 2)).first)
        #expect(!clipped.uncertain && clipped.nearestMeters == 2)
    }

    @Test func liveGeometryRespectsCautionDistanceBeyondOccupancyThreshold() throws {
        let occupancy = SpatialAlgorithms.occupancy(cameraPoints: Fixtures.pointsAhead(1.5),
                                                    confidences: Array(repeating: 1, count: 10))
        #expect(occupancy.first { $0.id == .center }?.occupancy == .observedFree)
        let input = try #require(ProximityDriver.occupancyInput(from: occupancy, cautionDistance: 2))
        var machine = ProximityStateMachine()
        machine.step(nearest: input.meters, confidence: input.confidence)
        #expect(machine.state == .caution)
    }

    @Test func distantSideObservationCannotClearUnknownForwardPath() {
        let occupancy = SpatialAlgorithms.occupancy(cameraPoints: Fixtures.pointsAhead(3, azimuth: 0.6),
                                                    confidences: Array(repeating: 1, count: 10))
        #expect(occupancy.first { $0.id == .center }?.occupancy == .unknown)
        #expect(ProximityDriver.occupancyInput(from: occupancy, cautionDistance: 2) == nil)
    }
}
