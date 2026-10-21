import ARKit
import CoreImage
import Foundation
import ImageIO
import Metal
import UIKit
import simd

/// A first valid observation wins. Unseen cells can be filled by later views,
/// and local position keys survive mesh topology/vertex-order changes.
nonisolated struct MapColorCache: Sendable {
    private var local: [UUID: [MapColorCell: SIMD4<Float>]] = [:]
    private var restoredWorld: [UUID: [MapColorCell: SIMD4<Float>]] = [:]
    private(set) var count = 0

    mutating func restore(_ meshes: [MapMeshSnapshot]) {
        self = Self()
        for mesh in meshes {
            guard let colors = mesh.vertexColors, colors.count == mesh.vertexCount * 4 else { continue }
            let inverse = mesh.colorWorldToLocal
            for i in 0..<mesh.vertexCount where colors[i * 4 + 3] == 1 {
                let position = SIMD3(mesh.vertices[i * 3], mesh.vertices[i * 3 + 1], mesh.vertices[i * 3 + 2])
                if let inverse {
                    let p = inverse * SIMD4(position, 1)
                    guard let cell = MapColorCell(SIMD3(p.x, p.y, p.z)), local[mesh.id]?[cell] == nil,
                          count < MapLimits.maxVertices else { continue }
                    local[mesh.id, default: [:]][cell] = SIMD4(colors[i * 4], colors[i * 4 + 1], colors[i * 4 + 2], 1)
                    count += 1
                    continue
                }
                guard let cell = MapColorCell(position), restoredWorld[mesh.id]?[cell] == nil,
                      count < MapLimits.maxVertices else { continue }
                restoredWorld[mesh.id, default: [:]][cell] = SIMD4(colors[i * 4], colors[i * 4 + 1], colors[i * 4 + 2], 1)
                count += 1
            }
        }
    }

    mutating func containsOrAdopt(anchorID: UUID, localCell: MapColorCell, worldPosition: SIMD3<Float>) -> Bool {
        if local[anchorID]?[localCell] != nil { return true }
        guard let worldCell = MapColorCell(worldPosition),
              let color = restoredWorld[anchorID]?[worldCell] else { return false }
        restoredWorld[anchorID]?[worldCell] = nil
        local[anchorID, default: [:]][localCell] = color
        return true
    }

    mutating func merge(_ samples: [MapColorSample]) {
        for sample in samples where local[sample.anchorID]?[sample.cell] == nil {
            guard count < MapLimits.maxVertices else { return }
            local[sample.anchorID, default: [:]][sample.cell] = sample.color
            count += 1
        }
    }

    func colors(for mesh: MapMeshSnapshot, worldToLocal: simd_float4x4?) -> [Float]? {
        var result = mesh.vertexColors ?? [Float](repeating: 0, count: mesh.vertexCount * 4)
        guard result.count == mesh.vertexCount * 4 else { return mesh.vertexColors }
        var found = false
        for i in 0..<mesh.vertexCount {
            if result[i * 4 + 3] == 1 { found = true; continue }
            let world = SIMD3(mesh.vertices[i * 3], mesh.vertices[i * 3 + 1], mesh.vertices[i * 3 + 2])
            var color: SIMD4<Float>?
            if let worldToLocal {
                let point = worldToLocal * SIMD4(world, 1)
                if let key = MapColorCell(SIMD3(point.x, point.y, point.z)) { color = local[mesh.id]?[key] }
            }
            if color == nil, let key = MapColorCell(world) { color = restoredWorld[mesh.id]?[key] }
            guard let color else { continue }
            result[i * 4] = color.x; result[i * 4 + 1] = color.y
            result[i * 4 + 2] = color.z; result[i * 4 + 3] = 1
            found = true
        }
        return found ? result : nil
    }
}

