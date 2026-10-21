import CoreVideo
import Foundation
import ImageIO
import Testing
import UIKit
import simd
@testable import test

@MainActor
@Suite("Captured map colours")
struct MappingColorTests {
    private func image() throws -> CVPixelBuffer {
        var created: CVPixelBuffer?
        #expect(CVPixelBufferCreate(kCFAllocatorDefault, 4, 4, kCVPixelFormatType_32BGRA, nil, &created) == kCVReturnSuccess)
        let image = try #require(created)
        CVPixelBufferLockBaseAddress(image, [])
        defer { CVPixelBufferUnlockBaseAddress(image, []) }
        let base = try #require(CVPixelBufferGetBaseAddress(image))
        for y in 0..<4 { for x in 0..<4 {
            let offset = y * CVPixelBufferGetBytesPerRow(image) + x * 4
            base.storeBytes(of: UInt8(y < 2 ? 0 : 255), toByteOffset: offset, as: UInt8.self)
            base.storeBytes(of: UInt8(0), toByteOffset: offset + 1, as: UInt8.self)
            base.storeBytes(of: UInt8(y < 2 ? 255 : 0), toByteOffset: offset + 2, as: UInt8.self)
            base.storeBytes(of: UInt8(255), toByteOffset: offset + 3, as: UInt8.self)
        }}
        return image
    }

    private func confidence(_ value: UInt8 = 2) throws -> CVPixelBuffer {
        var created: CVPixelBuffer?
        #expect(CVPixelBufferCreate(kCFAllocatorDefault, 4, 4, kCVPixelFormatType_OneComponent8, nil, &created) == kCVReturnSuccess)
        let buffer = try #require(created)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = try #require(CVPixelBufferGetBaseAddress(buffer))
        base.initializeMemory(as: UInt8.self, repeating: value, count: CVPixelBufferGetBytesPerRow(buffer) * 4)
        return buffer
    }

