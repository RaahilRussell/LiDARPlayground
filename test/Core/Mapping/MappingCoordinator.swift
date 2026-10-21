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
    private var deferredRestore: (id: UUID, automatic: Bool, pauseRevision: Int)?
    private var pendingSegmentCapture: MappingSessionCapture?
    private var pendingSegmentGeneration: Int?
    private var pendingSegmentNeedsRefresh = false
    private var retainedArchive: MapArchive?
    private var retainedGeneration: Int?
    private var checkpointCapturedAt: Date?

    /// A complete immutable checkpoint can be written without requesting another
    /// camera frame. It is never combined with observations from another world.
    private var availableCheckpoint: MapArchive? {
        retainedGeneration == manager.sessionGeneration ? retainedArchive : nil
    }
    var retainedCheckpointAt: Date? { availableCheckpoint == nil ? nil : checkpointCapturedAt }
    var isSavingRetainedCheckpoint: Bool {
        availableCheckpoint != nil && (!manager.canSaveWorldMap || pendingSegmentCapture != nil)
    }
    var canSaveMap: Bool {
        availableCheckpoint != nil || (manager.canSaveWorldMap && pendingSegmentCapture == nil)
    }

    /// Saving and live sensing have independent failure recovery. A storage
    /// error must not turn off the shared camera used by CV and LiDAR diagnostics.
    var automaticSaveNeedsAttention: Bool { automaticSaveBlocked }

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
                  !self.segmentClosing, self.pendingSegmentCapture == nil else { return }
            self.synchronizeGeneration()
            self.colorCapture.observe(frame: frame, generation: generation,
                                      eligibleAnchorIDs: self.manager.currentSegmentMeshIDs)
        }
    }

    /// Called once by the application, independent of whichever screen is open.
    /// A saved place is tried before a new coordinate space can overwrite it.
    func startAutomaticMapping() async {
        guard !automaticStarted else { return }
        automaticStarted = true
        launchRestorePending = true
        guard manager.supportsWorldTracking else {
            launchRestorePending = false
            manager.start()
            automaticState = "Live sensing requires an ARKit iPhone or iPad."
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
            if manager.supportsMesh, let latest = maps.max(by: { $0.updatedAt < $1.updatedAt }) {
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
                if pending.pauseRevision == manager.pauseRevision {
                    await restoreMap(id: pending.id, automatic: pending.automatic)
                }
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

    func retryAutomaticSave() {
        automaticSaveBlocked = false
        lastAttemptAt = nil
        lastSavedAt = nil
        errorMessage = nil
        automaticState = "Retrying the map checkpoint when tracking is ready"
        // This action does not override an explicit camera pause.
        startConsumersIfActive()
    }

    private func startConsumersIfActive() {
        UIApplication.shared.isIdleTimerDisabled = foregroundActive &&
            manager.runState == .running && !manager.isUserPaused
        guard foregroundActive, manager.runState == .running, !manager.isUserPaused else { return }
        navigation.startRecording()
        if !segmentClosing && pendingSegmentCapture == nil { textRecognition.start() }
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
        if manager.isRecoveringSensors || manager.canRetrySensorRecovery {
            // A capture failure is not evidence that the user moved to another
            // place. Keep its origin/checkpoint through recovery and never let
            // the launch auto-restore timeout silently start a replacement map.
            automaticRestoreAttempt = false
            automaticState = manager.sensorStatusMessage ?? "Recovering sensor data; your checkpoint is retained"
            navigation.pause()
            textRecognition.pause()
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
        guard manager.supportsMesh else {
            automaticState = "Camera and computer vision are available. Saving 3D surfaces requires LiDAR."
            return
        }
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
        if navigation.capacityReached {
            automaticState = "Mapping continues. Path recording is full; existing destinations and routes remain available."
        }
        if let captureFailure = colorCapture.lastError {
            errorMessage = "A camera photo could not be captured: \(captureFailure) Surface mapping continues; the camera will retry."
        }
        let usage = manager.mappingUsage(including: restoredGeometry)
        let needsRollover = pendingSegmentCapture != nil || colorCapture.needsSegmentRollover ||
            textRecognition.needsSegmentRollover ||
            AutomaticMappingPolicy.needsSegment(
                vertices: usage.vertices, faces: usage.faces, anchors: usage.anchors)
        if needsRollover, pendingSegmentCapture == nil, !manager.canSaveWorldMap {
            automaticState = "A storage segment is ready to close. Hold the phone steady and scan nearby surfaces so it can save; captured data stays in memory."
        }
        let now = Date()
        guard AutomaticMappingPolicy.shouldSave(now: now,
            lastSavedAt: needsRollover ? nil : lastSavedAt, lastAttemptAt: lastAttemptAt,
            ready: pendingSegmentCapture != nil || manager.canSaveWorldMap, foreground: foregroundActive,
            userPaused: manager.isUserPaused, busy: isBusy,
            enabled: autoSaveEnabled && !automaticSaveBlocked) else { return }
        lastAttemptAt = now
        isAutomaticSavePending = true
        if needsRollover {
            segmentClosing = true
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
            // The graph continues recording while the segment writes; its newest
            // nodes go into the next checkpoint, never a fabricated new origin.
            guard manager.beginMappingSegment() else { return }
            beginNextSegment(after: previous)
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
        guard pendingSegmentCapture == nil || availableCheckpoint != nil else {
            errorMessage = "A storage segment is waiting for its final checkpoint. Tap Retry Saving to retry it and continue."
            return
        }
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
            if !automatic, !closeSegment, isSavingRetainedCheckpoint {
                return try await saveRetainedCheckpoint(name: normalizedName,
                    operation: operation, generation: generation)
            }
            let capture: MappingSessionCapture
            if closeSegment, pendingSegmentGeneration == generation,
               !pendingSegmentNeedsRefresh, let pendingSegmentCapture {
                capture = pendingSegmentCapture
            } else {
                let latest: MappingSessionCapture
                do {
                    latest = try await manager.captureMappingSnapshot(holdReconstructionAfterCapture: closeSegment)
                } catch {
                    // Tracking can stop after Save was tapped. Preserve the
                    // user's request using the last complete snapshot instead.
                    if !automatic, !closeSegment, availableCheckpoint != nil,
                       isCurrent(operation), generation == manager.sessionGeneration {
                        return try await saveRetainedCheckpoint(name: normalizedName,
                            operation: operation, generation: generation)
                    }
                    throw error
                }
                if closeSegment, pendingSegmentGeneration == generation, let pendingSegmentCapture {
                    var geometry = try Self.merging(baseline: pendingSegmentCapture.geometry,
                        current: latest.geometry, excluding: manager.removedMeshAnchorIDs)
                    // Both snapshots belong to this same live run; its current
                    // trail already contains the earlier observations.
                    geometry.trail = latest.geometry.trail
                    capture = MappingSessionCapture(geometry: geometry,
                        worldMapData: latest.worldMapData,
                        referenceImageData: latest.referenceImageData)
                } else {
                    capture = latest
                }
                if closeSegment {
                    pendingSegmentCapture = capture
                    pendingSegmentGeneration = generation
                    // A valid checkpoint may finish encoding after sensors
                    // paused, without freezing reconstruction. Refresh it once
                    // healthy before rotating away any subsequently seen mesh.
                    pendingSegmentNeedsRefresh = !manager.hasHeldMappingCapture
                }
            }
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
            // Retain before disk I/O: a storage error must not throw away the
            // only complete world-map/geometry pair available during a dropout.
            try retainCheckpoint(archive, generation: generation, capturedAt: now)
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
            if closeSegment {
                pendingSegmentNeedsRefresh = pendingSegmentCapture != nil
                manager.resumeReconstructionAfterCheckpointFailure()
            }
            if automatic, let sessionError = error as? MappingSessionError,
               sessionError == .notReady || sessionError == .changedSession || sessionError == .noSurface {
                // A moving camera can briefly lose quality; retry with backoff.
                automaticState = manager.relocalizationGuidance
            } else {
                report(error, operation: operation)
                if automatic { handleAutomaticSaveFailure(error) }
            }
            return false
        }
    }

    func retainCheckpoint(_ archive: MapArchive, generation: Int, capturedAt: Date) throws {
        guard generation == manager.sessionGeneration else { return }
        try archive.validate()
        guard capturedAt.timeIntervalSince1970.isFinite else { throw MappingSessionError.invalidArchive }
        retainedArchive = archive
        retainedGeneration = generation
        checkpointCapturedAt = capturedAt
    }

    private func saveRetainedCheckpoint(name: String, operation: UUID, generation: Int) async throws -> Bool {
        guard var archive = availableCheckpoint, let capturedAt = checkpointCapturedAt else {
            throw MappingSessionError.notReady
        }
        archive.metadata.name = name
        // Preserve the observation timestamp. A later save must not make old
        // geometry appear to contain observations from the sensor outage.
        try await store.save(archive)
        guard isCurrent(operation), generation == manager.sessionGeneration else { return false }
        retainedArchive = archive
        storedActiveMap = archive.metadata
        activeGeneration = generation
        storedGeometry = archive.geometry
        storedReferenceImageData = archive.referenceImageData
        lastSavedAt = Date()
        if pendingSegmentCapture == nil { automaticSaveBlocked = false }
        let saved = try await store.list()
        guard isCurrent(operation), generation == manager.sessionGeneration else { return false }
        maps = saved
        statusMessage = "Saved \(name) using the last valid checkpoint, last updated \(capturedAt.formatted(date: .omitted, time: .standard)). Scanning after that checkpoint is not included. Live mapping resumes when tracking recovers."
        return true
    }

    func handleAutomaticSaveFailure(_ error: Error) {
        automaticSaveBlocked = true
        errorMessage = "Automatic saving needs attention: \(error.localizedDescription) Live camera, depth, and computer vision can continue. Your previous saved maps are safe. Tap Retry Saving to retry the checkpoint."
        if pendingSegmentCapture != nil {
            errorMessage = "Automatic saving needs attention: \(error.localizedDescription) The previous snapshot is retained while live mesh, depth, and computer vision continue. Photo and text capture wait for this checkpoint. Tap Retry Saving to save the updated surfaces."
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
        let pauseRevision = manager.pauseRevision
        let closesPending = pendingSegmentCapture != nil && pendingSegmentGeneration == generation
        if activeMap?.id != id, manager.canSaveWorldMap || closesPending {
            let saved = await performSave(name: activeMap?.name ?? nextSegmentName ??
                AutomaticMappingPolicy.automaticName(at: Date()), automatic: false,
                closeSegment: closesPending)
            guard saved, generation == manager.sessionGeneration else { return }
        }
        guard manager.pauseRevision == pauseRevision else {
            statusMessage = "Revisit canceled because the camera was paused."
            return
        }
        await restoreMap(id: id, automatic: false)
    }

    private func restoreMap(id: UUID, automatic: Bool) async {
        guard let operation = beginOperation() else { return }
        defer { finishOperation(operation) }
        let generation = manager.sessionGeneration
        let pauseRevision = manager.pauseRevision
        do {
            let archive = try await store.load(id: id)
            guard isCurrent(operation), generation == manager.sessionGeneration else { return }
            let worldMap = try await ARSessionManager.decodeWorldMap(archive.worldMapData)
            guard isCurrent(operation), generation == manager.sessionGeneration else { return }
            guard manager.pauseRevision == pauseRevision else {
                statusMessage = "Revisit canceled because the camera was paused while the place was loading."
                return
            }
            guard !automatic || !manager.isUserPaused else { return }
            guard foregroundActive else {
                deferredRestore = (id, automatic, pauseRevision)
                statusMessage = "Revisit will continue when the app returns to the foreground."
                return
            }
            try manager.restoreWorldMap(worldMap)
            pendingSegmentCapture = nil
            pendingSegmentGeneration = nil
            pendingSegmentNeedsRefresh = false
            segmentClosing = false
            storedActiveMap = archive.metadata
            activeGeneration = manager.sessionGeneration
            requiresRelocalization = true
            savedTrailPrefix = archive.geometry.trail
            storedGeometry = archive.geometry
            storedReferenceImageData = archive.referenceImageData
            observedGeneration = manager.sessionGeneration
            try retainCheckpoint(archive, generation: observedGeneration, capturedAt: archive.metadata.updatedAt)
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
            let deletedActive = activeMap?.id == id
            if deletedActive {
                // A continued scan can still be saved, but must receive a new ID.
                storedActiveMap = nil
                retainedArchive = nil
                retainedGeneration = nil
                checkpointCapturedAt = nil
                pauseAutomaticMapping()
                lastSavedAt = nil
            }
            let saved = try await store.list()
            guard isCurrent(operation) else { return }
            maps = saved
            statusMessage = deletedActive ?
                "Deleted the saved place. Mapping is paused so it is not recreated automatically. Resume Mapping to save the current scan as a new place." :
                "Deleted the saved place."
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

    private func beginNextSegment(after previous: SavedMapMetadata) {
        retainedArchive = nil
        retainedGeneration = nil
        checkpointCapturedAt = nil
        storedActiveMap = nil
        storedGeometry = nil
        storedReferenceImageData = nil
        savedTrailPrefix = []
        requiresRelocalization = false
        activeGeneration = manager.sessionGeneration
        pendingSegmentCapture = nil
        pendingSegmentGeneration = nil
        pendingSegmentNeedsRefresh = false
        nextPlaceID = previous.placeID ?? previous.id
        nextSegmentIndex = previous.segmentIndex + 1
        let oldSuffix = " · Part \(previous.segmentIndex + 1)"
        let baseName = previous.segmentIndex > 0 && previous.name.hasSuffix(oldSuffix) ?
            String(previous.name.dropLast(oldSuffix.count)) : previous.name
        let suffix = " · Part \(nextSegmentIndex + 1)"
        nextSegmentName = String(baseName.prefix(MapLimits.maxNameLength - suffix.count)) + suffix
        lastSavedAt = nil; lastAttemptAt = nil
        colorCapture.reset(generation: manager.sessionGeneration)
        textRecognition.beginNewPlace()
        statusMessage = "Saved \(previous.name). Mapping continues in a new storage segment; your recorded paths and destinations stay active."
    }

    private func clearActivePlace() {
        retainedArchive = nil
        retainedGeneration = nil
        checkpointCapturedAt = nil
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
        pendingSegmentCapture = nil
        pendingSegmentGeneration = nil
        pendingSegmentNeedsRefresh = false
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
