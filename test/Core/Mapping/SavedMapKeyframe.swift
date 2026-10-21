import Foundation
import ImageIO

/// A calibrated camera observation. JPEG pixels and intrinsics use the native
/// sensor orientation (EXIF up), not a cropped or rotated screen preview.
/// Matrix arrays are column-major; the pose maps camera coordinates to world.
nonisolated struct SavedMapKeyframe: Codable, Identifiable, Sendable, Equatable {
    var id: UUID
    var capturedAt: Date
    var cameraTransform: [Float]
    var intrinsics: [Float]
    var imageWidth: Int
    var imageHeight: Int
    var jpegData: Data

    func validate() throws {
        guard capturedAt.timeIntervalSince1970.isFinite,
              cameraTransform.count == 16, intrinsics.count == 9,
              cameraTransform.allSatisfy(\.isFinite), intrinsics.allSatisfy(\.isFinite),
              intrinsics[0] > 0, intrinsics[4] > 0,
              abs(cameraTransform[3]) < 0.001, abs(cameraTransform[7]) < 0.001,
              abs(cameraTransform[11]) < 0.001, abs(cameraTransform[15] - 1) < 0.001,
              cameraTransform[12...14].allSatisfy({ abs($0) <= MapLimits.maxCoordinateMagnitude }),
              (1...2_048).contains(imageWidth), (1...2_048).contains(imageHeight) else {
            throw MapStorageError.invalidGeometry("invalid camera image calibration")
        }
        guard !jpegData.isEmpty, jpegData.count <= MapLimits.maxKeyframeBytes else {
            throw MapStorageError.tooLarge("camera image")
        }
        guard let source = CGImageSourceCreateWithData(jpegData as CFData, nil),
              CGImageSourceGetType(source) as String? == "public.jpeg",
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.intValue == imageWidth, height.intValue == imageHeight else {
            throw MapStorageError.invalidGeometry("camera image dimensions or format do not match")
        }
    }
}