@MainActor
final class MappingColorCapture {
    private var generation = -1
    private var cache = MapColorCache()
    private var transforms: [UUID: simd_float4x4] = [:]
    private var vertexOffsets: [UUID: Int] = [:]
    private var anchorOffset = 0
    private var keyframes: [SavedMapKeyframe] = []
    private var keyframeBytes = 0
    private var lastObservation: TimeInterval = -.infinity
    private var lastKeyframePose: simd_float4x4?
    private var lastKeyframeDate: Date?
    private var processingTask: Task<Void, Never>?
    private var operationID = UUID()
    private(set) var lastError: String?

    var needsSegmentRollover: Bool {
        keyframes.count >= MapLimits.maxKeyframes - 1 ||
        keyframeBytes >= MapLimits.maxKeyframeTotalBytes - MapLimits.maxKeyframeBytes ||
        cache.count >= MapLimits.maxVertices - 30_000
    }

    func reset(generation: Int) {
        processingTask?.cancel(); processingTask = nil
        operationID = UUID(); self.generation = generation
        cache = MapColorCache(); transforms = [:]; vertexOffsets = [:]; anchorOffset = 0
        keyframes = []; keyframeBytes = 0; lastObservation = -.infinity
        lastKeyframePose = nil; lastKeyframeDate = nil; lastError = nil
    }

    func restore(geometry: SavedMapGeometry, generation: Int) {
        reset(generation: generation)
        cache.restore(geometry.meshes)
        keyframes = geometry.keyframes
        keyframeBytes = keyframes.reduce(0) { $0 + $1.jpegData.count }
        if let last = keyframes.max(by: { $0.capturedAt < $1.capturedAt }), last.cameraTransform.count == 16 {
            let m = last.cameraTransform
            lastKeyframePose = simd_float4x4(columns: (SIMD4(m[0], m[1], m[2], m[3]),
                SIMD4(m[4], m[5], m[6], m[7]), SIMD4(m[8], m[9], m[10], m[11]), SIMD4(m[12], m[13], m[14], m[15])))
            lastKeyframeDate = last.capturedAt
        }
    }

    /// The manager calls this only for an accepted frame in the active origin.
    /// At most one worker owns sensor buffers, sampled twice a second.
    func observe(frame: ARFrame, generation: Int, eligibleAnchorIDs: Set<UUID>? = nil) {
        guard generation == self.generation, processingTask == nil,
              frame.timestamp - lastObservation >= 0.5,
              case .normal = frame.camera.trackingState else { return }
        lastObservation = frame.timestamp
        let date = Date()
        let pose = frame.camera.transform
        let shouldCaptureImage = shouldCaptureKeyframe(pose: pose, date: date)
        let anchors = frame.anchors.compactMap { $0 as? ARMeshAnchor }
            .filter { eligibleAnchorIDs?.contains($0.identifier) ?? true }
        let candidates = captureCandidates(anchors)
        guard !candidates.isEmpty || shouldCaptureImage else { return }
        let depth = frame.sceneDepth ?? frame.smoothedSceneDepth
        let input = MapColorFrame(image: frame.capturedImage, depth: depth?.depthMap,
            confidence: depth?.confidenceMap, cameraTransform: pose,
            intrinsics: frame.camera.intrinsics, capturedAt: date, imageOrientation: imageOrientation())
        let operation = UUID()
        operationID = operation
        let worker = Task.detached(priority: .utility) {
            let samples = MapColorSampling.sample(candidates, from: input)
            var image: SavedMapKeyframe?
            var errorMessage: String?
            if shouldCaptureImage, !Task.isCancelled {
                do { image = try MapKeyframeEncoder.encode(input) }
                catch { errorMessage = error.localizedDescription }
            }
            return MapColorObservation(samples: samples, image: image, errorMessage: errorMessage)
        }
        processingTask = Task { [weak self] in
            let observation = await withTaskCancellationHandler {
                await worker.value
            } onCancel: { worker.cancel() }
            guard !Task.isCancelled, let self, self.generation == generation,
                  self.operationID == operation else { return }
            self.cache.merge(observation.samples)
            if let image = observation.image {
                self.keyframes.append(image)
                self.keyframeBytes += image.jpegData.count
                self.lastKeyframePose = pose; self.lastKeyframeDate = date
            }
            if let error = observation.errorMessage { self.lastError = error }
            else if observation.image != nil { self.lastError = nil }
            self.processingTask = nil
        }
    }

