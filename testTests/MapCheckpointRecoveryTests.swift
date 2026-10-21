import Foundation
import Testing
@testable import test

@MainActor
@Suite("Map saving during sensor loss")
struct MapCheckpointRecoveryTests {
    private let capturedAt = Date(timeIntervalSince1970: 1_800_000_000)

    private func archive() -> MapArchive {
        let geometry = SavedMapGeometry(meshes: [MapMeshSnapshot(id: UUID(),
            vertices: [0, 0, 0, 1, 0, 0, 0, 1, 0], triangleIndices: [0, 1, 2],
            vertexColors: [1, 0, 0, 1, 0, 1, 0, 1, 0, 0, 1, 1])],
            trail: [MapPosition(x: 0, y: 1, z: 2)])
        return MapArchive(metadata: SavedMapMetadata(id: UUID(), name: "Hallway",
            createdAt: capturedAt, updatedAt: capturedAt, anchorCount: 1, vertexCount: 3, faceCount: 1),
            geometry: geometry, worldMapData: Data([1, 2, 3]), referenceImageData: nil)
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("CheckpointRecovery-" + UUID().uuidString)
    }

    @Test func completeCheckpointSavesWhileCameraIsPausedWithoutRestartingSensors() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MapStore(rootURL: root)
        let manager = ARSessionManager()
        let mapping = MappingCoordinator(manager: manager, store: store)
        let original = archive()
        try mapping.retainCheckpoint(original, generation: manager.sessionGeneration, capturedAt: capturedAt)
        manager.pause()
        #expect(!manager.canSaveWorldMap)
        #expect(mapping.canSaveMap)
        #expect(mapping.isSavingRetainedCheckpoint)
        await mapping.saveMap(name: "Bathroom route")
        let saved = try await store.load(id: original.metadata.id)
        #expect(saved.metadata.name == "Bathroom route")
        #expect(saved.metadata.updatedAt == capturedAt)
        #expect(saved.geometry == original.geometry)
        #expect(saved.worldMapData == original.worldMapData)
        #expect(mapping.retainedCheckpointAt == capturedAt)
        #expect(mapping.statusMessage?.contains("last valid checkpoint") == true)
        #expect(manager.isUserPaused && manager.runState == .paused)
    }

    @Test func failedWriteKeepsCheckpointAvailableForRetryWithoutCameraFrames() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // A file where the store needs a directory forces a real disk-write error.
        try Data([0]).write(to: root)
        let store = MapStore(rootURL: root)
        let manager = ARSessionManager()
        let mapping = MappingCoordinator(manager: manager, store: store)
        let original = archive()
        try mapping.retainCheckpoint(original, generation: manager.sessionGeneration, capturedAt: capturedAt)
        await mapping.saveMap(name: "Recovered hall")
        #expect(mapping.errorMessage != nil)
        #expect(mapping.canSaveMap)
        #expect(mapping.retainedCheckpointAt == capturedAt)
        try FileManager.default.removeItem(at: root)
        await mapping.saveMap(name: "Recovered hall")
        let saved = try await store.load(id: original.metadata.id)
        #expect(saved.geometry == original.geometry)
        #expect(mapping.errorMessage == nil)
    }

    @Test func anotherWorldCannotSupplyFallbackAndNewPlaceClearsCheckpoint() throws {
        let manager = ARSessionManager()
        let mapping = MappingCoordinator(manager: manager)
        let original = archive()
        try mapping.retainCheckpoint(original, generation: manager.sessionGeneration + 1, capturedAt: capturedAt)
        #expect(!mapping.canSaveMap)
        try mapping.retainCheckpoint(original, generation: manager.sessionGeneration, capturedAt: capturedAt)
        #expect(mapping.canSaveMap)
        mapping.startNewMap()
        #expect(mapping.retainedCheckpointAt == nil)
        #expect(!mapping.isSavingRetainedCheckpoint)
    }

    @Test func invalidReplacementDoesNotDestroyLastCompleteCheckpoint() throws {
        let manager = ARSessionManager()
        let mapping = MappingCoordinator(manager: manager)
        let original = archive()
        try mapping.retainCheckpoint(original, generation: manager.sessionGeneration, capturedAt: capturedAt)
        var invalid = archive()
        invalid.worldMapData = Data()
        #expect(throws: MapStorageError.self) {
            try mapping.retainCheckpoint(invalid, generation: manager.sessionGeneration,
                                         capturedAt: capturedAt.addingTimeInterval(20))
        }
        #expect(mapping.retainedCheckpointAt == capturedAt)
        #expect(mapping.canSaveMap)
    }
}
