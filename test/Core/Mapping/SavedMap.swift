import Foundation

/// Explicit caps make saving a room-sized scan predictable and reject malformed
/// files before allocating unbounded vertex/index buffers.
nonisolated enum MapLimits {
    static let maxMeshAnchors = 2_000
    static let maxVertices = 750_000
    static let maxTriangles = 1_500_000
    static let maxTrailPoints = 6_000
    static let maxWorldMapBytes = 64 * 1_024 * 1_024
    static let maxGeometryBytes = 128 * 1_024 * 1_024
    static let maxReferenceImageBytes = 5 * 1_024 * 1_024
    static let maxNameLength = 80
    static let maxCoordinateMagnitude: Float = 10_000
}

nonisolated enum MapStorageError: Error, LocalizedError, Sendable {
    case invalidName
    case invalidGeometry(String)
    case tooLarge(String)
    case invalidArchive(String)
    case unsupportedVersion(Int)
    case notFound

    var errorDescription: String? {
        switch self {
        case .invalidName:
            return "Give this place a name between 1 and \(MapLimits.maxNameLength) characters."
        case .invalidGeometry(let reason):
            return "The saved surface cannot be read: \(reason)"
        case .tooLarge(let part):
            return "This \(part) exceeds the room-map storage limit. Save a smaller area."
        case .invalidArchive(let reason):
            return "The saved place cannot be opened: \(reason)"
        case .unsupportedVersion(let version):
            return "This place uses map format \(version), which this version of the app cannot read."
        case .notFound:
            return "This saved place is no longer available."
        }
    }
}

nonisolated struct MapPosition: Codable, Sendable, Equatable {
    var x: Float
    var y: Float
    var z: Float

    var isValid: Bool {
        [x, y, z].allSatisfy { $0.isFinite && abs($0) <= MapLimits.maxCoordinateMagnitude }
    }
}

nonisolated struct SavedMapMetadata: Codable, Identifiable, Sendable, Equatable {
    var id: UUID
    var name: String
    var createdAt: Date
    var updatedAt: Date
    var anchorCount: Int
    var vertexCount: Int
    var faceCount: Int

    func validate() throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= MapLimits.maxNameLength else {
            throw MapStorageError.invalidName
        }
        guard createdAt.timeIntervalSince1970.isFinite,
              updatedAt.timeIntervalSince1970.isFinite,
              anchorCount >= 0, vertexCount >= 0, faceCount >= 0 else {
            throw MapStorageError.invalidArchive("invalid metadata")
        }
        guard anchorCount <= MapLimits.maxMeshAnchors,
              vertexCount <= MapLimits.maxVertices, faceCount <= MapLimits.maxTriangles else {
            throw MapStorageError.tooLarge("map")
        }
    }
}

/// World-space XYZ triples in metres. The captured geometry owns its bytes; no
/// ARKit Metal buffer or ARFrame is retained by the offline map library.
nonisolated struct MapMeshSnapshot: Codable, Identifiable, Sendable, Equatable {
    var id: UUID
    var vertices: [Float]
    var triangleIndices: [UInt32]

    var vertexCount: Int { vertices.count / 3 }
    var faceCount: Int { triangleIndices.count / 3 }

    init(id: UUID, vertices: [Float], triangleIndices: [UInt32]) {
        self.id = id
        self.vertices = vertices
        self.triangleIndices = triangleIndices
    }

    // A binary payload avoids encoding millions of individual plist numbers.
    // Endianness is explicit so archived bytes are independent of host layout.
    private nonisolated enum CodingKeys: String, CodingKey { case id, vertices, triangleIndices }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        let vertexData = try container.decode(Data.self, forKey: .vertices)
        let indexData = try container.decode(Data.self, forKey: .triangleIndices)
        guard vertexData.count <= MapLimits.maxVertices * 12,
              indexData.count <= MapLimits.maxTriangles * 12 else {
            throw MapStorageError.tooLarge("surface")
        }
        guard vertexData.count.isMultiple(of: 12), indexData.count.isMultiple(of: 12) else {
            throw MapStorageError.invalidGeometry("incomplete vertex or triangle")
        }
        vertices = vertexData.withUnsafeBytes { bytes in
            stride(from: 0, to: bytes.count, by: 4).map {
                Float(bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: $0, as: UInt32.self)))
            }
        }
        triangleIndices = indexData.withUnsafeBytes { bytes in
            stride(from: 0, to: bytes.count, by: 4).map {
                UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: $0, as: UInt32.self))
            }
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        let vertexBits = vertices.map { $0.bitPattern.littleEndian }
        let indices = triangleIndices.map(\.littleEndian)
        try container.encode(vertexBits.withUnsafeBytes { Data($0) }, forKey: .vertices)
        try container.encode(indices.withUnsafeBytes { Data($0) }, forKey: .triangleIndices)
    }
}

