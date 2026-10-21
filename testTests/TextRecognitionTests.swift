import CoreGraphics
import Foundation
import ImageIO
import Testing
import UIKit
import CoreVideo
import simd
@testable import test

struct TextRecognitionTests {
    @Test @MainActor func visionRecognizesLocalImageWithoutInventingDepth() throws {
        let width = 1_000, height = 500
        let size = CGSize(width: CGFloat(width), height: CGFloat(height))
        let image = UIGraphicsImageRenderer(size: size).image { context in
            UIColor.white.setFill()
            context.cgContext.fill(CGRect(origin: .zero, size: size))
            ("RESTROOM" as NSString).draw(at: CGPoint(x: 80, y: 180), withAttributes: [
                .font: UIFont.boldSystemFont(ofSize: 90), .foregroundColor: UIColor.black])
        }
        let cgImage = try #require(image.cgImage)
        var buffer: CVPixelBuffer?
        let result = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary, &buffer)
        #expect(result == kCVReturnSuccess)
        let pixels = try #require(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        let context = try #require(CGContext(data: CVPixelBufferGetBaseAddress(pixels), width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixels), space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
        context.draw(cgImage, in: CGRect(origin: .zero, size: size))
        CVPixelBufferUnlockBaseAddress(pixels, [])
        let frame = SensorFrame(capturedImage: pixels, depthMap: nil, confidenceMap: nil,
            rawConfidenceMap: nil, smoothedDepthMap: nil, intrinsics: matrix_identity_float3x3,
            imageResolution: size, cameraTransform: matrix_identity_float4x4,
            timestamp: 1, trackingIsNormal: true)
        let recognized = try TextRecognitionWorker.recognize(frame: frame, orientation: .up)
        #expect(recognized.annotations.contains { $0.text.uppercased().contains("RESTROOM") })
        #expect(recognized.annotations.allSatisfy { $0.worldPosition == nil })
        #expect(recognized.imageJPEG != nil)
    }

    @Test func extractsExplicitArrowsWithoutGuessingWords() {
        #expect(SignArrowDetector.glyphDirections(in: "Restroom →") == [.right])
        #expect(SignArrowDetector.glyphDirections(in: "↑ Bathroom ↓") == [.up, .down])
        #expect(SignArrowDetector.glyphDirections(in: "Turn right upstairs") == [])
    }

    @Test func filledArrowContoursRespectUprightImageDirections() {
        let arrow = [CGPoint(x: 0, y: 0.3), CGPoint(x: 0.55, y: 0.3), CGPoint(x: 0.55, y: 0),
                     CGPoint(x: 1, y: 0.5), CGPoint(x: 0.55, y: 1), CGPoint(x: 0.55, y: 0.7), CGPoint(x: 0, y: 0.7)]
        let right = arrow.map { CGPoint(x: $0.x * 2, y: $0.y) }
        #expect(SignArrowDetector.classify(polygon: right) == .right)
        #expect(SignArrowDetector.classify(polygon: right.map { CGPoint(x: 2 - $0.x, y: $0.y) }) == .left)
        #expect(SignArrowDetector.classify(polygon: right.map { CGPoint(x: $0.y, y: $0.x) }) == .down)
        #expect(SignArrowDetector.classify(polygon: right.map { CGPoint(x: $0.y, y: 2 - $0.x) }) == .up)
    }

    @Test func rectangleAndTriangleAreNotArrows() {
        #expect(SignArrowDetector.classify(polygon: [CGPoint(x: 0, y: 0), CGPoint(x: 2, y: 0), CGPoint(x: 2, y: 1), CGPoint(x: 0, y: 1)]) == nil)
        #expect(SignArrowDetector.classify(polygon: [CGPoint(x: 0, y: 0), CGPoint(x: 2, y: 0.5), CGPoint(x: 0, y: 1)]) == nil)
    }

    @Test func arrowAssociatesOnlyWithUnambiguousNearbyText() {
        let arrow = CGRect(x: 0.7, y: 0.4, width: 0.1, height: 0.1)
        #expect(SignArrowDetector.nearestText(to: arrow, texts: [CGRect(x: 0.2, y: 0.4, width: 0.4, height: 0.1)]) == 0)
        #expect(SignArrowDetector.nearestText(to: arrow, texts: [CGRect(x: 0.2, y: 0.4, width: 0.4, height: 0.1), CGRect(x: 0.9, y: 0.4, width: 0.09, height: 0.1)]) == nil)
        #expect(SignArrowDetector.nearestText(to: arrow, texts: [CGRect(x: 0, y: 0, width: 0.1, height: 0.05)]) == nil)
    }

    @Test func orientationInversionMatchesCameraDepthCoordinates() {
        let p = CGPoint(x: 0.2, y: 0.3)
        #expect(TextRecognitionWorker.rawPoint(p, orientation: .right) == CGPoint(x: 0.3, y: 0.8))
        #expect(TextRecognitionWorker.rawPoint(p, orientation: .left) == CGPoint(x: 0.7, y: 0.2))
        #expect(TextRecognitionWorker.rawPoint(p, orientation: .down) == CGPoint(x: 0.8, y: 0.7))
        #expect(TextRecognitionWorker.rawPoint(p, orientation: .up) == p)
    }

    @Test func identicalSignsInDifferentPlacesRemainSeparate() {
        let a = annotation(position: MapPosition(x: 0, y: 1, z: 0))
        var b = a
        b.worldPosition = MapPosition(x: 3, y: 1, z: 0)
        #expect(!TextAnnotationMatching.isSamePhysicalText(a, b))
        b.worldPosition = MapPosition(x: 0.1, y: 1, z: 0)
        #expect(TextAnnotationMatching.isSamePhysicalText(a, b))
    }

    @Test func noDepthDoesNotMergeOppositeViewpoints() {
        let a = annotation(position: nil)
        var b = a
        b.observedDirection = MapPosition(x: 0, y: 0, z: 1)
        #expect(!TextAnnotationMatching.isSamePhysicalText(a, b))
    }

    @Test func textAndDirectionRoundTripAsSeparateData() throws {
        let text = annotation(position: nil)
        let sign = SavedDirectionalSignage(textAnnotationID: text.id, text: text.text, direction: .right,
            arrowBounds: text.bounds, confidence: 0.7, source: .contourShape, lastSeen: text.lastSeen)
        let geometry = SavedMapGeometry(meshes: [], trail: [], textAnnotations: [text], directionalSignage: [sign])
        let data = try PropertyListEncoder().encode(geometry)
        let decoded = try PropertyListDecoder().decode(SavedMapGeometry.self, from: data)
        #expect(decoded.textAnnotations == [text])
        #expect(decoded.directionalSignage == [sign])
        try decoded.validate()
    }

    @Test func invalidTextBoundsAreRejected() {
        var text = annotation(position: nil)
        text.bounds = TextImageBounds(CGRect(x: -1, y: 0, width: 2, height: 1))
        #expect(throws: MapStorageError.self) { try text.validate() }
    }

    @Test func exportedDataSeparatesSignsAndOmitsImageBytes() throws {
        var text = annotation(position: nil)
        text.evidenceJPEG = Data([1, 2, 3])
        let sign = SavedDirectionalSignage(textAnnotationID: text.id, text: text.text, direction: .left,
            arrowBounds: text.bounds, confidence: 0.8, source: .recognizedGlyph, lastSeen: text.lastSeen)
        let encoded = try TextObservationExport.encode(annotations: [text], signage: [sign])
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let texts = try #require(object["textAnnotations"] as? [[String: Any]])
        let signs = try #require(object["directionalSignage"] as? [[String: Any]])
        #expect(texts.count == 1 && signs.count == 1)
        #expect(texts[0]["evidenceJPEG"] == nil)
        #expect(signs[0]["direction"] as? String == "left")
        #expect(signs[0]["textAnnotationID"] as? String == text.id.uuidString)
    }

    private func annotation(position: MapPosition?) -> SavedTextAnnotation {
        let now = Date(timeIntervalSince1970: 1_000)
        return SavedTextAnnotation(text: "Restroom", confidence: 0.9,
            bounds: TextImageBounds(CGRect(x: 0.2, y: 0.3, width: 0.4, height: 0.1)),
            worldPosition: position, observedFrom: MapPosition(x: 0, y: 1, z: 2),
            observedDirection: MapPosition(x: 0, y: 0, z: -1), firstSeen: now, lastSeen: now)
    }
}
