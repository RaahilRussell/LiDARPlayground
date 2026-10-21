//
//  InspectorModels.swift
//  test
//
//  Phase 8 — pure value types and helpers behind the Perception Inspector:
//  frame metadata, depth/confidence statistics, a bounded event log, occupancy
//  change detection, and the measured latency breakdown. No ARKit objects are
//  stored here; frames are reduced to numbers and small previews immediately.
//

import CoreGraphics
import CoreVideo
import Foundation
import simd

// MARK: - Frame metadata

nonisolated enum FourCC {
    /// Renders a CoreVideo pixel-format OSType as its four characters, e.g. "420f".
    static func string(_ code: OSType) -> String {
        let bytes = [UInt8((code >> 24) & 0xFF), UInt8((code >> 16) & 0xFF),
                     UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF)]
        let printable = bytes.allSatisfy { $0 >= 0x20 && $0 < 0x7F }
        return printable ? String(decoding: bytes, as: UTF8.self) : String(format: "0x%08X", code)
    }
}

/// Numbers read from one SensorFrame snapshot (cheap; no pixel work).
nonisolated struct FrameMetadata: Sendable {
    var timestamp: TimeInterval
    /// Host clock minus ARFrame.timestamp when the snapshot was taken.
    var frameAgeMs: Double
    var imageWidth: Int
    var imageHeight: Int
    var imagePixelFormat: String
    var depthWidth: Int?
    var depthHeight: Int?
    var hasSmoothedDepth: Bool
    var hasConfidence: Bool
    var trackingNormal: Bool
    var fx: Float, fy: Float, cx: Float, cy: Float
    var position: SIMD3<Float>
}

nonisolated struct DepthStatistics: Equatable, Sendable {
    var validFraction: Double
    var minMeters: Float?
    var medianMeters: Float?
    var maxMeters: Float?
    /// Fractions of pixels at ARConfidenceLevel low/medium/high (nil without a map).
    var confidenceLow: Double?
    var confidenceMedium: Double?
    var confidenceHigh: Double?

    static func compute(depth: [Float], confidence: [UInt8]?) -> DepthStatistics {
        var valid = depth.filter { $0.isFinite && $0 > 0 }
        valid.sort()
        var stats = DepthStatistics(
            validFraction: depth.isEmpty ? 0 : Double(valid.count) / Double(depth.count),
            minMeters: valid.first, medianMeters: valid.isEmpty ? nil : valid[valid.count / 2],
            maxMeters: valid.last)
        if let confidence, !confidence.isEmpty {
            var counts = [0, 0, 0]
            for c in confidence { counts[min(2, Int(c))] += 1 }
            let n = Double(confidence.count)
            stats.confidenceLow = Double(counts[0]) / n
            stats.confidenceMedium = Double(counts[1]) / n
            stats.confidenceHigh = Double(counts[2]) / n
        }
        return stats
    }
}

// MARK: - Bounded event log

nonisolated enum EventOrigin: String, Sendable {
    case live = "LIVE"
    case demo = "DEMO"
}

nonisolated enum InspectorEventKind: String, Sendable {
    case proximity = "Proximity"
    case occupancy = "Occupancy"
    case floor = "Floor"
    case tracking = "Tracking"
    case system = "System"
}

nonisolated struct InspectorEvent: Identifiable, Sendable {
    let id: Int
    let hostTime: TimeInterval
    let origin: EventOrigin
    let kind: InspectorEventKind
    let message: String
    /// Measured latency attached to the event, if any (ms).
    let latencyMs: Double?
}

nonisolated struct EventLog: Sendable {
    static let capacity = 100
    private(set) var buffer = BoundedBuffer<InspectorEvent>(capacity: EventLog.capacity)
    private var nextId = 0

    mutating func append(origin: EventOrigin, kind: InspectorEventKind, message: String,
                         at hostTime: TimeInterval, latencyMs: Double? = nil) {
        buffer.append(InspectorEvent(id: nextId, hostTime: hostTime, origin: origin, kind: kind,
                                     message: message, latencyMs: latencyMs))
        nextId += 1
    }

    /// Newest first, for display.
    var newestFirst: [InspectorEvent] { buffer.elements.reversed() }

    mutating func clear() { buffer.removeAll() }
}

// MARK: - Occupancy change detection

nonisolated struct OccupancyChange: Equatable, Sendable {
    let region: SpatialRegion
    let from: OccupancyClass?
    let to: OccupancyClass
}

nonisolated enum OccupancyDiff {
    static func changes(previous: [RegionOccupancy], current: [RegionOccupancy]) -> [OccupancyChange] {
        current.compactMap { now in
            let before = previous.first { $0.id == now.id }?.occupancy
            return before == now.occupancy ? nil : OccupancyChange(region: now.id, from: before, to: now.occupancy)
        }
    }
}

// MARK: - Latency breakdown (measured values only)

nonisolated struct LatencyStage: Identifiable, Sendable {
    var id: String { name }
    let name: String
    /// nil = not measured / stage not running. Never substituted with a guess.
    let ms: Double?
    let note: String
}

nonisolated enum LatencyBreakdown {
    /// Inputs are the engines' own measurements; nil means "not running".
    static func stages(captureToResultMs: Double?, endToEndMs: Double?, preMs: Double?,
                       inferenceMs: Double?, postMs: Double?, fusionMs: Double?,
                       spatialMs: Double?, depthRefineMs: Double?,
                       navigationComputeMs: Double?, captureToDecisionMs: Double?) -> [LatencyStage] {
        var unattributed: Double?
        if let e2e = endToEndMs, let inf = inferenceMs {
            // Clamped: SDK and our clocks bracket slightly different spans.
            unattributed = max(0, e2e - (preMs ?? 0) - inf - (postMs ?? 0))
        }
        var frameAge: Double?
        if let c2r = captureToResultMs, let e2e = endToEndMs { frameAge = max(0, c2r - e2e) }
        return [
            LatencyStage(name: "Capture → inference start", ms: frameAge,
                         note: "frame age when the tick read it (capture→result − E2E)"),
            LatencyStage(name: "SDK pre-process", ms: preMs, note: "0 on Vision path (folded into inference)"),
            LatencyStage(name: "SDK inference", ms: inferenceMs, note: "Core ML via Vision, SDK timer"),
            LatencyStage(name: "SDK post-process", ms: postMs, note: "NMS / mask assembly, SDK timer"),
            LatencyStage(name: "Unattributed", ms: unattributed,
                         note: "E2E − SDK stages: annotation drawing, task hops, conversion"),
            LatencyStage(name: "Inference E2E", ms: endToEndMs, note: "tick start → converted result"),
            LatencyStage(name: "Capture → result", ms: captureToResultMs, note: "host clock − ARFrame.timestamp"),
            LatencyStage(name: "RGB+depth fusion", ms: fusionMs, note: "SpatialFusionEngine, last pass"),
            LatencyStage(name: "Spatial algorithms", ms: spatialMs, note: "floor/cluster/occupancy, last pass"),
            LatencyStage(name: "Depth refinement", ms: depthRefineMs, note: "Depth Lab filters, last pass"),
            LatencyStage(name: "Navigation compute", ms: navigationComputeMs,
                         note: "points → floor → map → path scan, last tick"),
            LatencyStage(name: "Capture → alert decision", ms: captureToDecisionMs,
                         note: "host clock − ARFrame.timestamp at the decision, last tick"),
        ]
    }
}
