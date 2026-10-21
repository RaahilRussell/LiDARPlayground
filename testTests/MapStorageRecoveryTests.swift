import Foundation
import Testing
@testable import test

@MainActor
@Suite("Map storage recovery")
struct MapStorageRecoveryTests {
    private func archive() -> MapArchive {
        let geometry = SavedMapGeometry(meshes: [MapMeshSnapshot(id: UUID(),
            vertices: [0, 0, 0, 1, 0, 0, 0, 1, 0], triangleIndices: [0, 1, 2])], trail: [])
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        return MapArchive(metadata: SavedMapMetadata(id: UUID(), name: "Study",
            createdAt: date, updatedAt: date, anchorCount: 1, vertexCount: 3, faceCount: 1),
            geometry: geometry, worldMapData: Data([1, 2, 3]), referenceImageData: nil)
    }

    @Test func newerFormatIsVisibleAndDeletableWithoutDecodingGeometry() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MapVersionTests-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MapStore(rootURL: root)
        let original = archive()
        try await store.save(original)

        let manifestURL = root.appendingPathComponent(original.metadata.id.uuidString + ".lidarmap")
            .appendingPathComponent("manifest.json")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL))
        var manifest = try #require(object as? [String: Any])
        manifest["formatVersion"] = 999
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL, options: .atomic)

        await #expect(throws: MapStorageError.self) { try await store.load(id: original.metadata.id) }
        let visible = try await store.list()
        #expect(visible.map(\.id) == [original.metadata.id])
        #expect(visible.first?.name == "Unreadable saved place")
        try await store.delete(id: original.metadata.id)
        #expect(try await store.list().isEmpty)
    }

    @Test func symbolicLinkRootCannotDeleteRealSavedMap() async throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("MapLinkTests-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let realRoot = parent.appendingPathComponent("real", isDirectory: true)
        let alias = parent.appendingPathComponent("alias", isDirectory: true)
        let store = MapStore(rootURL: realRoot)
        let original = archive()
        try await store.save(original)
        try FileManager.default.createSymbolicLink(atPath: alias.path, withDestinationPath: realRoot.path)

        let linkedStore = MapStore(rootURL: alias)
        await #expect(throws: MapStorageError.self) { try await linkedStore.delete(id: original.metadata.id) }
        await #expect(throws: MapStorageError.self) { try await linkedStore.list() }
        let retained = try await store.load(id: original.metadata.id)
        #expect(retained.geometry == original.geometry)
        #expect(retained.metadata == original.metadata)
    }
}
