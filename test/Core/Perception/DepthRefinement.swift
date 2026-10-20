//
//  DepthRefinement.swift
//  test
//
//  Phase 2 — pure, thread-safe depth filters operating on the 256×192 float
//  depth field. Every filter:
//   • excludes invalid / NaN / zero depth,
//   • respects per-pixel confidence,
//   • refuses to average across large depth discontinuities (range kernel),
//   • never invents geometry in unknown (invalid) areas.
//
//  These are "visual/analysis" refinements. Proximity measurements use their own
//  robust path (SpatialFusionEngine) and are NOT delayed by temporal smoothing.
//

import ARKit
import CoreImage
import CoreVideo
import simd

/// Flat depth field (row-major). depth[y*width+x] in metres, 0 == invalid.
nonisolated struct DepthField: Sendable {
    let width: Int
    let height: Int
    var depth: [Float]
    var confidence: [UInt8]?

    func valid(_ i: Int) -> Bool { depth[i].isFinite && depth[i] > 0 }
    func confOK(_ i: Int, min: Int) -> Bool {
        guard let c = confidence else { return true }
        return Int(c[i]) >= min
    }
    var validFraction: Double {
        var v = 0
        for d in depth where d.isFinite && d > 0 { v += 1 }
        return depth.isEmpty ? 0 : Double(v) / Double(depth.count)
    }
}

enum DepthRefinement {

    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    // MARK: - Extraction

    nonisolated static func field(from depth: CVPixelBuffer, confidence: CVPixelBuffer?) -> DepthField {
        let w = CVPixelBufferGetWidth(depth)
        let h = CVPixelBufferGetHeight(depth)
        CVPixelBufferLockBaseAddress(depth, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depth, .readOnly) }
        if let confidence { CVPixelBufferLockBaseAddress(confidence, .readOnly) }
        defer { if let confidence { CVPixelBufferUnlockBaseAddress(confidence, .readOnly) } }

