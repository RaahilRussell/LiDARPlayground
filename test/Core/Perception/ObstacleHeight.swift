//
//  ObstacleHeight.swift
//  test
//
//  Classifies a hazard by its height band ABOVE the fitted floor plane, so a low
//  trip hazard, a knee-height bollard, a body-level wall, and an overhead sign can
//  feel and sound different. Heights come from the same world-anchored fusion
//  (LiDAR clusters give a real vertical extent; CV objects give a point).
//

import Foundation

nonisolated enum ObstacleHeight: String, Codable, Sendable {
    case unknown, ground, knee, torso, overhead

    /// Thresholds in metres above the floor.
    static func classify(minHeight: Float?, maxHeight: Float?) -> ObstacleHeight {
        guard let lo = minHeight, let hi = maxHeight, lo.isFinite, hi.isFinite, hi >= lo else {
            return .unknown
        }
        if lo >= 1.6 { return .overhead }   // hangs above head, nothing low
        if hi <= 0.35 { return .ground }    // low trip hazard
        if hi <= 0.75 { return .knee }      // knee / shin height
        return .torso                       // body-level or tall spanning
    }

    /// Spoken descriptor used by Wearer Mode.
    var spokenName: String {
        switch self {
        case .ground: return "low obstacle"
        case .knee: return "knee-height obstacle"
        case .torso: return "obstacle"
        case .overhead: return "overhead obstacle"
        case .unknown: return "obstacle"
        }
    }

    /// Short tag for the developer overlay.
    var shortLabel: String {
        switch self {
        case .ground: return "Low"
        case .knee: return "Knee"
        case .torso: return "Body"
        case .overhead: return "Head"
        case .unknown: return "—"
        }
    }

    /// Haptic sharpness offset so heights feel distinct (ground = dull, overhead = crisp).
    var sharpnessBias: Float {
        switch self {
        case .ground: return -0.2
        case .knee: return -0.1
        case .torso: return 0
        case .overhead: return 0.3
        case .unknown: return 0
        }
    }
}
