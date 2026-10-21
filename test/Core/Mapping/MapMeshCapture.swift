import ARKit
import Metal
import simd

extension MapMeshSnapshot {
    /// Copy a mesh while on the session's actor. Its transform is baked into the
    /// positions so a saved map can be rendered without ARKit or a live camera.
    @MainActor static func capture(_ anchor: ARMeshAnchor) throws -> MapMeshSnapshot {
        let mesh = anchor.geometry
        let source = mesh.vertices
        let faces = mesh.faces
        guard source.count <= MapLimits.maxVertices, faces.count <= MapLimits.maxTriangles else {
            throw MapStorageError.tooLarge("surface")
        }
        guard source.format == .float3, source.stride >= 12, source.offset >= 0,
              faces.indexCountPerPrimitive == 3, [2, 4].contains(faces.bytesPerIndex),
              faces.count * 3 * faces.bytesPerIndex <= faces.buffer.length,
              source.count == 0 || source.offset + (source.count - 1) * source.stride + 12 <= source.buffer.length else {
            throw MapStorageError.invalidGeometry("unsupported mesh buffer layout")
        }
        var positions: [Float] = []
        positions.reserveCapacity(source.count * 3)
        let base = source.buffer.contents()
        for index in 0..<source.count {
            let pointer = base.advanced(by: source.offset + index * source.stride)
            let local = SIMD4<Float>(
                pointer.loadUnaligned(as: Float.self),
                pointer.loadUnaligned(fromByteOffset: 4, as: Float.self),
                pointer.loadUnaligned(fromByteOffset: 8, as: Float.self), 1)
            let world = anchor.transform * local
            positions.append(world.x)
            positions.append(world.y)
            positions.append(world.z)
        }
        let indexBase = faces.buffer.contents()
        var indices: [UInt32] = []
        indices.reserveCapacity(faces.count * 3)
        for index in 0..<(faces.count * 3) {
            let offset = index * faces.bytesPerIndex
            let value = faces.bytesPerIndex == 2
                ? UInt32(indexBase.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
                : indexBase.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
            guard Int(value) < source.count else {
                throw MapStorageError.invalidGeometry("triangle refers to a missing vertex")
            }
            indices.append(value)
        }
        let transform = anchor.transform
        let snapshot = MapMeshSnapshot(id: anchor.identifier, vertices: positions, triangleIndices: indices,
            anchorTransform: (0..<4).flatMap { column in (0..<4).map { transform[column][$0] } })
        try SavedMapGeometry(meshes: [snapshot], trail: []).validate()
        return snapshot
    }
}