        var out = [Float](repeating: 0, count: w * h)
        if let base = CVPixelBufferGetBaseAddress(depth) {
            let rb = CVPixelBufferGetBytesPerRow(depth)
            for y in 0..<h {
                let row = base.advanced(by: y * rb).assumingMemoryBound(to: Float32.self)
                for x in 0..<w {
                    let d = row[x]
                    out[y * w + x] = (d.isFinite && d > 0) ? d : 0
                }
            }
        }
        var conf: [UInt8]?
        if let confidence, let cbase = CVPixelBufferGetBaseAddress(confidence) {
            let rb = CVPixelBufferGetBytesPerRow(confidence)
            var c = [UInt8](repeating: 0, count: w * h)
            for y in 0..<h {
                let row = cbase.advanced(by: y * rb).assumingMemoryBound(to: UInt8.self)
                for x in 0..<w { c[y * w + x] = row[x] }
            }
            conf = c
        }
        return DepthField(width: w, height: h, depth: out, confidence: conf)
    }

    /// Downscaled RGB guide (RGBA8) at the depth resolution, for joint filtering.
    nonisolated static func rgbGuide(_ captured: CVPixelBuffer, width: Int, height: Int) -> [UInt8]? {
        let ci = CIImage(cvPixelBuffer: captured)
        let sx = CGFloat(width) / ci.extent.width
        let sy = CGFloat(height) / ci.extent.height
        let scaled = ci.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { raw in
            ciContext.render(scaled, toBitmap: raw.baseAddress!, rowBytes: width * 4,
                             bounds: CGRect(x: 0, y: 0, width: width, height: height),
                             format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        }
        return bytes
    }

    // MARK: - Filters (each returns a new depth array)

    /// C — confidence-aware median within a radius; ignores invalid/low-confidence.
    nonisolated static func confidenceMedian(_ f: DepthField, params p: FilterParams) -> [Float] {
        let w = f.width, h = f.height, r = max(1, p.kernelRadius)
        var out = f.depth
        var window = [Float]()
        window.reserveCapacity((2 * r + 1) * (2 * r + 1))
        for y in 0..<h {
            for x in 0..<w {
                let i = y * w + x
                guard f.valid(i) else { out[i] = 0; continue }
                window.removeAll(keepingCapacity: true)
                for dy in -r...r {
                    let yy = y + dy; if yy < 0 || yy >= h { continue }
                    for dx in -r...r {
                        let xx = x + dx; if xx < 0 || xx >= w { continue }
                        let j = yy * w + xx
                        if f.valid(j) && f.confOK(j, min: p.minConfidence) { window.append(f.depth[j]) }
                    }
                }
                if window.isEmpty { out[i] = f.depth[i]; continue }
                window.sort()
                out[i] = window[window.count / 2]
            }
        }
        return out
    }

    /// D — joint bilateral filter guided by RGB, with a depth range kernel so it
    /// never smooths foreground into background across a discontinuity.
    nonisolated static func jointBilateral(_ f: DepthField, guide: [UInt8]?, params p: FilterParams) -> [Float] {
        let w = f.width, h = f.height, r = max(1, p.kernelRadius)
        let ss = max(0.1, p.spatialSigma), cs = max(0.01, p.colorSigma)
        let dr = max(0.01, p.discontinuityThreshold)
        var out = f.depth
        for y in 0..<h {
            for x in 0..<w {
                let i = y * w + x
                guard f.valid(i) else { out[i] = 0; continue }
                let centerD = f.depth[i]
                let gi = i * 4
                var sum: Float = 0, wsum: Float = 0
                for dy in -r...r {
                    let yy = y + dy; if yy < 0 || yy >= h { continue }
                    for dx in -r...r {
                        let xx = x + dx; if xx < 0 || xx >= w { continue }
                        let j = yy * w + xx
                        guard f.valid(j) && f.confOK(j, min: p.minConfidence) else { continue }
                        let dd = f.depth[j] - centerD
                        if abs(dd) > dr { continue }  // don't cross discontinuities
                        let spatial = Float(dx * dx + dy * dy) / (2 * ss * ss)
                        var colorTerm: Float = 0
                        if let g = guide {
                            let gj = j * 4
                            let dc = (Float(g[gi]) - Float(g[gj])) / 255
                            let dcg = (Float(g[gi + 1]) - Float(g[gj + 1])) / 255
                            let dcb = (Float(g[gi + 2]) - Float(g[gj + 2])) / 255
                            colorTerm = (dc * dc + dcg * dcg + dcb * dcb) / (2 * cs * cs)
                        }
                        let rangeTerm = (dd * dd) / (2 * dr * dr)
                        let weight = expf(-(spatial + colorTerm + rangeTerm))
                        sum += weight * f.depth[j]
                        wsum += weight
                    }
                }
                out[i] = wsum > 0 ? sum / wsum : centerD
            }
        }
        return out
    }

    /// E — simplified motion-gated temporal blend. Blends with the previous frame
    /// only where both are valid and agree (rejecting invalid correspondences).
    /// Caller resets `previous` on tracking loss / large camera motion.
    /// NOTE: this is pose-gated, not full reprojection — documented simplification.
    nonisolated static func temporal(_ f: DepthField, previous: [Float]?, params p: FilterParams) -> [Float] {
        guard let prev = previous, prev.count == f.depth.count else { return f.depth }
        let a = min(1, max(0, p.temporalStrength))
        let dr = max(0.01, p.discontinuityThreshold)
        var out = f.depth
        for i in 0..<f.depth.count {
            guard f.valid(i) else { out[i] = 0; continue }
            let pv = prev[i]
            if pv.isFinite && pv > 0 && abs(pv - f.depth[i]) <= dr {
                out[i] = (1 - a) * f.depth[i] + a * pv
            }
        }
        return out
    }

    // MARK: - Edge / discontinuity map

    /// Returns a 0/1 edge mask where the local depth gradient exceeds the threshold.
    nonisolated static func edges(_ depth: [Float], width: Int, height: Int, threshold: Float) -> [Bool] {
        var out = [Bool](repeating: false, count: depth.count)
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let i = y * width + x
                let c = depth[i]; if !(c.isFinite && c > 0) { continue }
                let gx = absDiff(depth[i + 1], depth[i - 1])
                let gy = absDiff(depth[i + width], depth[i - width])
                if max(gx, gy) > threshold { out[i] = true }
            }
        }
        return out
    }

    private static func absDiff(_ a: Float, _ b: Float) -> Float {
        guard a.isFinite, a > 0, b.isFinite, b > 0 else { return 0 }
        return abs(a - b)
    }

    // MARK: - Colorization

    nonisolated static func colorize(_ depth: [Float], width: Int, height: Int,
                                     range: ClosedRange<Float>) -> CGImage? {
        var px = [UInt8](repeating: 0, count: width * height * 4)
        let span = max(0.0001, range.upperBound - range.lowerBound)
        for i in 0..<(width * height) {
            let d = depth[i]
            let o = i * 4
            if d.isFinite && d > 0 {
                let t = min(1, max(0, (d - range.lowerBound) / span))
                let rgb = DepthProcessing.turbo(t)
                px[o] = rgb.x; px[o + 1] = rgb.y; px[o + 2] = rgb.z; px[o + 3] = 255
            } else {
                px[o] = 255; px[o + 1] = 0; px[o + 2] = 180; px[o + 3] = 255 // magenta = invalid
            }
        }
        return makeImage(&px, width, height)
    }

    nonisolated static func edgeImage(_ edges: [Bool], width: Int, height: Int) -> CGImage? {
        var px = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<edges.count {
            let o = i * 4
            let v: UInt8 = edges[i] ? 255 : 0
            px[o] = v; px[o + 1] = v; px[o + 2] = v; px[o + 3] = 255
        }
        return makeImage(&px, width, height)
    }

    nonisolated static func rgbImage(_ guide: [UInt8]?, width: Int, height: Int) -> CGImage? {
        guard var guide else { return nil }
        return makeImage(&guide, width, height)
    }

    private static func makeImage(_ px: inout [UInt8], _ w: Int, _ h: Int) -> CGImage? {
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        return ctx.makeImage()
    }
}
