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

    private func fuse(confidence: UInt8?, tracking: Bool = true) throws -> ObjectObservation {
        let depth = try #require(Fixtures.depthBuffer(width: 4, height: 4,
                                                     values: Array(repeating: 2, count: 16)))
        let frame = SensorFrame(capturedImage: depth, depthMap: depth,
            confidenceMap: try confidence.map { try confidenceBuffer($0) }, rawConfidenceMap: nil,
            smoothedDepthMap: nil,
            intrinsics: simd_float3x3(columns: (SIMD3(4, 0, 0), SIMD3(0, 4, 0), SIMD3(2, 2, 1))),
            imageResolution: CGSize(width: 4, height: 4), cameraTransform: matrix_identity_float4x4,
            timestamp: 10, trackingIsNormal: tracking)
        let object = DetectedObject(id: 1, label: "chair", confidence: 0.9,
                                    boxNormalized: CGRect(x: 0, y: 0, width: 1, height: 1), mask: nil)
        return try #require(SpatialFusionEngine.fuse(objects: [object], frame: frame, depthMap: depth,
                                                    erosion: 0, minCoverage: 0.2, nearPct: 0.15).first)
    }

    @Test func lowAndMissingConfidenceCannotProduceWorldHazards() throws {
        for confidence: UInt8? in [0, nil] {
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
}
