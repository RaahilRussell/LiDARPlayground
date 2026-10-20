//
//  DepthProcessing.swift
//  test
//
//  Pure, thread-safe helpers that turn ARKit depth + confidence buffers into
//  heatmap images and numeric statistics. Everything here is `nonisolated` so
//  it can run on a background queue — we never process pixels on the main thread.
//
//  Depth buffers from sceneDepth/smoothedSceneDepth are 32-bit float metres in a
//  256×192 landscape buffer. Confidence buffers are 8-bit (ARConfidenceLevel).
//

import ARKit
import CoreVideo
import simd

/// What a heatmap render should encode.
enum HeatmapMode {
    case depth(range: ClosedRange<Float>)
    case confidence
}

/// Numeric summary of a depth frame (Feature 2 readouts).
struct DepthStats {
    var width: Int
    var height: Int
    var minMeters: Float
    var maxMeters: Float
    var medianMeters: Float
    var centerMeters: Float?
    var validFraction: Double
}

enum DepthProcessing {

    // MARK: - Colorization

    /// Produces an RGBA8 image of the depth (or confidence) buffer. Invalid pixels
    /// (zero/NaN depth, or below the confidence filter) are rendered as a clearly
    /// marked magenta so missing data is never shown as valid free space.
    nonisolated static func makeHeatmap(depth: CVPixelBuffer,
                                        confidence: CVPixelBuffer?,
                                        mode: HeatmapMode,
                                        minConfidence: ARConfidenceLevel?) -> CGImage? {
        let width = CVPixelBufferGetWidth(depth)
        let height = CVPixelBufferGetHeight(depth)

        CVPixelBufferLockBaseAddress(depth, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depth, .readOnly) }
        if let confidence { CVPixelBufferLockBaseAddress(confidence, .readOnly) }
        defer { if let confidence { CVPixelBufferUnlockBaseAddress(confidence, .readOnly) } }

        guard let depthBase = CVPixelBufferGetBaseAddress(depth) else { return nil }
        let depthRowBytes = CVPixelBufferGetBytesPerRow(depth)
        let confBase = confidence.flatMap { CVPixelBufferGetBaseAddress($0) }
        let confRowBytes = confidence.map { CVPixelBufferGetBytesPerRow($0) } ?? 0

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let invalid = SIMD3<UInt8>(255, 0, 180) // magenta = "no valid measurement"
        let minConf = minConfidence?.rawValue ?? -1

        pixels.withUnsafeMutableBytes { raw in
            let out = raw.bindMemory(to: UInt8.self).baseAddress!
            for y in 0..<height {
                let depthRow = depthBase.advanced(by: y * depthRowBytes)
                    .assumingMemoryBound(to: Float32.self)
                let confRow = confBase?.advanced(by: y * confRowBytes)
                    .assumingMemoryBound(to: UInt8.self)
                for x in 0..<width {
                    let idx = (y * width + x) * 4
                    let d = depthRow[x]
                    let confOK = confRow.map { Int($0[x]) >= minConf } ?? true
                    var rgb = invalid
                    var valid = confOK && d.isFinite && d > 0

                    if valid {
                        switch mode {
                        case .depth(let range):
                            let t = (d - range.lowerBound) / max(0.0001, range.upperBound - range.lowerBound)
                            rgb = turbo(clamp01(t))
                        case .confidence:
                            let level = confRow.map { Int($0[x]) } ?? 0
                            rgb = confidenceColor(level)
                        }
                    }
                    // In confidence mode, "invalid depth" still shows its confidence.
                    if case .confidence = mode, confRow != nil {
                        valid = true
                        let level = Int(confRow![x])
                        rgb = confidenceColor(level)
                    }

                    out[idx + 0] = rgb.x
                    out[idx + 1] = rgb.y
                    out[idx + 2] = rgb.z
                    out[idx + 3] = 255
                }
            }
        }

