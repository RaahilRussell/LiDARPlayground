//
//  Fixtures.swift
//  testTests
//
//  Shared deterministic fixtures for the Phase 9 Swift Testing suites. No
//  sensors, clocks, or system randomness: every input is constructed here.
//

import CoreGraphics
import CoreVideo
import Foundation
import simd
@testable import test

/// SplitMix64 — tiny, fully deterministic generator for seeded RANSAC tests.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

enum Fixtures {
    /// Row-major field filled with `value`.
    static func field(width: Int, height: Int, value: Float, confidence: UInt8? = 2) -> DepthField {
        DepthField(width: width, height: height,
                   depth: [Float](repeating: value, count: width * height),
                   confidence: confidence.map { [UInt8](repeating: $0, count: width * height) })
    }

    /// Left half `near`, right half `far` — a clean depth discontinuity.
    static func stepField(width: Int = 8, height: Int = 6, near: Float = 1, far: Float = 3) -> DepthField {
        var f = field(width: width, height: height, value: near)
        for y in 0..<height { for x in (width / 2)..<width { f.depth[y * width + x] = far } }
        return f
    }

    /// Horizontal floor grid at height `y` (world metres), spacing 0.1 m.
    static func floorPoints(y: Float = -1.2, side: Int = 20) -> [SIMD3<Float>] {
        var pts: [SIMD3<Float>] = []
        for i in 0..<side { for j in 0..<side {
            pts.append(SIMD3(Float(i) * 0.1 - 1, y, -Float(j) * 0.1 - 0.5))
        }}
        return pts
    }

    /// A dense cube of points centred at `c` (count = n³).
    static func blob(at c: SIMD3<Float>, n: Int = 3, spacing: Float = 0.03) -> [SIMD3<Float>] {
        var pts: [SIMD3<Float>] = []
        for i in 0..<n { for j in 0..<n { for k in 0..<n {
            pts.append(c + SIMD3(Float(i), Float(j), Float(k)) * spacing)
        }}}
        return pts
    }

    /// `count` camera-space points straight ahead at forward distance `d`.
    static func pointsAhead(_ d: Float, azimuth: Float = 0, count: Int = 10) -> [SIMD3<Float>] {
        (0..<count).map { i in SIMD3(tanf(azimuth) * d, Float(i) * 0.01, -d) }
    }

    static func observation(id: Int, at p: SIMD3<Float>, nearest: Float = 1) -> ObjectObservation {
        ObjectObservation(id: id, label: "chair", confidence: 0.9, validDepthCoverage: 0.8,
                          depthConfidence: 0.9, nearestMeters: nearest, medianMeters: nearest,
                          positionCamera: p, positionWorld: p, azimuthDegrees: 0, region: .center,
                          boxNormalized: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2),
                          timestamp: 0, uncertain: false)
    }

    static func sample(_ variant: ModelVariant = .nano, at t: Double, inferenceMs: Double = 10,
                       endToEndMs: Double = 15, objects: Int = 2, skipped: Int = 0) -> InferenceSample {
        InferenceSample(variant: variant, completedAt: t, frameTimestamp: t - 0.02, preprocessMs: 0,
                        inferenceMs: inferenceMs, postprocessMs: 2, endToEndMs: endToEndMs,
                        captureToResultMs: endToEndMs + 20, objectCount: objects, skippedSlots: skipped)
    }

    static func depthBuffer(width: Int, height: Int, values: [Float]) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_DepthFloat32,
                                  nil, &pb) == kCVReturnSuccess, let buffer = pb else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float32.self)
            for x in 0..<width { row[x] = values[y * width + x] }
        }
        return buffer
    }
}
