//
// Persistent places: the AR session owns tracking, the store owns durable data,
// and this coordinator owns user intent and guards asynchronous transitions.
//

import Foundation
import Observation

@MainActor
@Observable
final class MappingCoordinator {
    private(set) var maps: [SavedMapMetadata] = []
    private(set) var isBusy = false
    private(set) var errorMessage: String?
    private(set) var statusMessage: String?
    private var storedActiveMap: SavedMapMetadata?
    private var storedGeometry: SavedMapGeometry?
    private var storedReferenceImageData: Data?

    private let manager: ARSessionManager
    private let store: MapStore
    private var operationID = UUID()
    private var activeGeneration: Int?
    private var requiresRelocalization = false
    private var savedTrailPrefix: [MapPosition] = []

    var activeMap: SavedMapMetadata? {
        activeGeneration == manager.sessionGeneration ? storedActiveMap : nil
    }

    var restoredGeometry: SavedMapGeometry? {
        activeGeneration == manager.sessionGeneration ? storedGeometry : nil
    }

    var referenceImageData: Data? {
        activeGeneration == manager.sessionGeneration ? storedReferenceImageData : nil
    }

    init(manager: ARSessionManager, store: MapStore = MapStore()) {
        self.manager = manager
        self.store = store
    }

    /// A baseline is valid only in the coordinate space restored from its map.
    /// Ordinary sensor-console resets also invalidate it, without UI coupling.
    var canDisplayRestoredGeometry: Bool {
        activeGeneration == manager.sessionGeneration && manager.hasLocalizedMap &&
        manager.trackingIsNormal && !manager.isRelocalizing
    }

    func refreshLibrary() async {
        guard let operation = beginOperation() else { return }
        defer { finishOperation(operation) }
        do {
            let saved = try await store.list()
            guard isCurrent(operation) else { return }
            maps = saved
        } catch { report(error, operation: operation) }
    }

    func saveMap(name: String) async {
        guard let operation = beginOperation() else { return }
        defer { finishOperation(operation) }
        let generation = manager.sessionGeneration
        do {
            let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedName.isEmpty, normalizedName.count <= 80 else {
                throw MappingCoordinatorError.invalidName
            }
            let capture = try await manager.captureMappingSnapshot()
            guard isCurrent(operation), generation == manager.sessionGeneration else { return }

            let continuesSavedMap = activeGeneration == generation &&
                (!requiresRelocalization || manager.hasLocalizedMap)
            let baseline = continuesSavedMap ? restoredGeometry.map {
                // The live trail already contains this run's previous samples.
                // Only prepend the path from before the current revisit.
                SavedMapGeometry(meshes: $0.meshes, trail: savedTrailPrefix)
            } : nil
            let geometry = try Self.merging(baseline: baseline, current: capture.geometry)
            let previous = continuesSavedMap ? activeMap : nil
            let now = Date()
            let metadata = SavedMapMetadata(
                id: previous?.id ?? UUID(), name: normalizedName,
                createdAt: previous?.createdAt ?? now, updatedAt: now,
                anchorCount: geometry.meshes.count,
                vertexCount: geometry.meshes.reduce(0) { $0 + $1.vertices.count / 3 },
                faceCount: geometry.meshes.reduce(0) { $0 + $1.triangleIndices.count / 3 })
            let archive = MapArchive(metadata: metadata, geometry: geometry,
                                     worldMapData: capture.worldMapData,
                                     referenceImageData: capture.referenceImageData)
            try archive.validate()
            try await store.save(archive)
            guard isCurrent(operation), generation == manager.sessionGeneration else { return }
            if !continuesSavedMap {
                requiresRelocalization = false
                savedTrailPrefix = []
            }
            // Saving the active scan does not mean a saved map was relocalized.
            // Record the baseline independently so repeat saves preserve all chunks.
            storedActiveMap = metadata
            activeGeneration = generation
            storedGeometry = geometry
            storedReferenceImageData = capture.referenceImageData
            let saved = try await store.list()
            guard isCurrent(operation), generation == manager.sessionGeneration else { return }
            maps = saved
            statusMessage = "Saved \(metadata.name). You can explore it in 3D or return to this place and resume mapping."
        } catch { report(error, operation: operation) }
    }

