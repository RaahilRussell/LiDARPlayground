import Foundation

/// Timing and headroom are independent of ARKit so automatic-save decisions
/// can be verified without manufacturing camera frames in simulator tests.
nonisolated enum AutomaticMappingPolicy {
    static let saveInterval: TimeInterval = 20
    static let transientRetryInterval: TimeInterval = 5
    static let segmentFillFraction = 0.70

    static func shouldSave(now: Date, lastSavedAt: Date?, lastAttemptAt: Date?,
                           ready: Bool, foreground: Bool, userPaused: Bool,
                           busy: Bool, enabled: Bool) -> Bool {
        guard ready, foreground, !userPaused, !busy, enabled else { return false }
        if let lastAttemptAt, now.timeIntervalSince(lastAttemptAt) < transientRetryInterval { return false }
        return lastSavedAt.map { now.timeIntervalSince($0) >= saveInterval } ?? true
    }

    static func needsSegment(vertices: Int, faces: Int, anchors: Int) -> Bool {
        Double(vertices) >= Double(MapLimits.maxVertices) * segmentFillFraction ||
        Double(faces) >= Double(MapLimits.maxTriangles) * segmentFillFraction ||
        Double(anchors) >= Double(MapLimits.maxMeshAnchors) * segmentFillFraction
    }

    static func automaticName(at date: Date) -> String {
        "Place " + date.formatted(date: .abbreviated, time: .shortened)
    }
}
