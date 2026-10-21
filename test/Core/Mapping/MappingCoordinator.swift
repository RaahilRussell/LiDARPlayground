//
// Persistent places: the AR session owns tracking, the store owns durable data,
// and this coordinator owns user intent and guards asynchronous transitions.
//

import Foundation
import Observation
import UIKit

@MainActor
@Observable
final class MappingCoordinator {
    private(set) var maps: [SavedMapMetadata] = []
    private(set) var isBusy = false
    private(set) var errorMessage: String?
    private(set) var statusMessage: String?
    private(set) var automaticState = "Preparing automatic mapping"
    private(set) var lastSavedAt: Date?
    private(set) var requiresPlaceChoice = false
    private(set) var isAutomaticSavePending = false
    var autoSaveEnabled = true
    let navigation: NavigationController
    let textRecognition: LocalTextRecognitionController
    private var storedActiveMap: SavedMapMetadata?
    private var storedGeometry: SavedMapGeometry?
    private var storedReferenceImageData: Data?

    private let manager: ARSessionManager
    private let store: MapStore
    private var operationID = UUID()
    private var activeGeneration: Int?
    private var requiresRelocalization = false
    private var savedTrailPrefix: [MapPosition] = []
    private let colorCapture = MappingColorCapture()
    @ObservationIgnored private var automaticTask: Task<Void, Never>?
    private var automaticStarted = false
    private var foregroundActive = true
    private var automaticRestoreAttempt = false
    private var automaticSaveBlocked = false
    private var lastAttemptAt: Date?
    private var observedGeneration: Int
    private var nextPlaceID: UUID?
    private var nextSegmentIndex = 0
    private var nextSegmentName: String?
    private var segmentClosing = false
    private var launchRestorePending = false
    private var deferredRestore: (id: UUID, automatic: Bool)?

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
        self.navigation = NavigationController(manager: manager)
        self.textRecognition = LocalTextRecognitionController(manager: manager)
        self.observedGeneration = manager.sessionGeneration
        colorCapture.reset(generation: manager.sessionGeneration)
        manager.mappingFrameTap = { [weak self] frame, generation in
            guard let self, self.foregroundActive, !self.manager.isUserPaused,
                  !self.segmentClosing else { return }
            self.synchronizeGeneration()
            self.colorCapture.observe(frame: frame, generation: generation)
        }
    }

    /// Called once by the application, independent of whichever screen is open.
    /// A saved place is tried before a new coordinate space can overwrite it.
    func startAutomaticMapping() async {
        guard !automaticStarted else { return }
        automaticStarted = true
        launchRestorePending = true
        guard manager.supportsWorldTracking, manager.supportsMesh else {
            launchRestorePending = false
            automaticState = "Automatic mapping requires a LiDAR iPhone or iPad."
            return
        }
        // A child library view may be refreshing at the same time as app setup.
        // Do not interpret a busy read as an empty library and lose auto-restore.
        while isBusy {
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
        }
        await refreshLibrary()
        await prepareInitialSessionIfActive()
        automaticTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self else { return }
                await self.automaticTick()
            }
        }
    }

    private func prepareInitialSessionIfActive() async {
        guard foregroundActive, launchRestorePending, !isBusy else { return }
        launchRestorePending = false
        if !manager.isUserPaused {
            if let latest = maps.max(by: { $0.updatedAt < $1.updatedAt }) {
                await restoreMap(id: latest.id, automatic: true)
                if activeMap == nil, manager.errorMessage == nil, !manager.isUserPaused,
                   !isBusy, foregroundActive, deferredRestore == nil {
                    // A corrupt/obsolete archive stays in the library; scanning
                    // can still begin under a fresh ID without replacing it.
                    let restoreError = errorMessage
                    startNewMap()
                    errorMessage = restoreError
                }
            } else {
                manager.start()
                startConsumersIfActive()
            }
        }
    }

    func setForegroundActive(_ active: Bool) async {
        foregroundActive = active
        if active {
            manager.handleBecameActive()
            if !automaticStarted { await startAutomaticMapping() }
            else { await prepareInitialSessionIfActive() }
            if let pending = deferredRestore, !isBusy, foregroundActive {
                deferredRestore = nil
                await restoreMap(id: pending.id, automatic: pending.automatic)
            }
            startConsumersIfActive()
        } else {
            // iOS does not permit continuous camera mapping in the background.
            // Periodic durable checkpoints protect the most recent valid scan.
            manager.handleResignActive()
            UIApplication.shared.isIdleTimerDisabled = false
            navigation.pause()
            textRecognition.pause()
            automaticState = "Mapping suspended while the app is in the background"
        }
    }

    func pauseAutomaticMapping() {
        manager.pause()
        UIApplication.shared.isIdleTimerDisabled = false
        navigation.pause()
        textRecognition.pause()
        automaticState = "Mapping paused"
    }

    func resumeAutomaticMapping() {
        automaticSaveBlocked = false
        lastAttemptAt = nil
        errorMessage = nil
        manager.start()
        startConsumersIfActive()
    }

    private func startConsumersIfActive() {
        UIApplication.shared.isIdleTimerDisabled = foregroundActive &&
            manager.runState == .running && !manager.isUserPaused
        guard foregroundActive, !manager.isUserPaused, !segmentClosing else { return }
        navigation.startRecording()
        textRecognition.start()
    }

    private func automaticTick() async {
        synchronizeGeneration()
        guard foregroundActive else { return }
        guard !manager.isUserPaused else {
            UIApplication.shared.isIdleTimerDisabled = false
            navigation.pause()
            textRecognition.pause()
            automaticState = "Mapping paused"
            return
        }
        if let failure = manager.errorMessage {
            UIApplication.shared.isIdleTimerDisabled = false
            automaticState = "Camera stopped: \(failure)"
            navigation.pause()
            textRecognition.pause()
            return
        }
        startConsumersIfActive()
        if manager.isRelocalizing {
            automaticState = manager.relocalizationGuidance
            if manager.relocalizationTimedOut, automaticRestoreAttempt, !isBusy {
                let previousName = activeMap?.name ?? "the previous place"
                startNewMap()
                statusMessage = "Could not recognize \(previousName). Its saved map is unchanged; a separate new place is now being scanned."
            } else {
                requiresPlaceChoice = manager.relocalizationTimedOut
            }
            return
        }
        automaticRestoreAttempt = false
        requiresPlaceChoice = false
        automaticState = automaticSaveBlocked ? "Automatic saving needs attention" :
            (manager.canSaveWorldMap ? "Mapping continuously · saves automatically" : manager.relocalizationGuidance)
        if let captureFailure = colorCapture.lastError {
            errorMessage = "A camera photo could not be captured: \(captureFailure) Surface mapping continues; the camera will retry."
        }
        let usage = manager.mappingUsage(including: restoredGeometry)
        let needsRollover = colorCapture.needsSegmentRollover || navigation.capacityReached ||
            textRecognition.needsSegmentRollover ||
            AutomaticMappingPolicy.needsSegment(
                vertices: usage.vertices, faces: usage.faces, anchors: usage.anchors)
        let now = Date()
        guard AutomaticMappingPolicy.shouldSave(now: now,
            lastSavedAt: needsRollover ? nil : lastSavedAt, lastAttemptAt: lastAttemptAt,
            ready: manager.canSaveWorldMap, foreground: foregroundActive,
            userPaused: manager.isUserPaused, busy: isBusy,
            enabled: autoSaveEnabled && !automaticSaveBlocked) else { return }
        lastAttemptAt = now
        isAutomaticSavePending = true
        if needsRollover {
            segmentClosing = true
            navigation.pause()
            textRecognition.pause()
        }
        defer {
            isAutomaticSavePending = false
            segmentClosing = false
            startConsumersIfActive()
        }
        let generation = manager.sessionGeneration
        let saved = await performSave(name: activeMap?.name ?? nextSegmentName ?? AutomaticMappingPolicy.automaticName(at: now), automatic: true, closeSegment: needsRollover)
        guard saved, generation == manager.sessionGeneration,
              foregroundActive, !manager.isUserPaused else { return }
        if needsRollover, let previous = activeMap {
            // Reset only after the whole segment (photos/graph/text included) is
            // durable. Segments have different origins and never share routes.
            startNewMap()
            nextPlaceID = previous.placeID ?? previous.id
            nextSegmentIndex = previous.segmentIndex + 1
            let suffix = " · Part \(nextSegmentIndex + 1)"
            nextSegmentName = String(previous.name.prefix(MapLimits.maxNameLength - suffix.count)) + suffix
            statusMessage = "Saved \(previous.name). Continuing in a new map segment with a separate route start."
        }
    }

    private func synchronizeGeneration() {
        guard observedGeneration != manager.sessionGeneration else { return }
        observedGeneration = manager.sessionGeneration
        // Includes resets from the developer console and recovery after errors.
        // Restore/startNewMap update this synchronously after binding consumers.
        colorCapture.reset(generation: observedGeneration)
        navigation.beginNewPlace()
        textRecognition.beginNewPlace()
        clearActivePlace()
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
        _ = await performSave(name: name, automatic: false)
    }

    private func performSave(name: String, automatic: Bool, closeSegment: Bool = false) async -> Bool {
        guard let operation = beginOperation() else { return false }
        defer { finishOperation(operation) }
        let generation = manager.sessionGeneration
        do {
            let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedName.isEmpty, normalizedName.count <= 80 else {
                throw MappingCoordinatorError.invalidName
            }
            let capture = try await manager.captureMappingSnapshot(suspendAfterCapture: closeSegment)
            await colorCapture.flush()
            guard isCurrent(operation), generation == manager.sessionGeneration else { return false }

            let continuesSavedMap = activeGeneration == generation &&
                (!requiresRelocalization || manager.hasLocalizedMap)
            let baseline = continuesSavedMap ? restoredGeometry.map {
                // The live trail already contains this run's previous samples.
                // Only prepend the path from before the current revisit.
                var copy = $0
                copy.trail = savedTrailPrefix
                return copy
            } : nil
            var geometry = try Self.merging(baseline: baseline, current: capture.geometry,
                                           excluding: manager.removedMeshAnchorIDs)
            geometry = colorCapture.applying(to: geometry)
            geometry.navigation = navigation.graphForSaving()
            geometry.textAnnotations = textRecognition.annotations
            geometry.directionalSignage = textRecognition.directionalSignage
            let previous = continuesSavedMap ? activeMap : nil
            let now = Date()
            let metadata = SavedMapMetadata(
                id: previous?.id ?? UUID(), name: normalizedName,
                createdAt: previous?.createdAt ?? now, updatedAt: now,
                anchorCount: geometry.meshes.count,
                vertexCount: geometry.meshes.reduce(0) { $0 + $1.vertices.count / 3 },
                faceCount: geometry.meshes.reduce(0) { $0 + $1.triangleIndices.count / 3 },
                placeID: previous?.placeID ?? nextPlaceID,
                segmentIndex: previous?.segmentIndex ?? nextSegmentIndex)
            let archive = MapArchive(metadata: metadata, geometry: geometry,
                                     worldMapData: capture.worldMapData,
                                     referenceImageData: capture.referenceImageData)
            try archive.validate()
            try await store.save(archive)
            guard isCurrent(operation), generation == manager.sessionGeneration else { return false }
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
            lastSavedAt = now
            automaticSaveBlocked = false
            let saved = try await store.list()
            guard isCurrent(operation), generation == manager.sessionGeneration else { return false }
            maps = saved
            statusMessage = automatic ? "Automatically saved \(metadata.name)." :
                "Saved \(metadata.name). You can explore it in 3D or return to this place and resume mapping."
            return true
        } catch {
            guard isCurrent(operation), generation == manager.sessionGeneration else { return false }
            if automatic, let sessionError = error as? MappingSessionError,
               sessionError == .notReady || sessionError == .changedSession || sessionError == .noSurface {
                // A moving camera can briefly lose quality; retry with backoff.
                automaticState = manager.relocalizationGuidance
            } else {
                report(error, operation: operation)
                if automatic {
                    automaticSaveBlocked = true
                    pauseAutomaticMapping()
                    errorMessage = "Automatic saving stopped: \(error.localizedDescription) Your previous saved maps are safe. Resume to retry before starting another place."
                }
            }
            return false
        }
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
        let generation = manager.sessionGeneration
        if activeMap?.id != id, manager.canSaveWorldMap {
            let saved = await performSave(name: activeMap?.name ?? nextSegmentName ??
                AutomaticMappingPolicy.automaticName(at: Date()), automatic: false)
            guard saved, generation == manager.sessionGeneration else { return }
        }
        await restoreMap(id: id, automatic: false)
    }

    private func restoreMap(id: UUID, automatic: Bool) async {
        guard let operation = beginOperation() else { return }
        defer { finishOperation(operation) }
        let generation = manager.sessionGeneration
        do {
            let archive = try await store.load(id: id)
            guard isCurrent(operation), generation == manager.sessionGeneration else { return }
            let worldMap = try await ARSessionManager.decodeWorldMap(archive.worldMapData)
            guard isCurrent(operation), generation == manager.sessionGeneration else { return }
            guard !automatic || !manager.isUserPaused else { return }
            guard foregroundActive else {
                deferredRestore = (id, automatic)
                statusMessage = "Revisit will continue when the app returns to the foreground."
                return
            }
            try manager.restoreWorldMap(worldMap)
            storedActiveMap = archive.metadata
            activeGeneration = manager.sessionGeneration
            requiresRelocalization = true
            savedTrailPrefix = archive.geometry.trail
            storedGeometry = archive.geometry
            storedReferenceImageData = archive.referenceImageData
            observedGeneration = manager.sessionGeneration
            colorCapture.restore(geometry: archive.geometry, generation: observedGeneration)
            navigation.restore(graph: archive.geometry.navigation)
            textRecognition.restore(annotations: archive.geometry.textAnnotations,
                                    signage: archive.geometry.directionalSignage)
            automaticRestoreAttempt = automatic
            automaticSaveBlocked = false
            requiresPlaceChoice = false
            lastSavedAt = nil
            lastAttemptAt = nil
            nextPlaceID = nil
            nextSegmentIndex = 0
            nextSegmentName = nil
            startConsumersIfActive()
            statusMessage = "Loaded \(archive.metadata.name). Match the saved view to align its surfaces, then continue scanning."
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
        clearActivePlace()
        manager.startNewMap()
        observedGeneration = manager.sessionGeneration
        colorCapture.reset(generation: observedGeneration)
        navigation.beginNewPlace()
        textRecognition.beginNewPlace()
        startConsumersIfActive()
        statusMessage = "New place started. Mapping and saving continue automatically while the app is open."
    }

    private func clearActivePlace() {
        storedActiveMap = nil
        activeGeneration = nil
        requiresRelocalization = false
        savedTrailPrefix = []
        storedGeometry = nil
        storedReferenceImageData = nil
        nextPlaceID = nil
        nextSegmentIndex = 0
        nextSegmentName = nil
        deferredRestore = nil
        launchRestorePending = false
        automaticRestoreAttempt = false
        automaticSaveBlocked = false
        requiresPlaceChoice = false
        lastSavedAt = nil
        lastAttemptAt = nil
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

    nonisolated static func merging(baseline: SavedMapGeometry?, current: SavedMapGeometry,
                                    excluding removedIDs: Set<UUID> = []) throws -> SavedMapGeometry {
        try baseline?.validate()
        try current.validate()
        // Restored chunks remain available when ARKit is currently looking at
        // only one portion of the place. Updated IDs replace their saved chunk.
        let retained = (baseline?.meshes ?? []).filter { !removedIDs.contains($0.id) }
        var byID = Dictionary(uniqueKeysWithValues: retained.map { ($0.id, $0) })
        // A newly delivered live chunk with the same ID supersedes a tombstone.
        for mesh in current.meshes { byID[mesh.id] = mesh }
        var trail = baseline?.trail ?? []
        trail.append(contentsOf: current.trail)
        var result = SavedMapGeometry(
            meshes: byID.values.sorted { $0.id.uuidString < $1.id.uuidString },
            trail: Array(trail.suffix(MapLimits.maxTrailPoints)))
        result.keyframes = mergeByID(baseline?.keyframes ?? [], current.keyframes)
        result.navigation = current.navigation ?? baseline?.navigation
        result.textAnnotations = mergeByID(baseline?.textAnnotations ?? [], current.textAnnotations)
        result.directionalSignage = mergeByID(baseline?.directionalSignage ?? [], current.directionalSignage)
        try result.validate()
        return result
    }

    private nonisolated static func mergeByID<Value: Identifiable>(_ baseline: [Value], _ current: [Value]) -> [Value] {
        var result = baseline
        for value in current {
            if let index = result.firstIndex(where: { $0.id == value.id }) { result[index] = value }
            else { result.append(value) }
        }
        return result
    }
}

nonisolated enum MappingCoordinatorError: LocalizedError {
    case invalidName
    var errorDescription: String? { "Choose a place name between 1 and 80 characters." }
}
