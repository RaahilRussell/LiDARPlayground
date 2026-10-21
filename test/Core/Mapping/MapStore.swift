import Foundation

/// Owns all map disk I/O. Each save writes an immutable revision, then atomically
/// changes a small manifest to point at it. An interrupted save therefore leaves
/// the previous version readable, without a partially replaced map bundle.
actor MapStore {
    private let rootURL: URL
    private let fileManager = FileManager.default
    private static let formatVersion = 1
    private static let manifestLimit = 32 * 1_024

    private nonisolated struct Manifest: Codable, Sendable {
        var formatVersion: Int
        var revision: UUID
        var metadata: SavedMapMetadata
        var hasReferenceImage: Bool
    }

    init(rootURL: URL? = nil) {
        self.rootURL = rootURL ?? FileManager.default.urls(for: .applicationSupportDirectory,
                                                          in: .userDomainMask)[0]
            .appendingPathComponent("SavedPlaces", isDirectory: true)
    }

    func list() throws -> [SavedMapMetadata] {
        try prepareRoot()
        let directories = try fileManager.contentsOfDirectory(at: rootURL,
                                                              includingPropertiesForKeys: [.isDirectoryKey],
                                                              options: [.skipsHiddenFiles])
        var maps: [SavedMapMetadata] = []
        for directory in directories {
            guard directory.pathExtension == "lidarmap",
                  let id = UUID(uuidString: directory.deletingPathExtension().lastPathComponent),
                  (try? requireDirectory(directory)) != nil else { continue }
            // A directory without a manifest is an interrupted initial save.
            // A corrupt committed manifest stays visible so the user can open
            // it for a diagnostic or delete it from the normal library menu.
            guard fileManager.fileExists(atPath: directory.appendingPathComponent("manifest.json").path) else { continue }
            if let manifest = try? readManifest(id: id) {
                maps.append(manifest.metadata)
            } else {
                let modified = (try? directory.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                maps.append(SavedMapMetadata(id: id, name: "Unreadable saved place",
                                              createdAt: modified, updatedAt: modified,
                                              anchorCount: 0, vertexCount: 0, faceCount: 0))
            }
        }
        return maps.sorted { $0.updatedAt > $1.updatedAt }
    }

    func load(id: UUID) throws -> MapArchive {
        let manifest = try readManifest(id: id)
        let revision = mapURL(id).appendingPathComponent(manifest.revision.uuidString, isDirectory: true)
        try requireDirectory(revision)
        let geometryData = try readBounded(revision.appendingPathComponent("geometry.plist"),
                                           maximum: MapLimits.maxGeometryBytes)
        let geometry = try PropertyListDecoder().decode(SavedMapGeometry.self, from: geometryData)
        let worldMapData = try readBounded(revision.appendingPathComponent("worldmap.archive"),
                                           maximum: MapLimits.maxWorldMapBytes)
        let referenceImageData = manifest.hasReferenceImage
            ? try readBounded(revision.appendingPathComponent("reference.jpg"),
                              maximum: MapLimits.maxReferenceImageBytes)
            : nil
        let archive = MapArchive(metadata: manifest.metadata, geometry: geometry,
                                 worldMapData: worldMapData, referenceImageData: referenceImageData)
        try archive.validate()
        return archive
    }

    func save(_ archive: MapArchive) throws {
        try archive.validate()
        try prepareRoot()
        let directory = mapURL(archive.metadata.id)
        if fileManager.fileExists(atPath: directory.path) {
            try requireDirectory(directory)
        } else {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
        }
        let revisionID = UUID()
        let revision = directory.appendingPathComponent(revisionID.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: revision, withIntermediateDirectories: false)
        var committed = false
        defer {
            if !committed { try? fileManager.removeItem(at: revision) }
        }

        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let geometryData = try encoder.encode(archive.geometry)
        guard geometryData.count <= MapLimits.maxGeometryBytes else {
            throw MapStorageError.tooLarge("surface")
        }
        try writeProtected(geometryData, to: revision.appendingPathComponent("geometry.plist"))
        try writeProtected(archive.worldMapData, to: revision.appendingPathComponent("worldmap.archive"))
        if let referenceImageData = archive.referenceImageData {
            try writeProtected(referenceImageData, to: revision.appendingPathComponent("reference.jpg"))
        }

        var metadata = archive.metadata
        metadata.name = metadata.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let manifest = Manifest(formatVersion: Self.formatVersion, revision: revisionID,
                                metadata: metadata, hasReferenceImage: archive.referenceImageData != nil)
        try writeManifest(manifest, in: directory)
        committed = true

        // Old/staged revisions are not referenced after the atomic manifest
        // commit. Cleanup failure does not turn a successfully saved map into an
        // apparent failure; a later save can reclaim the orphaned bytes.
        if let children = try? fileManager.contentsOfDirectory(at: directory,
                                                               includingPropertiesForKeys: [.isDirectoryKey]) {
            for child in children where child.lastPathComponent != revisionID.uuidString {
                guard UUID(uuidString: child.lastPathComponent) != nil,
                      (try? requireDirectory(child)) != nil else { continue }
                try? fileManager.removeItem(at: child)
            }
        }
    }

    func rename(id: UUID, name: String) throws {
        var manifest = try readManifest(id: id)
        manifest.metadata.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        manifest.metadata.updatedAt = Date()
        try manifest.metadata.validate()
        try writeManifest(manifest, in: mapURL(id))
    }

    func delete(id: UUID) throws {
        let directory = mapURL(id)
        guard fileManager.fileExists(atPath: directory.path) else { throw MapStorageError.notFound }
        try requireDirectory(rootURL)
        try requireDirectory(directory)
        try fileManager.removeItem(at: directory)
    }

    private func mapURL(_ id: UUID) -> URL {
        rootURL.appendingPathComponent(id.uuidString + ".lidarmap", isDirectory: true)
    }

    private func prepareRoot() throws {
        if !fileManager.fileExists(atPath: rootURL.path) {
            try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        }
        try requireDirectory(rootURL)
    }

    private func requireDirectory(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw MapStorageError.invalidArchive("unexpected storage location")
        }
    }

    private func readManifest(id: UUID) throws -> Manifest {
        let directory = mapURL(id)
        guard fileManager.fileExists(atPath: directory.path) else { throw MapStorageError.notFound }
        try requireDirectory(rootURL)
        try requireDirectory(directory)
        let data = try readBounded(directory.appendingPathComponent("manifest.json"),
                                   maximum: Self.manifestLimit)
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        guard manifest.formatVersion == Self.formatVersion else {
            throw MapStorageError.unsupportedVersion(manifest.formatVersion)
        }
        guard manifest.metadata.id == id else {
            throw MapStorageError.invalidArchive("place identifier does not match its folder")
        }
        try manifest.metadata.validate()
        return manifest
    }

    private func writeManifest(_ manifest: Manifest, in directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(manifest)
        guard data.count <= Self.manifestLimit else { throw MapStorageError.tooLarge("manifest") }
        try writeProtected(data, to: directory.appendingPathComponent("manifest.json"))
    }

    private func readBounded(_ url: URL, maximum: Int) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size >= 0 else {
            throw MapStorageError.invalidArchive("missing or invalid \(url.lastPathComponent)")
        }
        guard size <= maximum else { throw MapStorageError.tooLarge(url.lastPathComponent) }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard data.count <= maximum else { throw MapStorageError.tooLarge(url.lastPathComponent) }
        return data
    }

    private func writeProtected(_ data: Data, to url: URL) throws {
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: url, options: [.atomic])
        #endif
    }
}