        return makeCGImage(rgba: &pixels, width: width, height: height)
    }

    // MARK: - Statistics

    nonisolated static func computeStats(depth: CVPixelBuffer,
                                         confidence: CVPixelBuffer?,
                                         minConfidence: ARConfidenceLevel?) -> DepthStats {
        let width = CVPixelBufferGetWidth(depth)
        let height = CVPixelBufferGetHeight(depth)

        CVPixelBufferLockBaseAddress(depth, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depth, .readOnly) }
        if let confidence { CVPixelBufferLockBaseAddress(confidence, .readOnly) }
        defer { if let confidence { CVPixelBufferUnlockBaseAddress(confidence, .readOnly) } }

        guard let depthBase = CVPixelBufferGetBaseAddress(depth) else {
            return DepthStats(width: width, height: height, minMeters: 0, maxMeters: 0,
                              medianMeters: 0, centerMeters: nil, validFraction: 0)
        }
        let depthRowBytes = CVPixelBufferGetBytesPerRow(depth)
        let confBase = confidence.flatMap { CVPixelBufferGetBaseAddress($0) }
        let confRowBytes = confidence.map { CVPixelBufferGetBytesPerRow($0) } ?? 0
        let minConf = minConfidence?.rawValue ?? -1

        var valid = [Float]()
        valid.reserveCapacity(width * height / 4)
        var total = 0
        var usable = 0

        var y = 0
        while y < height {
            let depthRow = depthBase.advanced(by: y * depthRowBytes)
                .assumingMemoryBound(to: Float32.self)
            let confRow = confBase?.advanced(by: y * confRowBytes)
                .assumingMemoryBound(to: UInt8.self)
            var x = 0
            while x < width {
                total += 1
                let d = depthRow[x]
                let confOK = confRow.map { Int($0[x]) >= minConf } ?? true
                if confOK && d.isFinite && d > 0 {
                    usable += 1
                    valid.append(d)
                }
                x += 2
            }
            y += 2
        }

        let center = sampleDistance(depth: depth, normalizedPoint: CGPoint(x: 0.5, y: 0.5), alreadyLocked: true)
        guard !valid.isEmpty else {
            return DepthStats(width: width, height: height, minMeters: 0, maxMeters: 0,
                              medianMeters: 0, centerMeters: center,
                              validFraction: total > 0 ? Double(usable) / Double(total) : 0)
        }
        valid.sort()
        return DepthStats(width: width, height: height,
                          minMeters: valid.first!, maxMeters: valid.last!,
                          medianMeters: valid[valid.count / 2],
                          centerMeters: center,
                          validFraction: total > 0 ? Double(usable) / Double(total) : 0)
    }

    // MARK: - Point sampling

    /// Returns the depth in metres at a normalized point (0...1, origin top-left of
    /// the depth buffer in its native landscape orientation). nil if invalid.
    nonisolated static func sampleDistance(depth: CVPixelBuffer,
                                           normalizedPoint: CGPoint,
                                           alreadyLocked: Bool = false) -> Float? {
        let width = CVPixelBufferGetWidth(depth)
        let height = CVPixelBufferGetHeight(depth)
        if !alreadyLocked { CVPixelBufferLockBaseAddress(depth, .readOnly) }
        defer { if !alreadyLocked { CVPixelBufferUnlockBaseAddress(depth, .readOnly) } }
        guard let base = CVPixelBufferGetBaseAddress(depth) else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRow(depth)

        let x = min(width - 1, max(0, Int(normalizedPoint.x * CGFloat(width))))
        let y = min(height - 1, max(0, Int(normalizedPoint.y * CGFloat(height))))
        let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float32.self)
        let d = row[x]
        return (d.isFinite && d > 0) ? d : nil
    }

    /// Confidence level (0=low,1=med,2=high) at a normalized buffer point, or nil.
    nonisolated static func sampleConfidence(_ confidence: CVPixelBuffer,
                                             normalizedPoint: CGPoint) -> Int? {
        let width = CVPixelBufferGetWidth(confidence)
        let height = CVPixelBufferGetHeight(confidence)
        CVPixelBufferLockBaseAddress(confidence, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(confidence, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(confidence) else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRow(confidence)
        let x = min(width - 1, max(0, Int(normalizedPoint.x * CGFloat(width))))
        let y = min(height - 1, max(0, Int(normalizedPoint.y * CGFloat(height))))
        let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt8.self)
        return Int(row[x])
    }

    /// Copies a depth buffer into a row-major [[Float]] matrix (metres, 0 == invalid).
    nonisolated static func matrix(from depth: CVPixelBuffer) -> [[Float]] {
        let width = CVPixelBufferGetWidth(depth)
        let height = CVPixelBufferGetHeight(depth)
        CVPixelBufferLockBaseAddress(depth, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depth, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(depth) else { return [] }
        let rowBytes = CVPixelBufferGetBytesPerRow(depth)
        var result = [[Float]](repeating: [Float](repeating: 0, count: width), count: height)
        for y in 0..<height {
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float32.self)
            for x in 0..<width {
                let d = row[x]
                result[y][x] = (d.isFinite && d > 0) ? d : 0
            }
        }
        return result
    }

    // MARK: - Colormaps

    /// Google "Turbo" colormap approximation — perceptually nice for depth.
    nonisolated static func turbo(_ t: Float) -> SIMD3<UInt8> {
        let r = clamp01(0.13 + 4.0 * t - 6.0 * t * t + 2.3 * t * t * t)
        let g = clamp01(0.05 + 2.5 * t - 2.1 * t * t)
        let b = clamp01(0.20 + 2.0 * t - 5.0 * t * t + 2.8 * t * t * t)
        return SIMD3<UInt8>(UInt8(r * 255), UInt8(g * 255), UInt8(b * 255))
    }

    nonisolated static func confidenceColor(_ level: Int) -> SIMD3<UInt8> {
        switch level {
        case 0: return SIMD3<UInt8>(230, 70, 70)    // low  — red
        case 1: return SIMD3<UInt8>(240, 200, 60)   // med  — amber
        default: return SIMD3<UInt8>(70, 210, 110)  // high — green
        }
    }

    // MARK: - Private

    nonisolated private static func clamp01(_ v: Float) -> Float { min(1, max(0, v)) }

    nonisolated private static func makeCGImage(rgba: inout [UInt8], width: Int, height: Int) -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(data: &rgba, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: colorSpace, bitmapInfo: info) else { return nil }
        return ctx.makeImage()
    }
}