    func flush() async { await processingTask?.value }

    private func imageOrientation() -> UInt32 {
        let orientation = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }?.effectiveGeometry.interfaceOrientation ?? .portrait
        switch orientation {
        case .portrait: return 6
        case .portraitUpsideDown: return 8
        case .landscapeLeft: return 3
        case .landscapeRight: return 1
        default: return 6
        }
    }

    /// Non-destructive: an unsuccessful save must never consume photos or
    /// colours. The caller resets only after a durable save and origin change.
    func applying(to geometry: SavedMapGeometry) -> SavedMapGeometry {
        var result = geometry
        for index in result.meshes.indices {
            let mesh = result.meshes[index]
            result.meshes[index].vertexColors = cache.colors(for: mesh,
                worldToLocal: mesh.colorWorldToLocal ?? transforms[mesh.id]?.inverse)
        }
        var images = Dictionary(uniqueKeysWithValues: geometry.keyframes.map { ($0.id, $0) })
        for image in keyframes { images[image.id] = image }
        result.keyframes = images.values.sorted { $0.capturedAt == $1.capturedAt
            ? $0.id.uuidString < $1.id.uuidString : $0.capturedAt < $1.capturedAt }
        return result
    }

    private func shouldCaptureKeyframe(pose: simd_float4x4, date: Date) -> Bool {
        guard keyframes.count < MapLimits.maxKeyframes,
              keyframeBytes <= MapLimits.maxKeyframeTotalBytes - MapLimits.maxKeyframeBytes else { return false }
        guard let previous = lastKeyframePose, let previousDate = lastKeyframeDate else { return true }
        guard date.timeIntervalSince(previousDate) >= 6 else { return false }
        let displacement = simd_distance(SIMD3(pose.columns.3.x, pose.columns.3.y, pose.columns.3.z),
            SIMD3(previous.columns.3.x, previous.columns.3.y, previous.columns.3.z))
        let forward = SIMD3(pose.columns.2.x, pose.columns.2.y, pose.columns.2.z)
        let oldForward = SIMD3(previous.columns.2.x, previous.columns.2.y, previous.columns.2.z)
        return displacement >= 0.35 || simd_dot(forward, oldForward) < cos(Float.pi / 9)
    }

    private func captureCandidates(_ anchors: [ARMeshAnchor]) -> [MapColorCandidate] {
        guard !anchors.isEmpty, cache.count < MapLimits.maxVertices else { return [] }
        let sorted = anchors.sorted { $0.identifier.uuidString < $1.identifier.uuidString }
        var candidates: [MapColorCandidate] = []
        candidates.reserveCapacity(24_000)
        var examined = 0
        var visited = 0
        for offset in 0..<sorted.count {
            guard examined < 40_000, candidates.count < 24_000 else { break }
            let anchor = sorted[(anchorOffset + offset) % sorted.count]
            visited += 1
            let source = anchor.geometry.vertices
            guard source.count > 0, source.count <= MapLimits.maxVertices,
                  source.format == .float3, source.stride >= 12, source.offset >= 0,
                  source.offset + (source.count - 1) * source.stride + 12 <= source.buffer.length else { continue }
            transforms[anchor.identifier] = anchor.transform
            let start = vertexOffsets[anchor.identifier, default: 0] % source.count
            var scanned = 0
            let base = source.buffer.contents()
            for offset in 0..<min(source.count, 6_000) {
                guard examined < 40_000, candidates.count < 24_000 else { break }
                let index = (start + offset) % source.count
                scanned += 1; examined += 1
                let p = base.advanced(by: source.offset + index * source.stride)
                let local = SIMD3(p.loadUnaligned(as: Float.self),
                    p.loadUnaligned(fromByteOffset: 4, as: Float.self), p.loadUnaligned(fromByteOffset: 8, as: Float.self))
                guard let cell = MapColorCell(local) else { continue }
                let w = anchor.transform * SIMD4(local, 1)
                let world = SIMD3(w.x, w.y, w.z)
                guard !cache.containsOrAdopt(anchorID: anchor.identifier, localCell: cell, worldPosition: world) else { continue }
                candidates.append(MapColorCandidate(anchorID: anchor.identifier, cell: cell, worldPosition: world))
            }
            vertexOffsets[anchor.identifier] = (start + scanned) % source.count
        }
        anchorOffset = (anchorOffset + max(1, visited)) % sorted.count
        return candidates
    }
}

