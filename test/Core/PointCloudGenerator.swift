//
//  PointCloudGenerator.swift
//  test
//
//  Feature 4 — converts a depth buffer into 3D points using the camera
//  intrinsics, depth resolution, and (optionally) the camera-to-world pose.
//  RGB colour is sampled from the captured image, downscaled once to depth
//  resolution. All heavy work is `nonisolated` so it runs off the main thread.
//

import ARKit
import CoreImage
import simd

struct PointCloud {
    var positions: [SIMD3<Float>] = []
    var colors: [SIMD4<Float>] = []   // RGBA 0...1
    var count: Int { positions.count }
}

/// Immutable inputs copied off an ARFrame on the main thread, then handed to a
/// background task. (Lets us avoid retaining the ARFrame itself.)
struct PointCloudInput {
    let depth: CVPixelBuffer
    let confidence: CVPixelBuffer?
    let capturedImage: CVPixelBuffer
    let intrinsics: simd_float3x3
    let imageResolution: CGSize
    let cameraTransform: simd_float4x4
    let worldSpace: Bool
    let stride: Int            // density: sample every Nth pixel
    let maxPoints: Int
    let minConfidence: Int     // ARConfidenceLevel.rawValue threshold
}

enum PointCloudGenerator {

    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    nonisolated static func generate(_ input: PointCloudInput) -> PointCloud {
        let dw = CVPixelBufferGetWidth(input.depth)
        let dh = CVPixelBufferGetHeight(input.depth)

        // Scale the full-image intrinsics down to the depth buffer resolution.
        let sx = Float(dw) / Float(input.imageResolution.width)
        let sy = Float(dh) / Float(input.imageResolution.height)
        let fx = input.intrinsics[0][0] * sx
        let fy = input.intrinsics[1][1] * sy
        let cx = input.intrinsics[2][0] * sx
        let cy = input.intrinsics[2][1] * sy

        // Downscale the captured image to depth resolution once, for colour lookup.
        let rgb = downscaledRGBA(input.capturedImage, width: dw, height: dh)

        CVPixelBufferLockBaseAddress(input.depth, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(input.depth, .readOnly) }
        if let c = input.confidence { CVPixelBufferLockBaseAddress(c, .readOnly) }
        defer { if let c = input.confidence { CVPixelBufferUnlockBaseAddress(c, .readOnly) } }

        guard let depthBase = CVPixelBufferGetBaseAddress(input.depth) else { return PointCloud() }
        let depthRowBytes = CVPixelBufferGetBytesPerRow(input.depth)
        let confBase = input.confidence.flatMap { CVPixelBufferGetBaseAddress($0) }
        let confRowBytes = input.confidence.map { CVPixelBufferGetBytesPerRow($0) } ?? 0

        var positions = [SIMD3<Float>]()
        var colors = [SIMD4<Float>]()
        positions.reserveCapacity(input.maxPoints)
        colors.reserveCapacity(input.maxPoints)

        let step = max(1, input.stride)
        var y = 0
        outer: while y < dh {
            let depthRow = depthBase.advanced(by: y * depthRowBytes)
                .assumingMemoryBound(to: Float32.self)
            let confRow = confBase?.advanced(by: y * confRowBytes)
                .assumingMemoryBound(to: UInt8.self)
            var x = 0
            while x < dw {
                let d = depthRow[x]
                let confOK = confRow.map { Int($0[x]) >= input.minConfidence } ?? true
                if d.isFinite && d > 0 && confOK {
                    // Unproject into ARKit camera space (x right, y up, -z forward).
                    let xc = (Float(x) - cx) * d / fx
                    let yc = (Float(y) - cy) * d / fy
                    let camPoint = SIMD3<Float>(xc, -yc, -d)
                    let p: SIMD3<Float>
                    if input.worldSpace {
                        let world = input.cameraTransform * SIMD4<Float>(camPoint, 1)
                        p = SIMD3<Float>(world.x, world.y, world.z)
                    } else {
                        p = camPoint
                    }
                    positions.append(p)
                    colors.append(colorAt(rgb, x: x, y: y, width: dw))

                    if positions.count >= input.maxPoints { break outer }
                }
                x += step
            }
            y += step
        }
        return PointCloud(positions: positions, colors: colors)
    }

    // MARK: - RGB helpers

    /// Renders the (YCbCr) captured image into a tightly-packed RGBA8 byte array.
    nonisolated private static func downscaledRGBA(_ pixelBuffer: CVPixelBuffer,
                                                   width: Int, height: Int) -> [UInt8]? {
        let ci = CIImage(cvPixelBuffer: pixelBuffer)
        let scaleX = CGFloat(width) / ci.extent.width
        let scaleY = CGFloat(height) / ci.extent.height
        let scaled = ci.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        bytes.withUnsafeMutableBytes { raw in
            ciContext.render(scaled,
                             toBitmap: raw.baseAddress!,
                             rowBytes: width * 4,
                             bounds: CGRect(x: 0, y: 0, width: width, height: height),
                             format: .RGBA8,
                             colorSpace: colorSpace)
        }
        return bytes
    }

    nonisolated private static func colorAt(_ rgb: [UInt8]?, x: Int, y: Int, width: Int) -> SIMD4<Float> {
        guard let rgb else { return SIMD4<Float>(0.7, 0.7, 0.7, 1) }
        let i = (y * width + x) * 4
        guard i + 2 < rgb.count else { return SIMD4<Float>(0.7, 0.7, 0.7, 1) }
        return SIMD4<Float>(Float(rgb[i]) / 255, Float(rgb[i + 1]) / 255, Float(rgb[i + 2]) / 255, 1)
    }
}