    private func frame(confidence value: UInt8 = 2) throws -> MapColorFrame {
        MapColorFrame(image: try image(), depth: try #require(Fixtures.depthBuffer(width: 4, height: 4,
            values: Array(repeating: 2, count: 16))), confidence: try confidence(value),
            cameraTransform: matrix_identity_float4x4, intrinsics: matrix_identity_float3x3,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test func nativeProjectionUsesCameraForwardAndImageDownIncludingTranslatedPose() throws {
        let intrinsics = simd_float3x3(columns: (SIMD3(100, 0, 0), SIMD3(0, 100, 0), SIMD3(50, 50, 1)))
        var pose = matrix_identity_float4x4
        pose.columns.3.x = 10
        let point = try #require(MapColorSampling.project(SIMD3(10.2, 0.2, -2), worldToCamera: pose.inverse,
            intrinsics: intrinsics, width: 100, height: 100))
        #expect(abs(point.x - 60) < 0.001)
        #expect(abs(point.y - 40) < 0.001)
        #expect(point.depth == 2)
        #expect(MapColorSampling.project(SIMD3(0, 0, 2), worldToCamera: matrix_identity_float4x4,
            intrinsics: intrinsics, width: 100, height: 100) == nil)
        #expect(MapColorSampling.project(SIMD3(20, 0, -1), worldToCamera: matrix_identity_float4x4,
            intrinsics: intrinsics, width: 100, height: 100) == nil)
    }

    @Test func samplingMatchesNativeRowsAndRejectsOcclusionAndUnknownConfidence() throws {
        let id = UUID(), cell = try #require(MapColorCell(.zero))
        let candidates = [MapColorCandidate(anchorID: id, cell: cell, worldPosition: SIMD3(2, -2, -2)),
                          MapColorCandidate(anchorID: id, cell: cell, worldPosition: SIMD3(2, -6, -2)),
                          MapColorCandidate(anchorID: id, cell: cell, worldPosition: SIMD3(4, -4, -4))]
        let samples = MapColorSampling.sample(candidates, from: try frame())
        #expect(samples.count == 2)
        #expect(samples.first?.color == SIMD4<Float>(1, 0, 0, 1))
        #expect(samples.last?.color == SIMD4<Float>(0, 0, 1, 1))
        #expect(MapColorSampling.sample(candidates, from: try frame(confidence: 0)).isEmpty)
        let normal = try frame()
        let missing = MapColorFrame(image: normal.image, depth: normal.depth, confidence: nil,
            cameraTransform: normal.cameraTransform, intrinsics: normal.intrinsics, capturedAt: normal.capturedAt)
        #expect(MapColorSampling.sample(candidates, from: missing).isEmpty)
        #expect(!MapColorSampling.depthAgrees(projected: 1, measured: .nan, confidence: 2))
        #expect(!MapColorSampling.depthAgrees(projected: 1, measured: 2, confidence: 2))
    }

    @Test func fullRangeCameraYCbCrProducesRedInsteadOfFalseGreyscale() throws {
        var created: CVPixelBuffer?
        #expect(CVPixelBufferCreate(kCFAllocatorDefault, 4, 4, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            nil, &created) == kCVReturnSuccess)
        let image = try #require(created)
        CVPixelBufferLockBaseAddress(image, [])
        let y = try #require(CVPixelBufferGetBaseAddressOfPlane(image, 0))
        y.initializeMemory(as: UInt8.self, repeating: 76, count: CVPixelBufferGetBytesPerRowOfPlane(image, 0) * 4)
        let uv = try #require(CVPixelBufferGetBaseAddressOfPlane(image, 1))
        for row in 0..<2 { for col in 0..<2 {
            let offset = row * CVPixelBufferGetBytesPerRowOfPlane(image, 1) + col * 2
            uv.storeBytes(of: UInt8(85), toByteOffset: offset, as: UInt8.self)
            uv.storeBytes(of: UInt8(255), toByteOffset: offset + 1, as: UInt8.self)
        }}
        CVPixelBufferUnlockBaseAddress(image, [])
        let normal = try frame()
        let yuvFrame = MapColorFrame(image: image, depth: normal.depth, confidence: normal.confidence,
            cameraTransform: normal.cameraTransform, intrinsics: normal.intrinsics, capturedAt: normal.capturedAt)
        let candidate = MapColorCandidate(anchorID: UUID(), cell: try #require(MapColorCell(.zero)), worldPosition: SIMD3(2, -2, -2))
        let color = try #require(MapColorSampling.sample([candidate], from: yuvFrame).first?.color)
        #expect(color.x > 0.98 && color.y < 0.01 && color.z < 0.01 && color.w == 1)
    }

    @Test func cachePreservesFirstValidColourAcrossVertexReorderingAndFillsUnknowns() throws {
        let id = UUID(), first = try #require(MapColorCell(.zero)), second = try #require(MapColorCell(SIMD3(1, 0, 0)))
        var cache = MapColorCache()
        cache.merge([MapColorSample(anchorID: id, cell: first, color: SIMD4(1, 0, 0, 1))])
        cache.merge([MapColorSample(anchorID: id, cell: first, color: SIMD4(0, 0, 1, 1)),
                     MapColorSample(anchorID: id, cell: second, color: SIMD4(0, 1, 0, 1))])
        let mesh = MapMeshSnapshot(id: id, vertices: [1, 0, 0, 0, 0, 0, 2, 0, 0], triangleIndices: [0, 1, 2])
        let colors = try #require(cache.colors(for: mesh, worldToLocal: matrix_identity_float4x4))
        #expect(Array(colors[0..<4]) == [0, 1, 0, 1])
        #expect(Array(colors[4..<8]) == [1, 0, 0, 1])
        #expect(Array(colors[8..<12]) == [0, 0, 0, 0])
        #expect(cache.count == 2)
    }

    @Test func restoredSamplesTransferToLocalCellsAndSurviveAnchorTransformCorrection() throws {
        let id = UUID()
        var mesh = MapMeshSnapshot(id: id, vertices: [10, 0, 0], triangleIndices: [], vertexColors: [1, 0, 0, 1])
        var cache = MapColorCache()
        cache.restore([mesh])
        #expect(cache.containsOrAdopt(anchorID: id, localCell: try #require(MapColorCell(.zero)), worldPosition: SIMD3(10, 0, 0)))
        mesh.vertices = [12, 0, 0]; mesh.vertexColors = nil
        var transform = matrix_identity_float4x4; transform.columns.3.x = 12
        #expect(cache.colors(for: mesh, worldToLocal: transform.inverse) == [1, 0, 0, 1])
        #expect(cache.count == 1)
    }

    @Test func displayUsesNeutralOpaqueFallbackWithoutChangingCapturedValues() {
        let mesh = MapMeshSnapshot(id: UUID(), vertices: [0, 0, 0, 1, 0, 0], triangleIndices: [],
            vertexColors: [0.1, 0.4, 0.8, 1, 0, 0, 0, 0])
        #expect(MapColorRendering.displayColors(for: mesh) == [0.1, 0.4, 0.8, 1, 0.18, 0.18, 0.18, 1])
    }

    @Test func legacyGeometryAndMetadataDecodeWithEmptyNewFields() throws {
        let mesh = MapMeshSnapshot(id: UUID(), vertices: [0, 0, 0], triangleIndices: [])
        let geometry = SavedMapGeometry(meshes: [mesh], trail: [])
        var plist = try #require(PropertyListSerialization.propertyList(from: PropertyListEncoder().encode(geometry),
            format: nil) as? [String: Any])
        for key in ["keyframes", "navigation", "textAnnotations", "directionalSignage"] { plist.removeValue(forKey: key) }
        let bytes = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        #expect(try PropertyListDecoder().decode(SavedMapGeometry.self, from: bytes) == geometry)
        let metadata = SavedMapMetadata(id: UUID(), name: "Old place", createdAt: Date(), updatedAt: Date(),
            anchorCount: 1, vertexCount: 1, faceCount: 0)
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(metadata)) as? [String: Any])
        json.removeValue(forKey: "placeID"); json.removeValue(forKey: "segmentIndex")
        let decoded = try JSONDecoder().decode(SavedMapMetadata.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.placeID == nil && decoded.segmentIndex == 0)
    }

    @Test func cameraImagesAndColoursRoundTripAndSavePreparationDoesNotConsumePhotos() throws {
        let keyframe = try MapKeyframeEncoder.encode(frame())
        let mesh = MapMeshSnapshot(id: UUID(), vertices: [0, 0, 0], triangleIndices: [], vertexColors: [1, 0, 0, 1])
        let geometry = SavedMapGeometry(meshes: [mesh], trail: [], keyframes: [keyframe])
        try geometry.validate()
        #expect(try PropertyListDecoder().decode(SavedMapGeometry.self, from: PropertyListEncoder().encode(geometry)) == geometry)
        let capture = MappingColorCapture()
        capture.restore(geometry: geometry, generation: 3)
        #expect(capture.applying(to: geometry).keyframes == [keyframe])
        #expect(capture.applying(to: geometry).keyframes == [keyframe])
        #expect(capture.applying(to: geometry).meshes.first?.vertexColors == [1, 0, 0, 1])
    }

    @Test func portraitPhotoDisplaysUprightWithoutRotatingCalibrationPixels() throws {
        var portrait = try frame()
        portrait.imageOrientation = 6
        let photo = try MapKeyframeEncoder.encode(portrait)
        let source = try #require(CGImageSourceCreateWithData(photo.jpegData as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect((properties[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value == 6)
        #expect(UIImage(data: photo.jpegData)?.imageOrientation == .right)
        #expect(photo.imageWidth == 4 && photo.imageHeight == 4)
        #expect(photo.intrinsics == [1, 0, 0, 0, 1, 0, 0, 0, 1])
    }

    @Test func rejectsMismatchedColourCountsInvalidColoursAndInvalidCameraImages() throws {
        var mesh = MapMeshSnapshot(id: UUID(), vertices: [0, 0, 0], triangleIndices: [], vertexColors: [1, 0, 0])
        #expect(throws: MapStorageError.self) { try SavedMapGeometry(meshes: [mesh], trail: []).validate() }
        mesh.vertexColors = [Float.nan, 0, 0, 1]
        #expect(throws: MapStorageError.self) { try SavedMapGeometry(meshes: [mesh], trail: []).validate() }
        mesh.vertexColors = [1, 0, 0, 0.5]
        #expect(throws: MapStorageError.self) { try SavedMapGeometry(meshes: [mesh], trail: []).validate() }
        var keyframe = try MapKeyframeEncoder.encode(frame())
        keyframe.imageWidth += 1
        #expect(throws: MapStorageError.self) { try keyframe.validate() }
        keyframe.jpegData = Data([1, 2, 3])
        #expect(throws: MapStorageError.self) { try keyframe.validate() }
    }
}
