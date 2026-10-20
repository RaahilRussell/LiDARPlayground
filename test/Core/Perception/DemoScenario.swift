//
//  DemoScenario.swift
//  test
//
//  Phase 8 — a deterministic, clearly SYNTHETIC scenario for the Inspector's demo
//  mode. Each step is a pure function of its index (no clock, no randomness), so
//  the same step always yields the same geometry and the whole sequence is
//  fixture-tested. The synthetic geometry is pushed through the REAL occupancy
//  algorithm and proximity state machine, but never through the shared live
//  ProximityEvaluator, and it never drives haptics unless the user opts in.
//

import Foundation

nonisolated enum DemoSegment: String, Sendable {
    case approach = "Approach (centre)"
    case hold = "Hold at close range"
    case recede = "Recede (right)"
    case dropout = "Sensor dropout (no valid depth)"
    case lowConfidence = "Low-confidence depth"
    case clearPath = "Far wall only"
}

nonisolated struct DemoFrame: Sendable {
    let step: Int
    let segment: DemoSegment
    /// Scripted obstacle distance (metres), nil when no obstacle is placed.
    let obstacleMeters: Float?
    let obstacleRegion: SpatialRegion?
    let cameraPoints: [SIMD3<Float>]
    let confidences: [Float]
    /// Small synthetic depth image (row-major, 0 == invalid) for the preview.
    let depth: [Float]
}

nonisolated enum DemoScenario {
    static let length = 64
    static let tickSeconds = 0.25
    static let depthWidth = 64
    static let depthHeight = 48
    static let wallMeters: Float = 4.0

    static func segment(at step: Int) -> DemoSegment {
        switch wrap(step) {
        case 0..<24: return .approach
        case 24..<32: return .hold
        case 32..<44: return .recede
        case 44..<52: return .dropout
        case 52..<58: return .lowConfidence
        default: return .clearPath
        }
    }

    static func frame(at step: Int) -> DemoFrame {
        let s = wrap(step)
        let seg = segment(at: s)
        var distance: Float?
        var region: SpatialRegion?
        var confidence: Float = 1.0
        var wall = true

        switch seg {
        case .approach:
            distance = 3.0 - (3.0 - 0.4) * Float(s) / 23   // 3.0 m → 0.4 m
            region = .center
        case .hold:
            distance = 0.4
            region = .center
        case .recede:
            distance = 0.4 + (2.6 - 0.4) * Float(s - 32) / 11 // 0.4 m → 2.6 m
            region = .right
        case .dropout:
            wall = false                                      // no valid samples at all
        case .lowConfidence:
            distance = 1.2
            region = .center
            confidence = 0.3
        case .clearPath:
            break
        }

        var points: [SIMD3<Float>] = []
        var confs: [Float] = []
        if wall {
            for r in [SpatialRegion.left, .center, .right] {
                append(region: r, distance: wallMeters, count: 10, confidence: confidence,
                       into: &points, &confs)
            }
        }
        if let distance, let region {
            append(region: region, distance: distance, count: 30, confidence: confidence,
                   into: &points, &confs)
        }
        return DemoFrame(step: s, segment: seg, obstacleMeters: distance, obstacleRegion: region,
                         cameraPoints: points, confidences: confs,
                         depth: depthImage(wall: wall, distance: distance, region: region))
    }

    /// Deterministic camera-space samples spread across a region's azimuth band.
    /// Region bands match SpatialAlgorithms.occupancy (|azimuth| < 0.26 rad = centre).
    private static func append(region: SpatialRegion, distance d: Float, count: Int, confidence: Float,
                               into points: inout [SIMD3<Float>], _ confs: inout [Float]) {
        let band: ClosedRange<Float>
        switch region {
        case .left: band = -0.6 ... -0.35
        case .center: band = -0.15 ... 0.15
        case .right: band = 0.35 ... 0.6
        }
        for i in 0..<count {
            let t = count > 1 ? Float(i) / Float(count - 1) : 0.5
            let az = band.lowerBound + (band.upperBound - band.lowerBound) * t
            let y = Float(i % 5) * 0.1 - 0.2
            points.append(SIMD3<Float>(tanf(az) * d, y, -d))
            confs.append(confidence)
        }
    }

    private static func depthImage(wall: Bool, distance: Float?, region: SpatialRegion?) -> [Float] {
        let w = depthWidth, h = depthHeight
        var out = [Float](repeating: wall ? wallMeters : 0, count: w * h)
        guard let distance, let region else { return out }
        let x0: Int, x1: Int
        switch region {
        case .left: (x0, x1) = (2, w / 3 - 2)
        case .center: (x0, x1) = (w / 3 + 2, 2 * w / 3 - 2)
        case .right: (x0, x1) = (2 * w / 3 + 2, w - 3)
        }
        for y in (h / 4)..<(3 * h / 4) {
            for x in x0...x1 { out[y * w + x] = distance }
        }
        return out
    }

    private static func wrap(_ step: Int) -> Int { ((step % length) + length) % length }
}

/// Chooses the proximity input from a region summary: the nearest region that has
/// enough samples, with that region's mean confidence. No samples → nil
/// (UNCERTAIN), never "clear".
nonisolated enum ProximityInputSelector {
    static func select(from regions: [RegionOccupancy]) -> (meters: Float, confidence: Float, region: SpatialRegion)? {
        let observed = regions.compactMap { r -> (meters: Float, confidence: Float, region: SpatialRegion)? in
            guard r.occupancy != .unknown, let meters = r.nearestMeters else { return nil }
            return (meters, r.meanConfidence, r.id)
        }
        return observed.min { $0.meters < $1.meters }
    }
}

/// Runs the demo sequence through the real pure algorithms. Owns its own state
/// machine so it can never disturb the live ProximityEvaluator.
nonisolated struct DemoStepOutput: Sendable {
    let frame: DemoFrame
    let occupancy: [RegionOccupancy]
    let state: ProximityState
    let stateChanged: Bool
    /// Distance fed to the state machine (nil → UNCERTAIN).
    let input: Float?
}

nonisolated struct DemoRunner: Sendable {
    private(set) var step = 0
    private(set) var machine = ProximityStateMachine()

    init(thresholds: ProximityThresholds = ProximityThresholds()) {
        machine = ProximityStateMachine(thresholds: thresholds)
    }

    mutating func advance() -> DemoStepOutput {
        let frame = DemoScenario.frame(at: step)
        let occupancy = SpatialAlgorithms.occupancy(cameraPoints: frame.cameraPoints,
                                                    confidences: frame.confidences)
        let input = ProximityInputSelector.select(from: occupancy)
        let changed = machine.step(nearest: input?.meters, confidence: input?.confidence)
        step += 1
        return DemoStepOutput(frame: frame, occupancy: occupancy, state: machine.state,
                      stateChanged: changed, input: input?.meters)
    }

    mutating func reset() {
        step = 0
        machine.reset()
    }

    /// Demo events reach the Taptic Engine only with explicit opt-in.
    static func shouldPlayHaptic(stateChanged: Bool, optedIn: Bool) -> Bool {
        optedIn && stateChanged
    }
}