private extension MapMeshSnapshot {
    nonisolated var colorWorldToLocal: simd_float4x4? {
        guard let m = anchorTransform, m.count == 16 else { return nil }
        let matrix = simd_float4x4(columns: (SIMD4(m[0], m[1], m[2], m[3]),
            SIMD4(m[4], m[5], m[6], m[7]), SIMD4(m[8], m[9], m[10], m[11]), SIMD4(m[12], m[13], m[14], m[15])))
        guard abs(matrix.determinant) > 0.001 else { return nil }
        return matrix.inverse
    }
}

private nonisolated struct MapColorObservation: Sendable {
    let samples: [MapColorSample]
    let image: SavedMapKeyframe?
    let errorMessage: String?
}

nonisolated enum MapKeyframeEncoder {
    static func encode(_ frame: MapColorFrame) throws -> SavedMapKeyframe {
        let sourceWidth = CVPixelBufferGetWidth(frame.image), sourceHeight = CVPixelBufferGetHeight(frame.image)
        guard sourceWidth > 0, sourceHeight > 0 else {
            throw MapStorageError.invalidGeometry("camera image has no pixels")
        }
        let scale = min(1, 1_024 / Double(max(sourceWidth, sourceHeight)))
        let width = max(1, Int((Double(sourceWidth) * scale).rounded()))
        let height = max(1, Int((Double(sourceHeight) * scale).rounded()))
        let sx = CGFloat(width) / CGFloat(sourceWidth), sy = CGFloat(height) / CGFloat(sourceHeight)
        let image = CIImage(cvPixelBuffer: frame.image).transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        let context = CIContext(options: [.cacheIntermediates: false])
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let cgImage = context.createCGImage(image, from: CGRect(x: 0, y: 0, width: width, height: height),
                  format: .RGBA8, colorSpace: colorSpace) else {
            throw MapStorageError.invalidGeometry("camera image could not be copied")
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else {
            throw MapStorageError.invalidGeometry("camera image encoder is unavailable")
        }
        CGImageDestinationAddImage(destination, cgImage,
            [kCGImageDestinationLossyCompressionQuality: 0.72,
             kCGImagePropertyOrientation: frame.imageOrientation] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw MapStorageError.invalidGeometry("camera image could not be encoded")
        }
        var intrinsics = frame.intrinsics
        for column in 0..<3 { intrinsics[column][0] *= Float(sx); intrinsics[column][1] *= Float(sy) }
        let matrix = frame.cameraTransform
        let result = SavedMapKeyframe(id: UUID(), capturedAt: frame.capturedAt,
            cameraTransform: (0..<4).flatMap { column in (0..<4).map { matrix[column][$0] } },
            intrinsics: (0..<3).flatMap { column in (0..<3).map { intrinsics[column][$0] } },
            imageWidth: width, imageHeight: height, jpegData: data as Data)
        try result.validate()
        return result
    }
}
