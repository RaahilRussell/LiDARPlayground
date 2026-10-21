import CoreVideo
import Foundation
import simd

/// The only unchecked boundary is the read-only ownership of these retained
/// pixel buffers. No ARFrame, ARMeshAnchor, or mutable Metal buffer crosses it.
nonisolated struct MapColorFrame: @unchecked Sendable {
    let image: CVPixelBuffer
    let depth: CVPixelBuffer?
    let confidence: CVPixelBuffer?
    let cameraTransform: simd_float4x4
    let intrinsics: simd_float3x3
    let capturedAt: Date
}

nonisolated struct MapColorCell: Hashable, Sendable {
    let x: Int32
    let y: Int32
    let z: Int32

    init?(_ position: SIMD3<Float>) {
        guard position.x.isFinite, position.y.isFinite, position.z.isFinite,
              max(abs(position.x), max(abs(position.y), abs(position.z))) <= MapLimits.maxCoordinateMagnitude else { return nil }
        // One-centimetre cells survive ARKit vertex reordering. Anchor-local
        // cells also survive changes to that anchor's world transform.
        x = Int32((position.x * 100).rounded())
        y = Int32((position.y * 100).rounded())
        z = Int32((position.z * 100).rounded())
    }
}

nonisolated struct MapColorCandidate: Sendable {
    let anchorID: UUID
    let cell: MapColorCell
    let worldPosition: SIMD3<Float>
}

nonisolated struct MapColorSample: Sendable {
    let anchorID: UUID
    let cell: MapColorCell
    let color: SIMD4<Float>
}