    /// Offline viewing never changes, runs, or pauses the shared camera session.
    func loadMap(id: UUID) async -> MapArchive? {
        guard let operation = beginOperation() else { return nil }
        defer { finishOperation(operation) }
        do {
            let archive = try await store.load(id: id)
            guard isCurrent(operation) else { return nil }
            return archive
        } catch {
            report(error, operation: operation)
            return nil
        }
    }

    func resumeMap(id: UUID) async {
        guard let operation = beginOperation() else { return }
        defer { finishOperation(operation) }
        let generation = manager.sessionGeneration
        do {
            let archive = try await store.load(id: id)
            guard isCurrent(operation), generation == manager.sessionGeneration else { return }
            let worldMap = try await ARSessionManager.decodeWorldMap(archive.worldMapData)
            guard isCurrent(operation), generation == manager.sessionGeneration else { return }
            try manager.restoreWorldMap(worldMap)
            storedActiveMap = archive.metadata
            activeGeneration = manager.sessionGeneration
            requiresRelocalization = true
            savedTrailPrefix = archive.geometry.trail
            storedGeometry = archive.geometry
            storedReferenceImageData = archive.referenceImageData
            statusMessage = "Recognizing \(archive.metadata.name). Return to the saved view before extending this map."
        } catch { report(error, operation: operation) }
    }

    func deleteMap(id: UUID) async {
        guard let operation = beginOperation() else { return }
        defer { finishOperation(operation) }
        do {
            try await store.delete(id: id)
            guard isCurrent(operation) else { return }
            if activeMap?.id == id {
                // A continued scan can still be saved, but must receive a new ID.
                storedActiveMap = nil
            }
            let saved = try await store.list()
            guard isCurrent(operation) else { return }
            maps = saved
            statusMessage = "Deleted the saved place."
        } catch { report(error, operation: operation) }
    }

    func renameMap(id: UUID, name: String) async {
        guard let operation = beginOperation() else { return }
        defer { finishOperation(operation) }
        do {
            try await store.rename(id: id, name: name)
            guard isCurrent(operation) else { return }
            let saved = try await store.list()
            guard isCurrent(operation) else { return }
            maps = saved
            if activeMap?.id == id { storedActiveMap = maps.first { $0.id == id } }
            statusMessage = "Renamed the saved place."
        } catch { report(error, operation: operation) }
    }

    func startNewMap() {
        invalidateOperation()
        storedActiveMap = nil
        activeGeneration = nil
        requiresRelocalization = false
        savedTrailPrefix = []
        storedGeometry = nil
        storedReferenceImageData = nil
        manager.startNewMap()
        statusMessage = "New map started. Scan nearby surfaces slowly from several angles."
    }

    func cancelRelocalization() { startNewMap() }

    func clearError() { errorMessage = nil }

    private func beginOperation() -> UUID? {
        guard !isBusy else { return nil }
        let token = UUID()
        operationID = token
        isBusy = true
        errorMessage = nil
        statusMessage = nil
        return token
    }

    private func isCurrent(_ operation: UUID) -> Bool { operationID == operation }

    private func finishOperation(_ operation: UUID) {
        if isCurrent(operation) { isBusy = false }
    }

    private func invalidateOperation() {
        operationID = UUID()
        isBusy = false
        errorMessage = nil
        statusMessage = nil
    }

    private func report(_ error: Error, operation: UUID) {
        if isCurrent(operation) { errorMessage = error.localizedDescription }
    }

    nonisolated static func merging(baseline: SavedMapGeometry?, current: SavedMapGeometry) throws -> SavedMapGeometry {
        try baseline?.validate()
        try current.validate()
        // Restored chunks remain available when ARKit is currently looking at
        // only one portion of the place. Updated IDs replace their saved chunk.
        var byID = Dictionary(uniqueKeysWithValues: (baseline?.meshes ?? []).map { ($0.id, $0) })
        for mesh in current.meshes { byID[mesh.id] = mesh }
        var trail = baseline?.trail ?? []
        trail.append(contentsOf: current.trail)
        let result = SavedMapGeometry(
            meshes: byID.values.sorted { $0.id.uuidString < $1.id.uuidString },
            trail: Array(trail.suffix(MapLimits.maxTrailPoints)))
        try result.validate()
        return result
    }
}

nonisolated enum MappingCoordinatorError: LocalizedError {
    case invalidName
    var errorDescription: String? { "Choose a place name between 1 and 80 characters." }
}
