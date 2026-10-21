import Foundation
import Testing
@testable import test

@MainActor
@Suite("Saved places")
struct MappingTests {
    private func archive() -> MapArchive {
        let geometry = SavedMapGeometry(meshes: [MapMeshSnapshot(id: UUID(),
            vertices: [0, 0, 0, 1, 0, 0, 0, 1, 0], triangleIndices: [0, 1, 2])],
            trail: [MapPosition(x: 0, y: 1, z: 2)])
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        return MapArchive(metadata: SavedMapMetadata(id: UUID(), name: "Living room",
            createdAt: date, updatedAt: date, anchorCount: 1, vertexCount: 3, faceCount: 1),
            geometry: geometry, worldMapData: Data([1, 2, 3]), referenceImageData: nil)
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("MapTests-" + UUID().uuidString)
    }

    @Test func geometryRoundTripsExactBinaryCoordinates() throws {
        let original = archive().geometry
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let decoded = try PropertyListDecoder().decode(SavedMapGeometry.self, from: encoder.encode(original))
        #expect(decoded == original)
        try decoded.validate()
    }

    @Test func rejectsInvalidIndicesAndNonfiniteCoordinates() {
        var value = archive()
        value.geometry.meshes[0].triangleIndices = [0, 1, 3]
        #expect(throws: MapStorageError.self) { try value.validate() }
        value = archive()
        value.geometry.meshes[0].vertices[0] = .nan
        #expect(throws: MapStorageError.self) { try value.validate() }
        value = archive()
        value.geometry.trail[0].x = .infinity
        #expect(throws: MapStorageError.self) { try value.validate() }
    }

    @Test func rejectsDuplicateAnchorsIncompleteTrianglesAndOversizedTrail() {
        var value = archive()
        value.geometry.meshes.append(value.geometry.meshes[0])
        #expect(throws: MapStorageError.self) { try value.geometry.validate() }
        value = archive()
        value.geometry.meshes[0].triangleIndices.removeLast()
        #expect(throws: MapStorageError.self) { try value.geometry.validate() }
        value = archive()
        value.geometry.trail = Array(repeating: MapPosition(x: 0, y: 0, z: 0),
                                     count: MapLimits.maxTrailPoints + 1)
        #expect(throws: MapStorageError.self) { try value.geometry.validate() }
    }

    @Test func rejectsEmptyNamesCountMismatchAndMissingTrackingMap() {
        var value = archive()
        value.metadata.name = " \n "
        #expect(throws: MapStorageError.self) { try value.validate() }
        value = archive()
        value.metadata.vertexCount += 1
        #expect(throws: MapStorageError.self) { try value.validate() }
        value = archive()
        value.worldMapData = Data()
        #expect(throws: MapStorageError.self) { try value.validate() }
    }

    @Test func revisitingKeepsUnseenChunksAndReplacesUpdatedChunks() throws {
        let baseline = archive().geometry
        var replacement = baseline.meshes[0]
        replacement.vertices[0] = 0.25
        let newMesh = archive().geometry.meshes[0]
        let current = SavedMapGeometry(meshes: [replacement, newMesh], trail: [])
        let updated = try MappingCoordinator.merging(baseline: baseline, current: current)
        #expect(updated.meshes.count == 2)
        #expect(updated.meshes.first { $0.id == replacement.id } == replacement)

        let partlySeen = try MappingCoordinator.merging(baseline: updated,
            current: SavedMapGeometry(meshes: [newMesh], trail: []))
        #expect(partlySeen.meshes.count == 2)
        #expect(partlySeen.meshes.contains(replacement))
    }