nonisolated enum MapColorSampling {
    nonisolated struct Projection: Sendable, Equatable {
        let x: Float
        let y: Float
        let depth: Float
    }

    /// ARKit camera axes are right/up/back. Native image axes are right/down;
    /// projection therefore negates camera Y and uses forward depth = -Z.
    static func project(_ world: SIMD3<Float>, worldToCamera: simd_float4x4,
                        intrinsics: simd_float3x3, width: Int, height: Int) -> Projection? {
        let camera = worldToCamera * SIMD4(world, 1)
        let depth = -camera.z
        guard depth.isFinite, depth > 0.05 else { return nil }
        let pixel = intrinsics * SIMD3(camera.x / depth, -camera.y / depth, 1)
        guard pixel.x.isFinite, pixel.y.isFinite,
              pixel.x >= 0, pixel.y >= 0, pixel.x < Float(width), pixel.y < Float(height) else { return nil }
        return Projection(x: pixel.x, y: pixel.y, depth: depth)
    }

    static func depthAgrees(projected: Float, measured: Float, confidence: UInt8) -> Bool {
        confidence >= 1 && confidence <= 2 && projected.isFinite && measured.isFinite && measured > 0
            && abs(projected - measured) <= max(0.04, measured * 0.02)
    }

    static func linearComponent(_ srgb: Float) -> Float {
        let value = min(1, max(0, srgb))
        return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }

    static func sample(_ candidates: [MapColorCandidate], from frame: MapColorFrame) -> [MapColorSample] {
        guard let depth = frame.depth, let confidence = frame.confidence,
              CVPixelBufferGetPixelFormatType(depth) == kCVPixelFormatType_DepthFloat32,
              CVPixelBufferGetPixelFormatType(confidence) == kCVPixelFormatType_OneComponent8 else { return [] }
        let width = CVPixelBufferGetWidth(frame.image), height = CVPixelBufferGetHeight(frame.image)
        let dw = CVPixelBufferGetWidth(depth), dh = CVPixelBufferGetHeight(depth)
        guard width > 0, height > 0, dw > 0, dh > 0,
              CVPixelBufferGetWidth(confidence) == dw, CVPixelBufferGetHeight(confidence) == dh else { return [] }
        guard CVPixelBufferLockBaseAddress(frame.image, .readOnly) == kCVReturnSuccess else { return [] }
        defer { CVPixelBufferUnlockBaseAddress(frame.image, .readOnly) }
        guard CVPixelBufferLockBaseAddress(depth, .readOnly) == kCVReturnSuccess else { return [] }
        defer { CVPixelBufferUnlockBaseAddress(depth, .readOnly) }
        guard CVPixelBufferLockBaseAddress(confidence, .readOnly) == kCVReturnSuccess else { return [] }
        defer { CVPixelBufferUnlockBaseAddress(confidence, .readOnly) }
        guard let depthBase = CVPixelBufferGetBaseAddress(depth),
              let confidenceBase = CVPixelBufferGetBaseAddress(confidence) else { return [] }
        let depthStride = CVPixelBufferGetBytesPerRow(depth), confidenceStride = CVPixelBufferGetBytesPerRow(confidence)
        guard depthStride >= dw * 4, confidenceStride >= dw else { return [] }

        let format = CVPixelBufferGetPixelFormatType(frame.image)
        let bgra = format == kCVPixelFormatType_32BGRA
        let yuv = format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        guard bgra || yuv else { return [] }
        let imageBase: UnsafeMutableRawPointer?
        let chromaBase: UnsafeMutableRawPointer?
        let imageStride: Int
        let chromaStride: Int
        if bgra {
            imageBase = CVPixelBufferGetBaseAddress(frame.image)
            chromaBase = nil
            imageStride = CVPixelBufferGetBytesPerRow(frame.image)
            chromaStride = 0
            guard imageStride >= width * 4 else { return [] }
        } else {
            guard CVPixelBufferGetPlaneCount(frame.image) == 2,
                  CVPixelBufferGetWidthOfPlane(frame.image, 0) == width,
                  CVPixelBufferGetHeightOfPlane(frame.image, 0) == height,
                  CVPixelBufferGetWidthOfPlane(frame.image, 1) >= (width + 1) / 2,
                  CVPixelBufferGetHeightOfPlane(frame.image, 1) >= (height + 1) / 2 else { return [] }
            imageBase = CVPixelBufferGetBaseAddressOfPlane(frame.image, 0)
            chromaBase = CVPixelBufferGetBaseAddressOfPlane(frame.image, 1)
            imageStride = CVPixelBufferGetBytesPerRowOfPlane(frame.image, 0)
            chromaStride = CVPixelBufferGetBytesPerRowOfPlane(frame.image, 1)
            guard imageStride >= width, chromaStride >= ((width + 1) / 2) * 2, chromaBase != nil else { return [] }
            // ARKit documents full-range ITU-R 601. Refuse a different matrix
            // instead of silently producing incorrectly calibrated colours.
            if let matrix = CVBufferCopyAttachment(frame.image, kCVImageBufferYCbCrMatrixKey, nil),
               !CFEqual(matrix, kCVImageBufferYCbCrMatrix_ITU_R_601_4) { return [] }
        }
        guard let imageBase else { return [] }
        let inverse = frame.cameraTransform.inverse
        var result: [MapColorSample] = []
        result.reserveCapacity(candidates.count)
        for (index, candidate) in candidates.enumerated() {
            if index.isMultiple(of: 512), Task.isCancelled { return [] }
            guard let projected = project(candidate.worldPosition, worldToCamera: inverse,
                                          intrinsics: frame.intrinsics, width: width, height: height) else { continue }
            let dx = min(dw - 1, Int(projected.x * Float(dw) / Float(width)))
            let dy = min(dh - 1, Int(projected.y * Float(dh) / Float(height)))
            let measured = depthBase.loadUnaligned(fromByteOffset: dy * depthStride + dx * 4, as: Float.self)
            let quality = confidenceBase.load(fromByteOffset: dy * confidenceStride + dx, as: UInt8.self)
            guard depthAgrees(projected: projected.depth, measured: measured, confidence: quality) else { continue }
            let x = Int(projected.x), y = Int(projected.y)
            let rgb: SIMD3<Float>
            if bgra {
                let offset = y * imageStride + x * 4
                rgb = SIMD3(Float(imageBase.load(fromByteOffset: offset + 2, as: UInt8.self)) / 255,
                            Float(imageBase.load(fromByteOffset: offset + 1, as: UInt8.self)) / 255,
                            Float(imageBase.load(fromByteOffset: offset, as: UInt8.self)) / 255)
            } else {
                let luminance = Float(imageBase.load(fromByteOffset: y * imageStride + x, as: UInt8.self)) / 255
                let offset = (y / 2) * chromaStride + (x / 2) * 2
                let cb = Float(chromaBase!.load(fromByteOffset: offset, as: UInt8.self)) / 255 - 0.5
                let cr = Float(chromaBase!.load(fromByteOffset: offset + 1, as: UInt8.self)) / 255 - 0.5
                rgb = SIMD3(luminance + 1.402 * cr, luminance - 0.344136 * cb - 0.714136 * cr,
                            luminance + 1.772 * cb)
            }
            result.append(MapColorSample(anchorID: candidate.anchorID, cell: candidate.cell,
                color: SIMD4(linearComponent(rgb.x), linearComponent(rgb.y), linearComponent(rgb.z), 1)))
        }
        return result
    }
}