nonisolated struct SavedMapGeometry: Codable, Sendable, Equatable {
    var meshes: [MapMeshSnapshot]
    var trail: [MapPosition]

    var vertexCount: Int { meshes.reduce(0) { $0 + $1.vertexCount } }
    var faceCount: Int { meshes.reduce(0) { $0 + $1.faceCount } }

    func validate() throws {
        guard meshes.count <= MapLimits.maxMeshAnchors,
              trail.count <= MapLimits.maxTrailPoints else {
            throw MapStorageError.tooLarge("map")
        }
        var ids = Set<UUID>()
        var vertices = 0
        var faces = 0
        for mesh in meshes {
            guard ids.insert(mesh.id).inserted else {
                throw MapStorageError.invalidGeometry("duplicate surface identifier")
            }
            guard mesh.vertices.count.isMultiple(of: 3),
                  mesh.triangleIndices.count.isMultiple(of: 3) else {
                throw MapStorageError.invalidGeometry("incomplete vertex or triangle")
            }
            vertices += mesh.vertexCount
            faces += mesh.faceCount
            guard vertices <= MapLimits.maxVertices, faces <= MapLimits.maxTriangles else {
                throw MapStorageError.tooLarge("surface")
            }
            guard mesh.vertices.allSatisfy({ $0.isFinite && abs($0) <= MapLimits.maxCoordinateMagnitude }) else {
                throw MapStorageError.invalidGeometry("nonfinite or out-of-range position")
            }
            guard mesh.triangleIndices.allSatisfy({ Int($0) < mesh.vertexCount }) else {
                throw MapStorageError.invalidGeometry("triangle refers to a missing vertex")
            }
        }
        guard trail.allSatisfy(\.isValid) else {
            throw MapStorageError.invalidGeometry("invalid camera trail")
        }
    }
}

nonisolated struct MapArchive: Sendable {
    var metadata: SavedMapMetadata
    var geometry: SavedMapGeometry
    var worldMapData: Data
    var referenceImageData: Data?

    func validate() throws {
        try metadata.validate()
        try geometry.validate()
        guard geometry.faceCount > 0 else {
            throw MapStorageError.invalidGeometry("scan a surface before saving")
        }
        guard metadata.anchorCount == geometry.meshes.count,
              metadata.vertexCount == geometry.vertexCount,
              metadata.faceCount == geometry.faceCount else {
            throw MapStorageError.invalidArchive("surface counts do not match the manifest")
        }
        guard !worldMapData.isEmpty else {
            throw MapStorageError.invalidArchive("the tracking map is missing")
        }
        guard worldMapData.count <= MapLimits.maxWorldMapBytes else {
            throw MapStorageError.tooLarge("tracking map")
        }
        guard (referenceImageData?.count ?? 0) <= MapLimits.maxReferenceImageBytes else {
            throw MapStorageError.tooLarge("reference photo")
        }
    }
}
