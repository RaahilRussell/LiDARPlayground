import Foundation
import CoreGraphics
import ImageIO

/// All rectangles are normalized to the upright evidence image, top-left origin.
nonisolated struct TextImageBounds: Codable, Sendable, Equatable {
    var x: Float
    var y: Float
    var width: Float
    var height: Float

    init(_ rect: CGRect) {
        x = Float(rect.minX); y = Float(rect.minY)
        width = Float(rect.width); height = Float(rect.height)
    }

    var rect: CGRect { CGRect(x: CGFloat(x), y: CGFloat(y), width: CGFloat(width), height: CGFloat(height)) }
    var isValid: Bool {
        [x, y, width, height].allSatisfy(\.isFinite) && x >= 0 && y >= 0 &&
        width > 0 && height > 0 && x + width <= 1.001 && y + height <= 1.001
    }
}

nonisolated enum SignArrowDirection: String, Codable, Sendable, CaseIterable {
    case up, down, left, right

    var symbol: String {
        switch self { case .up: "↑"; case .down: "↓"; case .left: "←"; case .right: "→" }
    }
}

nonisolated struct SavedTextAnnotation: Codable, Identifiable, Sendable, Equatable {
    var id: UUID = UUID()
    var text: String
    var confidence: Float
    var bounds: TextImageBounds
    var worldPosition: MapPosition?
    var observedFrom: MapPosition
    var observedDirection: MapPosition? = nil
    var firstSeen: Date
    var lastSeen: Date
    var observationCount: Int = 1
    /// Upright image of the observation, never an ARFrame or live buffer.
    var evidenceJPEG: Data?

    func validate() throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 2_000,
              confidence.isFinite, (0...1).contains(confidence), bounds.isValid,
              worldPosition?.isValid != false, observedFrom.isValid, observedDirection?.isValid != false,
              firstSeen.timeIntervalSince1970.isFinite, lastSeen.timeIntervalSince1970.isFinite,
              lastSeen >= firstSeen, observationCount > 0,
              (evidenceJPEG?.count ?? 0) <= 512 * 1_024 else {
            throw MapStorageError.invalidArchive("invalid text observation")
        }
        try TextEvidenceImage.validate(evidenceJPEG)
    }
}

/// A sign is evidence about an image. An up arrow does not prove stairs, a floor,
/// a world bearing, or a traversable edge. Navigation requires a visited label.
nonisolated struct SavedDirectionalSignage: Codable, Identifiable, Sendable, Equatable {
    nonisolated enum Source: String, Codable, Sendable { case recognizedGlyph, contourShape }
    var id: UUID = UUID()
    var textAnnotationID: UUID
    var text: String
    var direction: SignArrowDirection
    var arrowBounds: TextImageBounds
    var confidence: Float
    var source: Source
    var lastSeen: Date
    var worldPosition: MapPosition?
    var evidenceJPEG: Data? = nil

    func validate() throws {
        guard !text.isEmpty, text.count <= 2_000, arrowBounds.isValid,
              confidence.isFinite, (0...1).contains(confidence), worldPosition?.isValid != false,
              lastSeen.timeIntervalSince1970.isFinite, (evidenceJPEG?.count ?? 0) <= 512 * 1_024 else {
            throw MapStorageError.invalidArchive("invalid directional sign")
        }
        try TextEvidenceImage.validate(evidenceJPEG)
    }
}

nonisolated enum TextEvidenceImage {
    static func validate(_ data: Data?) throws {
        guard let data else { return }
        guard !data.isEmpty, data.count <= 512 * 1_024,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(source) as String? == "public.jpeg",
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              (1...2_048).contains(width), (1...2_048).contains(height) else {
            throw MapStorageError.invalidArchive("invalid text evidence image")
        }
    }
}

nonisolated enum TextAnnotationMatching {
    static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func isSamePhysicalText(_ a: SavedTextAnnotation, _ b: SavedTextAnnotation) -> Bool {
        guard normalized(a.text) == normalized(b.text) else { return false }
        if let p = a.worldPosition, let q = b.worldPosition {
            return distance(p, q) <= 0.45
        }
        // Without depth, only merge consecutive overlapping observations from
        // nearly the same viewpoint. Two rooms can both contain 'Restroom'.
        guard b.lastSeen.timeIntervalSince(a.lastSeen) < 8,
              distance(a.observedFrom, b.observedFrom) < 0.25,
              let aDirection = a.observedDirection, let bDirection = b.observedDirection,
              aDirection.x * bDirection.x + aDirection.y * bDirection.y + aDirection.z * bDirection.z > 0.96 else { return false }
        let intersection = a.bounds.rect.intersection(b.bounds.rect)
        let denominator = min(a.bounds.rect.width * a.bounds.rect.height,
                              b.bounds.rect.width * b.bounds.rect.height)
        return !intersection.isNull && denominator > 0 && intersection.width * intersection.height / denominator > 0.6
    }

    static func distance(_ a: MapPosition, _ b: MapPosition) -> Float {
        sqrt(pow(a.x - b.x, 2) + pow(a.y - b.y, 2) + pow(a.z - b.z, 2))
    }
}