    @Test func mergingBoundsTrailAndRejectsAggregateAnchorOverflow() throws {
        var baseline = archive().geometry
        baseline.trail = Array(repeating: MapPosition(x: 1, y: 0, z: 0), count: MapLimits.maxTrailPoints)
        let latest = MapPosition(x: 2, y: 0, z: 0)
        let merged = try MappingCoordinator.merging(baseline: baseline,
            current: SavedMapGeometry(meshes: [], trail: [latest]))
        #expect(merged.trail.count == MapLimits.maxTrailPoints)
        #expect(merged.trail.last == latest)
        baseline.meshes = (0..<MapLimits.maxMeshAnchors).map { _ in archive().geometry.meshes[0] }
        #expect(throws: MapStorageError.self) {
            try MappingCoordinator.merging(baseline: baseline, current: archive().geometry)
        }
    }

    @Test func mergingRejectsDuplicateIDsInsteadOfTrapping() {
        var invalid = archive().geometry
        invalid.meshes.append(invalid.meshes[0])
        #expect(throws: MapStorageError.self) {
            try MappingCoordinator.merging(baseline: invalid, current: archive().geometry)
        }
    }

    @Test func explicitRemovalDropsArchivedChunkButNotUnseenSurfacesOrReaddedChunks() throws {
        let removed = archive().geometry.meshes[0]
        let unseen = archive().geometry.meshes[0]
        let baseline = SavedMapGeometry(meshes: [removed, unseen], trail: [])
        let merged = try MappingCoordinator.merging(baseline: baseline,
            current: SavedMapGeometry(meshes: [], trail: []), excluding: [removed.id])
        #expect(merged.meshes == [unseen])

        var readded = removed
        readded.vertices[0] = 0.5
        let restored = try MappingCoordinator.merging(baseline: baseline,
            current: SavedMapGeometry(meshes: [readded], trail: []), excluding: [removed.id])
        #expect(restored.meshes.count == 2)
        #expect(restored.meshes.contains(readded))
        #expect(restored.meshes.contains(unseen))
    }

    @Test func saveReopenRenameAndDeletePreserveGeometry() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MapStore(rootURL: root)
        let original = archive()
        try await store.save(original)

        // A new store instance models a new app launch, with no in-memory cache.
        let reopened = MapStore(rootURL: root)
        let saved = try await reopened.load(id: original.metadata.id)
        #expect(saved.metadata == original.metadata)
        #expect(saved.geometry == original.geometry)
        #expect(saved.worldMapData == original.worldMapData)
        #expect(try await reopened.list().count == 1)

        try await reopened.rename(id: original.metadata.id, name: "  Kitchen  ")
        let renamed = try await reopened.load(id: original.metadata.id)
        #expect(renamed.metadata.name == "Kitchen")
        #expect(renamed.geometry == original.geometry)
        try await reopened.delete(id: original.metadata.id)
        #expect(try await reopened.list().isEmpty)
    }

    @Test func failedReplacementLeavesLastSavedRevisionReadable() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MapStore(rootURL: root)
        let original = archive()
        try await store.save(original)
        var invalid = original
        invalid.geometry.meshes[0].triangleIndices = [0, 1, 500]
        await #expect(throws: MapStorageError.self) { try await store.save(invalid) }
        let retained = try await store.load(id: original.metadata.id)
        #expect(retained.geometry == original.geometry)
        #expect(retained.metadata == original.metadata)
    }

    @Test func incompleteDirectoryIsIgnoredAndCorruptionFailsOnLoad() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MapStore(rootURL: root)
        let original = archive()
        try await store.save(original)
        let incomplete = root.appendingPathComponent(UUID().uuidString + ".lidarmap")
        try FileManager.default.createDirectory(at: incomplete, withIntermediateDirectories: false)
        #expect(try await store.list().map(\.id) == [original.metadata.id])

        let directory = root.appendingPathComponent(original.metadata.id.uuidString + ".lidarmap")
        let children = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let revision = try #require(children.first { UUID(uuidString: $0.lastPathComponent) != nil })
        try Data("corrupt geometry".utf8).write(to: revision.appendingPathComponent("geometry.plist"))
        await #expect(throws: (any Error).self) { try await store.load(id: original.metadata.id) }
    }

    @Test func corruptManifestRemainsVisibleAndDeletable() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MapStore(rootURL: root)
        let original = archive()
        try await store.save(original)
        let manifest = root.appendingPathComponent(original.metadata.id.uuidString + ".lidarmap")
            .appendingPathComponent("manifest.json")
        try Data("broken manifest".utf8).write(to: manifest)
        let list = try await store.list()
        #expect(list.count == 1)
        #expect(list.first?.id == original.metadata.id)
        #expect(list.first?.name == "Unreadable saved place")
        try await store.delete(id: original.metadata.id)
        #expect(try await store.list().isEmpty)
    }
}
