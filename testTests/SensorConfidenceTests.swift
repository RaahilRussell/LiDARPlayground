import ARKit
import CoreGraphics
import CoreVideo
import Foundation
import Testing
import simd
@testable import test

@MainActor
@Suite("Diagnostic sensor confidence")
struct SensorConfidenceTests {
    @Test func missingConfidenceIsExcludedOnlyWhenDepthFilterIsEnabled() throws {
        let depth = try #require(Fixtures.depthBuffer(width: 2, height: 2, values: [2, 2, 2, 2]))
        let filtered = DepthProcessing.computeStats(depth: depth, confidence: nil, minConfidence: .medium)
        let raw = DepthProcessing.computeStats(depth: depth, confidence: nil, minConfidence: nil)
        #expect(filtered.validFraction == 0)
        #expect(raw.validFraction == 1)
        #expect(raw.minMeters == 2)

        let image = try #require(DepthProcessing.makeHeatmap(depth: depth, confidence: nil,
            mode: .depth(range: 0...5), minConfidence: .medium))
        let data = try #require(image.dataProvider?.data) as Data
        #expect(Array(data.prefix(4)) == [255, 0, 180, 255], "unknown confidence must use the invalid colour")
    }

    @Test func pointCloudRequiresKnownConfidenceOnlyWhenFilterIsEnabled() throws {
        let depth = try #require(Fixtures.depthBuffer(width: 2, height: 2, values: [2, 2, 2, 2]))
        var created: CVPixelBuffer?
        let result = CVPixelBufferCreate(kCFAllocatorDefault, 2, 2, kCVPixelFormatType_32BGRA, nil, &created)
        #expect(result == kCVReturnSuccess)
        let image = try #require(created)
        CVPixelBufferLockBaseAddress(image, [])
        if let base = CVPixelBufferGetBaseAddress(image) {
            base.initializeMemory(as: UInt8.self, repeating: 0,
                                  count: CVPixelBufferGetBytesPerRow(image) * 2)
        }
        CVPixelBufferUnlockBaseAddress(image, [])

        func cloud(minimum: Int) -> PointCloud {
            PointCloudGenerator.generate(PointCloudInput(depth: depth, confidence: nil,
                capturedImage: image, intrinsics: matrix_identity_float3x3,
                imageResolution: CGSize(width: 2, height: 2), cameraTransform: matrix_identity_float4x4,
                worldSpace: false, stride: 1, maxPoints: 10, minConfidence: minimum))
        }
        #expect(cloud(minimum: ARConfidenceLevel.high.rawValue).count == 0)
        #expect(cloud(minimum: -1).count == 4)
    }
}
