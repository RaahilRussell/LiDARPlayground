import Foundation

/// Explicit caps make saving a room-sized scan predictable and reject malformed
/// files before allocating unbounded vertex/index buffers.
nonisolated enum MapLimits {
    static let maxMeshAnchors = 2_000
    static let maxVertices = 750_000
    static let maxTriangles = 1_500_000
    static let maxTrailPoints = 6_000
    static let maxWorldMapBytes = 64 * 1_024 * 1_024
    static let maxGeometryBytes = 256 * 1_024 * 1_024
    static let maxReferenceImageBytes = 5 * 1_024 * 1_024
    static let maxKeyframes = 48
    static let maxKeyframeBytes = 2 * 1_024 * 1_024
    static let maxKeyframeTotalBytes = 32 * 1_024 * 1_024
    static let maxTextAnnotations = 20_000
    static let maxDirectionalSignage = 20_000
    static let maxTextEvidenceBytes = 48 * 1_024 * 1_024
    static let maxTextUTF8Bytes = 32 * 1_024 * 1_024
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

/// Durable world-space perception data. Camera-relative values such as TTC are
/// intentionally not stored; they are recomputed after relocalization.
nonisolated struct SavedPerceptionHazard: Codable, Sendable, Equatable {
    var position: MapPosition
    var radius: Float
    var label: String?
    var confidence: Float
    var minHeight: Float?
    var maxHeight: Float?
    var height: ObstacleHeight
}

nonisolated struct SavedMapMetadata: Codable, Identifiable, Sendable, Equatable {
    var id: UUID
    var name: String
    var createdAt: Date
    var updatedAt: Date
    var anchorCount: Int
    var vertexCount: Int
    var faceCount: Int
    /// Segments retain the same logical place identity when an automatic scan
    /// rolls over. Older maps are a single segment whose place ID is their ID.
    var placeID: UUID?
    var segmentIndex: Int

    init(id: UUID, name: String, createdAt: Date, updatedAt: Date,
         anchorCount: Int, vertexCount: Int, faceCount: Int,
         placeID: UUID? = nil, segmentIndex: Int = 0) {
        self.id = id; self.name = name; self.createdAt = createdAt; self.updatedAt = updatedAt
        self.anchorCount = anchorCount; self.vertexCount = vertexCount; self.faceCount = faceCount
        self.placeID = placeID; self.segmentIndex = segmentIndex
    }

    private nonisolated enum CodingKeys: String, CodingKey {
        case id, name, createdAt, updatedAt, anchorCount, vertexCount, faceCount, placeID, segmentIndex
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        anchorCount = try c.decode(Int.self, forKey: .anchorCount)
        vertexCount = try c.decode(Int.self, forKey: .vertexCount)
        faceCount = try c.decode(Int.self, forKey: .faceCount)
        placeID = try c.decodeIfPresent(UUID.self, forKey: .placeID)
        segmentIndex = try c.decodeIfPresent(Int.self, forKey: .segmentIndex) ?? 0
    }

    func validate() throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= MapLimits.maxNameLength else {
            throw MapStorageError.invalidName
        }
        guard createdAt.timeIntervalSince1970.isFinite,
              updatedAt.timeIntervalSince1970.isFinite,
              anchorCount >= 0, vertexCount >= 0, faceCount >= 0,
              segmentIndex >= 0 else {
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
    /// Linear RGBA quadruples, with alpha 1 for a real camera sample and 0 for
    /// an unseen vertex. A missing array is a legacy, uncoloured surface.
    var vertexColors: [Float]?
    /// Optional column-major capture pose. Rendering still uses world vertices;
    /// this pose lets later saves reuse colour samples in stable anchor space.
    var anchorTransform: [Float]?

    var vertexCount: Int { vertices.count / 3 }
    var faceCount: Int { triangleIndices.count / 3 }

    init(id: UUID, vertices: [Float], triangleIndices: [UInt32], vertexColors: [Float]? = nil,
         anchorTransform: [Float]? = nil) {
        self.id = id
        self.vertices = vertices
        self.triangleIndices = triangleIndices
        self.vertexColors = vertexColors
        self.anchorTransform = anchorTransform
    }

    // A binary payload avoids encoding millions of individual plist numbers.
    // Endianness is explicit so archived bytes are independent of host layout.
    private nonisolated enum CodingKeys: String, CodingKey { case id, vertices, triangleIndices, vertexColors, anchorTransform }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        let vertexData = try container.decode(Data.self, forKey: .vertices)
        let indexData = try container.decode(Data.self, forKey: .triangleIndices)
        let colorData = try container.decodeIfPresent(Data.self, forKey: .vertexColors)
        vertexColors = nil
        anchorTransform = try container.decodeIfPresent([Float].self, forKey: .anchorTransform)
        guard vertexData.count <= MapLimits.maxVertices * 12,
              indexData.count <= MapLimits.maxTriangles * 12,
              (colorData?.count ?? 0) <= MapLimits.maxVertices * 16 else {
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
        if let colorData {
            guard colorData.count == vertexCount * 16 else {
                throw MapStorageError.invalidGeometry("colour count does not match vertices")
            }
            vertexColors = colorData.withUnsafeBytes { bytes in
                stride(from: 0, to: bytes.count, by: 4).map {
                    Float(bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: $0, as: UInt32.self)))
                }
            }
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(anchorTransform, forKey: .anchorTransform)
        let vertexBits = vertices.map { $0.bitPattern.littleEndian }
        let indices = triangleIndices.map(\.littleEndian)
        try container.encode(vertexBits.withUnsafeBytes { Data($0) }, forKey: .vertices)
        try container.encode(indices.withUnsafeBytes { Data($0) }, forKey: .triangleIndices)
        if let vertexColors {
            let bits = vertexColors.map { $0.bitPattern.littleEndian }
            try container.encode(bits.withUnsafeBytes { Data($0) }, forKey: .vertexColors)
        }
    }
}

nonisolated struct SavedMapGeometry: Codable, Sendable, Equatable {
    var meshes: [MapMeshSnapshot]
    var trail: [MapPosition]
    var keyframes: [SavedMapKeyframe]
    var navigation: SavedNavigationGraph?
    var textAnnotations: [SavedTextAnnotation]
    var directionalSignage: [SavedDirectionalSignage]
    var perceptionHazards: [SavedPerceptionHazard]

    init(meshes: [MapMeshSnapshot], trail: [MapPosition], keyframes: [SavedMapKeyframe] = [],
         navigation: SavedNavigationGraph? = nil, textAnnotations: [SavedTextAnnotation] = [],
         directionalSignage: [SavedDirectionalSignage] = [],
         perceptionHazards: [SavedPerceptionHazard] = []) {
        self.meshes = meshes; self.trail = trail; self.keyframes = keyframes
        self.navigation = navigation; self.textAnnotations = textAnnotations
        self.directionalSignage = directionalSignage
        self.perceptionHazards = perceptionHazards
    }

    private nonisolated enum CodingKeys: String, CodingKey {
        case meshes, trail, keyframes, navigation, textAnnotations, directionalSignage, perceptionHazards
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        meshes = try c.decode([MapMeshSnapshot].self, forKey: .meshes)
        trail = try c.decode([MapPosition].self, forKey: .trail)
        keyframes = try c.decodeIfPresent([SavedMapKeyframe].self, forKey: .keyframes) ?? []
        navigation = try c.decodeIfPresent(SavedNavigationGraph.self, forKey: .navigation)
        textAnnotations = try c.decodeIfPresent([SavedTextAnnotation].self, forKey: .textAnnotations) ?? []
        directionalSignage = try c.decodeIfPresent([SavedDirectionalSignage].self, forKey: .directionalSignage) ?? []
        perceptionHazards = try c.decodeIfPresent([SavedPerceptionHazard].self, forKey: .perceptionHazards) ?? []
    }

    var vertexCount: Int { meshes.reduce(0) { $0 + $1.vertexCount } }
    var faceCount: Int { meshes.reduce(0) { $0 + $1.faceCount } }

    func validate() throws {
        guard meshes.count <= MapLimits.maxMeshAnchors,
              trail.count <= MapLimits.maxTrailPoints,
              keyframes.count <= MapLimits.maxKeyframes,
              textAnnotations.count <= MapLimits.maxTextAnnotations,
              directionalSignage.count <= MapLimits.maxDirectionalSignage else {
            throw MapStorageError.tooLarge("map")
        }
        guard perceptionHazards.count <= 200 else {
            throw MapStorageError.tooLarge("perception hazards")
        }
        for hazard in perceptionHazards {
            guard hazard.position.isValid,
                  hazard.radius.isFinite, hazard.radius >= 0, hazard.radius <= 100,
                  hazard.confidence.isFinite, (0...1).contains(hazard.confidence),
                  [hazard.minHeight, hazard.maxHeight].compactMap({ $0 }).allSatisfy({ $0.isFinite && abs($0) <= 100 }) else {
                throw MapStorageError.invalidGeometry("invalid perception hazard")
            }
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
            if let colors = mesh.vertexColors {
                guard colors.count == mesh.vertexCount * 4,
                      colors.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
                      stride(from: 3, to: colors.count, by: 4).allSatisfy({ colors[$0] == 0 || colors[$0] == 1 }) else {
                    throw MapStorageError.invalidGeometry("invalid captured vertex colours")
                }
            }
            if let transform = mesh.anchorTransform {
                guard transform.count == 16, transform.allSatisfy(\.isFinite),
                      abs(transform[3]) < 0.001, abs(transform[7]) < 0.001,
                      abs(transform[11]) < 0.001, abs(transform[15] - 1) < 0.001,
                      transform[12...14].allSatisfy({ abs($0) <= MapLimits.maxCoordinateMagnitude }) else {
                    throw MapStorageError.invalidGeometry("invalid surface capture pose")
                }
            }
        }
        guard trail.allSatisfy(\.isValid) else {
            throw MapStorageError.invalidGeometry("invalid camera trail")
        }
        var imageBytes = 0
        var keyframeIDs = Set<UUID>()
        for keyframe in keyframes {
            guard keyframeIDs.insert(keyframe.id).inserted else {
                throw MapStorageError.invalidGeometry("duplicate camera image identifier")
            }
            imageBytes += keyframe.jpegData.count
            guard imageBytes <= MapLimits.maxKeyframeTotalBytes else {
                throw MapStorageError.tooLarge("camera images")
            }
            try keyframe.validate()
        }
        try navigation?.validate()
        var textIDs = Set<UUID>(), signIDs = Set<UUID>()
        var evidenceBytes = 0
        var textBytes = 0
        for item in textAnnotations {
            try item.validate()
            guard textIDs.insert(item.id).inserted else {
                throw MapStorageError.invalidGeometry("duplicate text observation identifier")
            }
            evidenceBytes += item.evidenceJPEG?.count ?? 0
            textBytes += item.text.utf8.count
            guard evidenceBytes <= MapLimits.maxTextEvidenceBytes else {
                throw MapStorageError.tooLarge("text evidence images")
            }
        }
        for item in directionalSignage {
            try item.validate()
            evidenceBytes += item.evidenceJPEG?.count ?? 0
            textBytes += item.text.utf8.count
            guard evidenceBytes <= MapLimits.maxTextEvidenceBytes else {
                throw MapStorageError.tooLarge("text evidence images")
            }
            guard signIDs.insert(item.id).inserted, textIDs.contains(item.textAnnotationID) else {
                throw MapStorageError.invalidGeometry("invalid directional sign reference")
            }
        }
        guard textBytes <= MapLimits.maxTextUTF8Bytes else {
            throw MapStorageError.tooLarge("text observations")
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
