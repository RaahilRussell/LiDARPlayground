//
//  ARSessionManager.swift
//  test
//
//  The single owner of the app's one ARSession. Every view observes this
//  object; no other object is allowed to create or run an ARSession.
//

import ARKit
import CoreImage
import ImageIO
import Observation
import QuartzCore
import UIKit
import simd

/// High-level description of what the session is doing right now.
enum SessionRunState: String {
    case idle = "Idle"
    case running = "Running"
    case paused = "Paused"
    case interrupted = "Interrupted"
    case unsupported = "Unsupported"
}

/// The depth source currently requested for visualization.
enum DepthSource: String, CaseIterable, Identifiable {
    case raw = "Raw"
    case smoothed = "Smoothed"
    var id: String { rawValue }
}

@MainActor
@Observable
final class ARSessionManager: NSObject, ARSessionDelegate {

    // MARK: - The one and only session

    /// Shared by every view. Created once, never duplicated.
    let session = ARSession()

    // MARK: - Published-style observable state (read by the UI)

    private(set) var runState: SessionRunState = .idle
    private(set) var trackingDescription: String = "Not started"
    private(set) var trackingIsNormal: Bool = false
    private(set) var fps: Double = 0
    private(set) var lastFrameTimestamp: TimeInterval = 0
    private(set) var thermalState: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState
    private(set) var isDepthAvailable: Bool = false
    /// Fraction 0...1 of depth pixels with usable (medium/high) confidence, or nil if unknown.
    private(set) var validDepthFraction: Double?
    private(set) var errorMessage: String?
    private(set) var isRecoveringSensors = false

    var canRetrySensorRecovery: Bool {
        foregroundActive && userWantsRunning && !isUserPaused && !systemInterrupted && recoveryReason != nil
    }

    var sensorStatusMessage: String? {
        if isUserPaused { return "Sensing is paused. Resume to continue camera, LiDAR, and alerts." }
        if !foregroundActive { return nil }
        if systemInterrupted { return "Camera access was interrupted. Your scan is retained; sensing resumes when access returns." }
        guard let recoveryReason else { return nil }
        if recoveryExhausted {
            return "Sensing needs attention: \(recoveryReason) Your scan is retained. Retry sensing or save the last checkpoint."
        }
        if requiresRecoveryOriginProof, lastFrameTimestamp > 0 {
            return "Camera data has returned. Slowly look around the same place to recover map alignment; the previous scan is retained."
        }
        return "Recovering camera and LiDAR (attempt \(recoveryPolicy.attempts) of \(SensorRecoveryPolicy.maximumAttempts)). Your scan is retained."
    }

    /// Changes whenever previously published world coordinates become invalid.
    private(set) var sessionGeneration: Int = 0
    private(set) var worldMappingStatus: ARFrame.WorldMappingStatus = .notAvailable
    private(set) var isRelocalizing = false
    private(set) var hasLocalizedMap = false
    private(set) var relocalizationTimedOut = false
    /// Explicit pause survives scene changes and automatic-mapping ticks.
    private(set) var isUserPaused = false
    /// Lets asynchronous load requests honor a newer explicit Pause command.
    private(set) var pauseRevision = 0
    private(set) var mappingRevision = 0

    var worldMappingDescription: String {
        switch worldMappingStatus {
        case .notAvailable: return "Not available"
        case .limited: return "Learning the room"
        case .extending: return "Extending map"
        case .mapped: return "Ready to save"
        @unknown default: return "Unknown"
        }
    }

    var canSaveWorldMap: Bool {
        guard !reconstructionHeld, !awaitingReconstructionReset, meshFaceCount > 0,
              let frame = session.currentFrame,
              isCurrentWorldFrame(frame),
              frame.timestamp >= reconstructionResetTimestamp else { return false }
        return frame.worldMappingStatus == .extending || frame.worldMappingStatus == .mapped
    }

    /// ARKit can publish currentFrame before its main-queue delegate is delivered.
    /// Requiring equality with the last delegate timestamp makes polling readers
    /// miss fresh camera/depth frames. Accept that newer frame after this run has
    /// delivered its first frame, while retaining the reset and freshness barriers.
    func isCurrentFrame(_ frame: ARFrame) -> Bool {
        runState == .running && Self.acceptsFrameTimestamp(frame.timestamp,
            lastAccepted: lastFrameTimestamp, minimum: minimumFrameTimestamp,
            now: CACurrentMediaTime())
    }

    /// Completed image work may legitimately lag the newest camera frame, but
    /// must never publish observations captured before a pause/resume or reset.
    func isCurrentObservation(timestamp: TimeInterval, maxAge: TimeInterval = 0.5) -> Bool {
        runState == .running && Self.acceptsObservationTimestamp(timestamp,
            lastAccepted: lastFrameTimestamp, minimum: minimumFrameTimestamp,
            now: CACurrentMediaTime(), maxAge: maxAge)
    }

    /// Camera-only previews/CV may use current images during relocalization.
    /// Anything placing data in the saved world must additionally pass this gate.
    func isCurrentWorldFrame(_ frame: ARFrame) -> Bool {
        guard isCurrentFrame(frame), trackingIsNormal, !isRelocalizing,
              !restoringSavedMap, !requiresRecoveryOriginProof,
              case .normal = frame.camera.trackingState else { return false }
        return true
    }

    nonisolated static func acceptsFrameTimestamp(_ timestamp: TimeInterval,
        lastAccepted: TimeInterval, minimum: TimeInterval, now: TimeInterval) -> Bool {
        acceptsObservationTimestamp(timestamp, lastAccepted: lastAccepted, minimum: minimum, now: now) &&
        timestamp >= lastAccepted
    }

    nonisolated static func acceptsObservationTimestamp(_ timestamp: TimeInterval,
        lastAccepted: TimeInterval, minimum: TimeInterval, now: TimeInterval,
        maxAge: TimeInterval = 0.5) -> Bool {
        timestamp.isFinite && lastAccepted.isFinite && minimum.isFinite && now.isFinite &&
        maxAge.isFinite && maxAge >= 0 &&
        lastAccepted > 0 && lastAccepted >= minimum &&
        timestamp >= minimum && timestamp <= now && now - timestamp <= maxAge
    }

    var relocalizationGuidance: String {
        if relocalizationTimedOut {
            return "This place has not been recognized yet. Match the saved camera view, improve the lighting, or start a new map."
        }
        if isRelocalizing {
            return "Return to the saved place and slowly match the reference view. Mapping resumes when the place is recognized."
        }
        if !trackingIsNormal { return "Move slowly and point the camera toward well-lit, detailed surfaces." }
        return "Scan the room from several angles. The camera and motion sensors track your pose while LiDAR maps surfaces."
    }

    /// User-facing visualization preferences shared across tabs.
    var depthSource: DepthSource = .smoothed

    /// Instrumentation tap (Phase 7 profiler): receives each delivered ARFrame's
    /// capture timestamp. Only a Double is passed — the frame is never retained.
    @ObservationIgnored var frameTimestampTap: ((TimeInterval) -> Void)?
    /// Synchronous consumers copy what they need; they must never retain a frame.
    @ObservationIgnored var mappingFrameTap: ((ARFrame, Int) -> Void)?

    /// Frame rate of the running configuration's video format, if known.
    var nominalFramesPerSecond: Int? {
        guard let fps = session.configuration?.videoFormat.framesPerSecond, fps > 0 else { return nil }
        return fps
    }

    // MARK: - Pose & motion (Feature 6) — all values are LOCAL ARKit coordinates,
    // not GPS. Origin is wherever the session started.

    private(set) var cameraPosition: SIMD3<Float> = .zero
    /// Pitch, yaw, roll in degrees.
    private(set) var cameraEulerDegrees: SIMD3<Float> = .zero
    private(set) var displacementMeters: Float = 0
    /// Recent camera positions for drawing a movement trail (world space, metres).
    private(set) var trail: [SIMD3<Float>] = []
    private var initialPosition: SIMD3<Float>?
    private var lastTrailTime: TimeInterval = 0

    // MARK: - Mesh statistics (Feature 5)

    private(set) var meshAnchorCount: Int = 0
    private(set) var meshVertexCount: Int = 0
    private(set) var meshFaceCount: Int = 0
    /// Explicit reconstruction deletions, distinct from surfaces merely outside
    /// the current camera view. Saved baseline chunks honor these tombstones.
    private(set) var removedMeshAnchorIDs: Set<UUID> = []
    private var meshStats: [UUID: (v: Int, f: Int)] = [:]
    private var reconstructionHeld = false
    var hasHeldMappingCapture: Bool { reconstructionHeld }
    private var awaitingReconstructionReset = false
    private var reconstructionResetTimestamp: TimeInterval = 0
    private var retiredMeshIDs: Set<UUID> = []
    private var retiredMeshRemovals: Set<UUID> = []
    private var heldMeshRemovals: Set<UUID> = []
    private var segmentMeshIDs: Set<UUID>?
    var currentSegmentMeshIDs: Set<UUID>? { segmentMeshIDs }

    /// Estimate the actual merge rather than taking the larger of two counts:
    /// a revisited room can contain disjoint saved and currently visible chunks.
    func mappingUsage(including baseline: SavedMapGeometry?) -> (vertices: Int, faces: Int, anchors: Int) {
        let unseen = (baseline?.meshes ?? []).filter {
            meshStats[$0.id] == nil && !removedMeshAnchorIDs.contains($0.id)
        }
        return (meshVertexCount + unseen.reduce(0) { $0 + $1.vertexCount },
                meshFaceCount + unseen.reduce(0) { $0 + $1.faceCount },
                meshAnchorCount + unseen.count)
    }

    // MARK: - Capability flags (resolved once)

    let supportsWorldTracking = ARWorldTrackingConfiguration.isSupported
    let supportsSceneDepth = ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
    let supportsSmoothedSceneDepth = ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth)
    let supportsMesh = ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
    let supportsMeshClassification = ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification)

    // MARK: - Private FPS / throttling state

    private var fpsLastTimestamp: TimeInterval = 0
    private var validDepthComputeInFlight = false
    private var lastValidDepthComputeTime: TimeInterval = 0
    /// Set true the first time the user explicitly starts, so background/foreground
    /// transitions only auto-resume a session the user actually wanted running.
    private var userWantsRunning = false
    private var foregroundActive = true
    private var pendingInitialWorldMap: ARWorldMap?
    private var pendingRunOptions: ARSession.RunOptions = []
    private var restoringSavedMap = false
    private var restorationAnchorID: UUID?
    private static let mapOriginAnchorName = "LiDARPlayground.saved-map-origin.v1"
    private var relocalizationTimeoutTask: Task<Void, Never>?
    private var minimumFrameTimestamp: TimeInterval = 0
    private var liveOriginAnchor: ARAnchor?
    private var requiresRecoveryOriginProof = false
    private var systemInterrupted = false
    private var recoveryPolicy = SensorRecoveryPolicy()
    private var recoveryReason: String?
    private var recoveryExhausted = false
    private var depthRecoveryPending = false
    private var depthMissingSince: TimeInterval?
    private var automaticRecoveryAllowed = true
    private var runStartedAt: TimeInterval = 0
    private var recoveryWatchdog: Task<Void, Never>?
    private var worldMapRequest: WorldMapSnapshotRequest?
    private var mappingCaptureInProgress = false

    override init() {
        super.init()
        session.delegate = self
        session.delegateQueue = nil // nil == main queue (lightweight work only)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(thermalStateChanged),
            name: ProcessInfo.thermalStateDidChangeNotification,
            object: nil
        )
    }

    // MARK: - Configuration

    /// Builds the world-tracking configuration, enabling every depth/mesh feature
    /// the current device actually supports.
    func makeConfiguration() -> ARWorldTrackingConfiguration {
        let config = ARWorldTrackingConfiguration()
        config.worldAlignment = .gravity
        config.planeDetection = []
        config.environmentTexturing = .none

        var semantics: ARConfiguration.FrameSemantics = []
        if supportsSceneDepth { semantics.insert(.sceneDepth) }
        if supportsSmoothedSceneDepth { semantics.insert(.smoothedSceneDepth) }
        config.frameSemantics = semantics

        if reconstructionHeld {
            config.sceneReconstruction = []
        } else if supportsMeshClassification {
            config.sceneReconstruction = .meshWithClassification
        } else if supportsMesh {
            config.sceneReconstruction = .mesh
        }
        return config
    }

    // MARK: - Lifecycle controls

    func start() {
        guard supportsWorldTracking else {
            runState = .unsupported
            errorMessage = "ARWorldTracking is not supported on this device (requires a physical iPhone/iPad with ARKit). LiDAR features require a device with a LiDAR scanner."
            return
        }
        isUserPaused = false
        userWantsRunning = true
        guard foregroundActive, !systemInterrupted else { return }
        if recoveryReason != nil { retrySensorRecovery(); return }
        guard runState != .running else { startRecoveryWatchdog(); return }
        minimumFrameTimestamp = CACurrentMediaTime()
        errorMessage = nil
        runState = .running
        requiresRecoveryOriginProof = requiresRecoveryOriginProof || liveOriginAnchor != nil
        if requiresRecoveryOriginProof || isRelocalizing { beginRelocalization(resetTimer: true) }
        runRequestedConfiguration()
    }

    func pause() {
        pauseRevision &+= 1
        isUserPaused = true
        userWantsRunning = false
        session.pause()
        runState = .paused
        relocalizationTimeoutTask?.cancel()
        relocalizationTimeoutTask = nil
        stopRecoveryWatchdog()
        cancelWorldMapRequest()
        invalidateLiveMetrics()
    }

    /// Full reset: discards tracking, anchors, and any accumulated mesh map.
    func reset() {
        guard supportsWorldTracking else { return }
        errorMessage = nil
        pendingInitialWorldMap = nil
        liveOriginAnchor = nil
        resetSensorRecovery()
        restoringSavedMap = false
        restorationAnchorID = nil
        hasLocalizedMap = false
        finishRelocalization()
        sessionGeneration += 1
        minimumFrameTimestamp = CACurrentMediaTime()
        clearDerivedState()
        pendingRunOptions = [.resetTracking, .removeExistingAnchors]
        if supportsMesh { pendingRunOptions.insert(.resetSceneReconstruction) }
        if userWantsRunning && foregroundActive && !systemInterrupted {
            runState = .running
            runRequestedConfiguration()
        } else {
            // A reset while paused must not turn the camera back on.
            session.pause()
            runState = .paused
        }
    }

    /// Deliberately begin scanning a new coordinate space, including from pause.
    func startNewMap() {
        reset()
        start()
    }

    /// Rotate the reconstruction file while retaining the AR world and route.
    /// Existing non-mesh anchors, camera pose, generation, and localization proof
    /// survive this option. Only newly reconstructed chunks enter the next file.
    @discardableResult
    func beginMappingSegment() -> Bool {
        guard supportsMesh, foregroundActive, userWantsRunning, !isUserPaused,
              reconstructionHeld,
              let frame = session.currentFrame, isCurrentWorldFrame(frame) else { return false }
        retiredMeshIDs = Set(meshStats.keys)
        retiredMeshIDs.formUnion(session.currentFrame?.anchors.compactMap {
            ($0 as? ARMeshAnchor)?.identifier
        } ?? [])
        retiredMeshRemovals = heldMeshRemovals.intersection(retiredMeshIDs)
        heldMeshRemovals = []
        segmentMeshIDs = []
        awaitingReconstructionReset = true
        reconstructionResetTimestamp = CACurrentMediaTime()
        reconstructionHeld = false
        meshStats = [:]
        meshAnchorCount = 0; meshVertexCount = 0; meshFaceCount = 0
        removedMeshAnchorIDs = []
        trail = []; lastTrailTime = 0
        mappingRevision &+= 1
        session.run(makeConfiguration(), options: [.resetSceneReconstruction])
        return true
    }

    /// A disk failure must not freeze the live mesh viewer. The coordinator
    /// retains its immutable capture and refreshes it before retrying the write.
    /// Re-enable reconstruction in the same world without removing any anchors.
    func resumeReconstructionAfterCheckpointFailure() {
        guard reconstructionHeld else { return }
        reconstructionHeld = false
        let removedWhileHeld = Array(heldMeshRemovals)
        heldMeshRemovals = []
        applyMesh(updates: [:], removed: removedWhileHeld)
        if foregroundActive, userWantsRunning, runState == .running {
            session.run(makeConfiguration())
        }
    }

    private func runRequestedConfiguration() {
        reclaimSessionDelegate()
        let configuration = makeConfiguration()
        configuration.initialWorldMap = pendingInitialWorldMap
        let options = pendingRunOptions
        pendingRunOptions = []
        runStartedAt = CACurrentMediaTime()
        session.run(configuration, options: options)
        startRecoveryWatchdog()
    }

    func restoreWorldMap(_ worldMap: ARWorldMap) throws {
        guard supportsWorldTracking, supportsMesh else { throw MappingSessionError.unsupported }
        guard let origin = worldMap.anchors.first(where: { $0.name == Self.mapOriginAnchorName }) else {
            throw MappingSessionError.invalidArchive
        }
        sessionGeneration += 1
        resetSensorRecovery()
        minimumFrameTimestamp = CACurrentMediaTime()
        clearDerivedState()
        hasLocalizedMap = false
        restoringSavedMap = true
        restorationAnchorID = origin.identifier
        liveOriginAnchor = origin
        pendingInitialWorldMap = worldMap
        pendingRunOptions = [.resetTracking, .removeExistingAnchors, .resetSceneReconstruction]
        userWantsRunning = true
        isUserPaused = false
        errorMessage = nil
        runState = foregroundActive && !systemInterrupted ? .running : .interrupted
        finishRelocalization()
        beginRelocalization()
        if foregroundActive && !systemInterrupted { runRequestedConfiguration() }
    }

    func cancelRelocalization() { startNewMap() }

    // MARK: - Scene phase handling

    func handleResignActive() {
        foregroundActive = false
        stopRecoveryWatchdog()
        cancelWorldMapRequest()
        relocalizationTimeoutTask?.cancel()
        relocalizationTimeoutTask = nil
        relocalizationTimedOut = false
        // Suspend sensors without changing the user's explicit running intent.
        if runState == .running {
            session.pause()
            runState = .interrupted
            invalidateLiveMetrics()
        }
    }

    func handleBecameActive() {
        foregroundActive = true
        guard !systemInterrupted else { return }
        if userWantsRunning && runState != .running {
            if recoveryReason != nil { retrySensorRecovery(); return }
            minimumFrameTimestamp = CACurrentMediaTime()
            runState = .running
            requiresRecoveryOriginProof = liveOriginAnchor != nil
            beginRelocalization(resetTimer: true)
            runRequestedConfiguration()
        }
    }

    // MARK: - Non-destructive sensor recovery

    /// A retry never removes anchors or resets world tracking. If ARKit cannot
    /// recover this world, its retained checkpoint remains available to save.
    func retrySensorRecovery() {
        guard foregroundActive, userWantsRunning, !isUserPaused, !systemInterrupted else { return }
        recoveryPolicy.reset()
        recoveryExhausted = false
        depthRecoveryPending = false
        depthMissingSince = nil
        automaticRecoveryAllowed = true
        beginSensorRecovery(reason: recoveryReason ?? "Camera data stopped arriving.")
        checkSensorHealth()
    }

    private func reclaimSessionDelegate() {
        if session.delegate !== self { session.delegate = self }
        session.delegateQueue = nil
    }

    private func startRecoveryWatchdog() {
        guard recoveryWatchdog == nil, foregroundActive, userWantsRunning,
              !isUserPaused, !systemInterrupted else { return }
        recoveryWatchdog = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self else { return }
                self.checkSensorHealth()
            }
        }
    }

    private func stopRecoveryWatchdog() {
        recoveryWatchdog?.cancel()
        recoveryWatchdog = nil
    }

    private func resetSensorRecovery() {
        stopRecoveryWatchdog()
        cancelWorldMapRequest()
        recoveryPolicy.reset()
        recoveryReason = nil
        recoveryExhausted = false
        depthRecoveryPending = false
        depthMissingSince = nil
        automaticRecoveryAllowed = true
        requiresRecoveryOriginProof = false
        isRecoveringSensors = false
    }

    private func beginSensorRecovery(reason: String) {
        recoveryReason = reason
        recoveryPolicy.lostFrames()
        // Never let late work or an older currentFrame cross this run boundary.
        minimumFrameTimestamp = CACurrentMediaTime()
        cancelWorldMapRequest()
        invalidateLiveMetrics()
        requiresRecoveryOriginProof = liveOriginAnchor != nil || restoringSavedMap || meshFaceCount > 0
        if userWantsRunning, foregroundActive, !systemInterrupted {
            runState = .running
            isRecoveringSensors = automaticRecoveryAllowed
            if requiresRecoveryOriginProof { beginRelocalization(resetTimer: true) }
            startRecoveryWatchdog()
        }
        if !automaticRecoveryAllowed {
            recoveryExhausted = true
            isRecoveringSensors = false
        }
    }

    private func checkSensorHealth() {
        guard foregroundActive, userWantsRunning, !isUserPaused, !systemInterrupted else { return }
        // A newly attached ARSCNView can take the shared session's delegate.
        // Reclaim ownership first and give it time to deliver its next frame.
        if session.delegate !== self {
            reclaimSessionDelegate()
            runStartedAt = CACurrentMediaTime()
            return
        }
        guard automaticRecoveryAllowed, !recoveryExhausted else { return }
        let now = CACurrentMediaTime()
        if supportsSceneDepth, let depthMissingSince,
           now - depthMissingSince >= SensorRecoveryPolicy.startupGrace,
           lastFrameTimestamp > 0, now - lastFrameTimestamp < 0.5,
           trackingIsNormal, !isRelocalizing, !depthRecoveryPending {
            depthRecoveryPending = true
            beginSensorRecovery(reason: "LiDAR depth data stopped arriving.")
        }
        if requiresRecoveryOriginProof, lastFrameTimestamp > 0, now - lastFrameTimestamp < 0.5 {
            if relocalizationTimedOut {
                recoveryReason = "The previous map's alignment is not confirmed."
                recoveryExhausted = true
                isRecoveringSensors = false
                errorMessage = "Camera data returned, but the previous map's alignment is not confirmed. Retry in the same place or save the last checkpoint."
            }
            return // Fresh camera images are not a sensor stall.
        }
        let decision = recoveryPolicy.decision(now: now, runStartedAt: runStartedAt,
            lastFrameAt: lastFrameTimestamp, foreground: foregroundActive,
            wantsRunning: userWantsRunning, interrupted: systemInterrupted,
            failed: recoveryReason != nil && (lastFrameTimestamp == 0 || depthRecoveryPending))
        switch decision {
        case .wait: return
        case .exhausted:
            recoveryExhausted = true
            isRecoveringSensors = false
            errorMessage = "Camera and LiDAR data have not resumed. Your scan is retained. Retry sensing or save the last checkpoint."
        case .retry:
            if recoveryReason == nil { beginSensorRecovery(reason: "Camera data stopped arriving.") }
            recoveryPolicy.didAttempt(at: now)
            isRecoveringSensors = true
            minimumFrameTimestamp = now
            runStartedAt = now
            invalidateLiveMetrics()
            runState = .running
            reclaimSessionDelegate()
            // Reuse this exact coordinate system. Reinjecting an old initial map
            // or resetTracking here would silently discard newer observations.
            session.run(makeConfiguration(), options: [])
        }
    }

    private func cancelWorldMapRequest() {
        worldMapRequest?.finish(.failure(MappingSessionError.changedSession))
        worldMapRequest = nil
    }

    @objc private nonisolated func thermalStateChanged() {
        let state = ProcessInfo.processInfo.thermalState
        Task { @MainActor in self.thermalState = state }
    }

    // MARK: - ARSessionDelegate (called on the main queue; keep it light)

    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // Hop is a no-op (already main) but satisfies isolation checking.
        MainActor.assumeIsolated {
            self.ingest(frame: frame)
        }
    }

    nonisolated func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        MainActor.assumeIsolated {
            guard self.runState == .running else { return }
            self.updateTracking(camera.trackingState)
        }
    }

    nonisolated func sessionWasInterrupted(_ session: ARSession) {
        MainActor.assumeIsolated {
            self.systemInterrupted = true
            self.stopRecoveryWatchdog()
            self.cancelWorldMapRequest()
            if self.userWantsRunning { self.runState = .interrupted }
            self.relocalizationTimeoutTask?.cancel()
            self.relocalizationTimeoutTask = nil
            self.relocalizationTimedOut = false
            self.invalidateLiveMetrics()
        }
    }

    nonisolated func sessionInterruptionEnded(_ session: ARSession) {
        MainActor.assumeIsolated {
            self.systemInterrupted = false
            guard self.userWantsRunning, self.foregroundActive else { return }
            self.minimumFrameTimestamp = CACurrentMediaTime()
            self.runState = .running
            self.requiresRecoveryOriginProof = self.liveOriginAnchor != nil
            self.beginRelocalization(resetTimer: true)
            self.runStartedAt = CACurrentMediaTime()
            self.reclaimSessionDelegate()
            self.startRecoveryWatchdog()
            if !self.pendingRunOptions.isEmpty || self.session.configuration == nil {
                self.runRequestedConfiguration()
            }
        }
    }

    nonisolated func sessionShouldAttemptRelocalization(_ session: ARSession) -> Bool {
        // Never silently replace the coordinate space of a saved/live map after
        // an interruption. The UI provides an explicit Start New Map escape.
        true
    }

    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        let message = error.localizedDescription
        let code = (error as? ARError)?.code
        MainActor.assumeIsolated {
            self.errorMessage = message
            // Failure does not authorize a new coordinate space or destroying
            // the user's unsaved surfaces, path, and checkpoint. Live world use
            // remains blocked until a fresh frame proves the original anchor.
            self.automaticRecoveryAllowed = code != .cameraUnauthorized &&
                code != .unsupportedConfiguration && code != .invalidConfiguration && code != .invalidWorldMap
            self.beginSensorRecovery(reason: message)
            self.checkSensorHealth()
        }
    }

    // MARK: - Mesh anchors (Feature 5 statistics)

    nonisolated func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        let counts = Self.meshCounts(anchors)
        guard !counts.isEmpty else { return }
        MainActor.assumeIsolated { self.applyMesh(updates: counts, removed: []) }
    }

    nonisolated func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        let counts = Self.meshCounts(anchors)
        guard !counts.isEmpty else { return }
        MainActor.assumeIsolated { self.applyMesh(updates: counts, removed: []) }
    }

    nonisolated func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        let ids = anchors.compactMap { ($0 as? ARMeshAnchor)?.identifier }
        guard !ids.isEmpty else { return }
        MainActor.assumeIsolated {
            if self.reconstructionHeld { self.heldMeshRemovals.formUnion(ids) }
            // Resets/relocalization also remove anchors. Those events must not
            // delete the saved baseline before its coordinate space is restored.
            if self.runState == .running, self.trackingIsNormal, !self.isRelocalizing {
                if !self.reconstructionHeld {
                    self.removedMeshAnchorIDs.formUnion(ids.filter {
                        self.segmentMeshIDs?.contains($0) ?? true
                    })
                }
            }
            self.retiredMeshRemovals.formUnion(ids.filter { self.retiredMeshIDs.contains($0) })
            self.applyMesh(updates: [:], removed: ids)
        }
    }

    nonisolated static func meshCounts(_ anchors: [ARAnchor]) -> [UUID: (v: Int, f: Int)] {
        var result: [UUID: (v: Int, f: Int)] = [:]
        for anchor in anchors {
            guard let mesh = anchor as? ARMeshAnchor else { continue }
            result[mesh.identifier] = (mesh.geometry.vertices.count, mesh.geometry.faces.count)
        }
        return result
    }

    private func applyMesh(updates: [UUID: (v: Int, f: Int)], removed: [UUID]) {
        guard !reconstructionHeld, !requiresRecoveryOriginProof else { return }
        mappingRevision &+= 1
        for (id, value) in updates {
            guard segmentMeshIDs == nil || !retiredMeshIDs.contains(id) || retiredMeshRemovals.contains(id) else { continue }
            segmentMeshIDs?.insert(id)
            meshStats[id] = value
            removedMeshAnchorIDs.remove(id)
        }
        for id in removed { meshStats.removeValue(forKey: id) }
        meshAnchorCount = meshStats.count
        meshVertexCount = meshStats.values.reduce(0) { $0 + $1.v }
        meshFaceCount = meshStats.values.reduce(0) { $0 + $1.f }
    }

    /// Clear reconstruction and tracking together so no old map coordinates leak
    /// into a fresh scan. Preserve the user's paused/running choice.
    func resetMeshMap() {
        reset()
    }

    private func clearDerivedState() {
        reconstructionHeld = false
        awaitingReconstructionReset = false
        reconstructionResetTimestamp = 0
        retiredMeshIDs = []; retiredMeshRemovals = []; heldMeshRemovals = []; segmentMeshIDs = nil
        mappingRevision &+= 1
        meshStats.removeAll()
        removedMeshAnchorIDs.removeAll()
        meshAnchorCount = 0
        meshVertexCount = 0
        meshFaceCount = 0
        trail.removeAll()
        initialPosition = nil
        displacementMeters = 0
        cameraPosition = .zero
        cameraEulerDegrees = .zero
        lastTrailTime = 0
        worldMappingStatus = .notAvailable
        invalidateLiveMetrics()
    }

    // MARK: - Per-frame ingest (main thread, lightweight only)

    private func ingest(frame: ARFrame) {
        guard runState == .running, frame.timestamp >= minimumFrameTimestamp else { return }
        let t = frame.timestamp
        let expectedOrigin = restoringSavedMap ? restorationAnchorID : liveOriginAnchor?.identifier
        let needsProof = restoringSavedMap || requiresRecoveryOriginProof
        let hasRestoredOrigin = !needsProof || (expectedOrigin != nil && frame.anchors.contains { $0.identifier == expectedOrigin })
        updateTracking(frame.camera.trackingState, acceptsLocalization: hasRestoredOrigin)
        if case .normal = frame.camera.trackingState, hasRestoredOrigin {
            requiresRecoveryOriginProof = false
            if needsProof {
                // Mesh callbacks may precede the frame that proves alignment.
                // Reconcile those safe, current anchors after the proof arrives.
                applyMesh(updates: Self.meshCounts(frame.anchors), removed: [])
            }
            if liveOriginAnchor == nil {
                let anchor = ARAnchor(name: Self.mapOriginAnchorName, transform: matrix_identity_float4x4)
                liveOriginAnchor = anchor
                session.add(anchor: anchor)
            }
            if recoveryReason != nil, !depthRecoveryPending || frame.sceneDepth != nil || frame.smoothedSceneDepth != nil {
                recoveryReason = nil
                recoveryExhausted = false
                isRecoveringSensors = false
                errorMessage = nil
                depthRecoveryPending = false
            }
        }
        worldMappingStatus = frame.worldMappingStatus
        if awaitingReconstructionReset, frame.timestamp >= reconstructionResetTimestamp,
           frame.anchors.contains(where: { anchor in
               anchor is ARMeshAnchor && (segmentMeshIDs?.contains(anchor.identifier) ?? false)
           }) {
            awaitingReconstructionReset = false
        }
        if fpsLastTimestamp > 0 {
            let dt = t - fpsLastTimestamp
            if dt > 0 {
                let instantaneous = 1.0 / dt
                // Exponential smoothing for a readable FPS number.
                fps = fps == 0 ? instantaneous : (fps * 0.9 + instantaneous * 0.1)
            }
        }
        fpsLastTimestamp = t
        lastFrameTimestamp = t
        if !depthRecoveryPending { recoveryPolicy.observedFrame(at: t) }
        frameTimestampTap?(t)
        isDepthAvailable = (frame.sceneDepth != nil) || (frame.smoothedSceneDepth != nil)
        if isDepthAvailable { depthMissingSince = nil }
        else if depthMissingSince == nil { depthMissingSince = t }

        updatePose(frame: frame, time: t)
        maybeComputeValidDepth(frame: frame)
        if trackingIsNormal && !isRelocalizing { mappingFrameTap?(frame, sessionGeneration) }
    }

    /// Updates local camera pose, displacement, and the movement trail.
    private func updatePose(frame: ARFrame, time t: TimeInterval) {
        // Limited/relocalizing poses must not pollute saved geometry or trails.
        guard trackingIsNormal, !isRelocalizing else { return }
        let transform = frame.camera.transform
        let pos = SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
        cameraPosition = pos
        cameraEulerDegrees = frame.camera.eulerAngles * (180 / .pi)
        if initialPosition == nil { initialPosition = pos }
        if let origin = initialPosition { displacementMeters = simd_distance(pos, origin) }

        if t - lastTrailTime > 0.1 {
            if let last = trail.last {
                if simd_distance(last, pos) > 0.01 { appendTrail(pos) }
            } else {
                appendTrail(pos)
            }
            lastTrailTime = t
        }
    }

    private func appendTrail(_ p: SIMD3<Float>) {
        trail.append(p)
        if trail.count > 3000 { trail.removeFirst(trail.count - 3000) }
    }

    /// Computes the usable-depth percentage off the main thread, throttled to a
    /// few times per second so we never scan a full confidence buffer on-screen-rate.
    private func maybeComputeValidDepth(frame: ARFrame) {
        guard !validDepthComputeInFlight else { return }
        let now = CACurrentMediaTime()
        guard now - lastValidDepthComputeTime > 0.33 else { return }
        guard let depth = frame.sceneDepth ?? frame.smoothedSceneDepth,
              let confidence = depth.confidenceMap else {
            validDepthFraction = nil
            return
        }
        validDepthComputeInFlight = true
        lastValidDepthComputeTime = now
        let generation = sessionGeneration
        let capturedAt = frame.timestamp

        Task { [weak self] in
            let fraction = await ARSessionManager.usableFractionAsync(confidence)
            guard let self else { return }
            if self.sessionGeneration == generation, self.isCurrentObservation(timestamp: capturedAt) {
                self.validDepthFraction = fraction
            }
            self.validDepthComputeInFlight = false
        }
    }

    /// Runs the (CPU) confidence scan off the main actor and returns the fraction.
    nonisolated static func usableFractionAsync(_ confidenceMap: CVPixelBuffer) async -> Double {
        await Task.detached(priority: .utility) {
            usableFraction(confidenceMap: confidenceMap)
        }.value
    }

    /// Scans a confidence map (strided for speed) and returns the fraction of
    /// pixels at medium or high confidence.
    nonisolated static func usableFraction(confidenceMap: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(confidenceMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(confidenceMap, .readOnly) }
        let width = CVPixelBufferGetWidth(confidenceMap)
        let height = CVPixelBufferGetHeight(confidenceMap)
        let rowBytes = CVPixelBufferGetBytesPerRow(confidenceMap)
        guard let base = CVPixelBufferGetBaseAddress(confidenceMap) else { return 0 }

        let stride = 4 // sample every 4th pixel in each axis — plenty for a percentage
        var usable = 0
        var total = 0
        let medium = ARConfidenceLevel.medium.rawValue
        var y = 0
        while y < height {
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt8.self)
            var x = 0
            while x < width {
                if Int(row[x]) >= medium { usable += 1 }
                total += 1
                x += stride
            }
            y += stride
        }
        return total > 0 ? Double(usable) / Double(total) : 0
    }

    // MARK: - Helpers

    private func invalidateLiveMetrics() {
        trackingIsNormal = false
        trackingDescription = "Waiting for tracking"
        fps = 0
        fpsLastTimestamp = 0
        lastFrameTimestamp = 0
        isDepthAvailable = false
        validDepthFraction = nil
        depthMissingSince = nil
    }

    private func updateTracking(_ state: ARCamera.TrackingState, acceptsLocalization: Bool = false) {
        guard runState == .running else { return }
        trackingDescription = Self.describe(state)
        if case .normal = state {
            trackingIsNormal = true
            // Only a new frame from this run can resolve the initial world map;
            // a queued tracking callback from the previous run cannot do so.
            if acceptsLocalization {
                if restoringSavedMap {
                    hasLocalizedMap = true
                    restoringSavedMap = false
                    restorationAnchorID = nil
                    pendingInitialWorldMap = nil
                }
                finishRelocalization()
            }
        } else {
            trackingIsNormal = false
            if case .limited(.relocalizing) = state { beginRelocalization() }
        }
    }

    private func beginRelocalization(resetTimer: Bool = false) {
        guard !isRelocalizing || resetTimer else { return }
        isRelocalizing = true
        relocalizationTimedOut = false
        let generation = sessionGeneration
        relocalizationTimeoutTask?.cancel()
        relocalizationTimeoutTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            guard let self, self.sessionGeneration == generation, self.isRelocalizing else { return }
            self.relocalizationTimedOut = true
        }
    }

    private func finishRelocalization() {
        isRelocalizing = false
        relocalizationTimedOut = false
        relocalizationTimeoutTask?.cancel()
        relocalizationTimeoutTask = nil
    }

    /// Freeze renderable geometry independently of ARKit's opaque localization
    /// archive. Metal buffers are copied here before any asynchronous work.
    private func copyMappingGeometry() throws -> (SavedMapGeometry, CVPixelBuffer, CGImagePropertyOrientation) {
        guard canSaveWorldMap, let frame = session.currentFrame else { throw MappingSessionError.notReady }
        let anchors = frame.anchors.compactMap { $0 as? ARMeshAnchor }.filter {
            segmentMeshIDs?.contains($0.identifier) ?? true
        }
        guard !anchors.isEmpty else { throw MappingSessionError.noSurface }
        let vertexCount = anchors.reduce(0) { $0 + $1.geometry.vertices.count }
        let faceCount = anchors.reduce(0) { $0 + $1.geometry.faces.count }
        guard anchors.count <= MapLimits.maxMeshAnchors,
              vertexCount <= MapLimits.maxVertices, faceCount <= MapLimits.maxTriangles else {
            throw MappingSessionError.tooLarge
        }
        let geometry = SavedMapGeometry(
            meshes: try anchors.map { try MapMeshSnapshot.capture($0) },
            trail: trail.suffix(MapLimits.maxTrailPoints).map { MapPosition(x: $0.x, y: $0.y, z: $0.z) })
        try geometry.validate()
        return (geometry, frame.capturedImage, referenceImageOrientation())
    }

    private func referenceImageOrientation() -> CGImagePropertyOrientation {
        let orientation = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }?.effectiveGeometry.interfaceOrientation ?? .portrait
        // Interface and physical device landscape orientations are opposites.
        switch orientation {
        case .portrait: return .right
        case .portraitUpsideDown: return .left
        case .landscapeLeft: return .down
        case .landscapeRight: return .up
        default: return .right
        }
    }

    func captureMappingSnapshot(holdReconstructionAfterCapture: Bool = false) async throws -> MappingSessionCapture {
        guard supportsMesh else { throw MappingSessionError.unsupported }
        guard canSaveWorldMap else { throw MappingSessionError.notReady }
        guard !mappingCaptureInProgress else { throw MappingSessionError.captureBusy }
        mappingCaptureInProgress = true
        defer { mappingCaptureInProgress = false }
        let generation = sessionGeneration
        let request = WorldMapSnapshotRequest()
        worldMapRequest = request
        defer { if worldMapRequest === request { worldMapRequest = nil } }
        let worldMap: ARWorldMap = try await withCheckedThrowingContinuation { continuation in
            request.continuation = continuation
            request.timeoutTask = Task { [weak request] in
                do { try await Task.sleep(for: .seconds(8)) } catch { return }
                request?.finish(.failure(MappingSessionError.captureTimedOut))
            }
            session.getCurrentWorldMap { map, error in
                Task { @MainActor in
                    if let error { request.finish(.failure(error)) }
                    else if let map { request.finish(.success(map)) }
                    else { request.finish(.failure(MappingSessionError.notReady)) }
                }
            }
        }
        if worldMapRequest === request { worldMapRequest = nil }
        guard generation == sessionGeneration, canSaveWorldMap else { throw MappingSessionError.changedSession }
        let (geometry, imageBuffer, orientation) = try copyMappingGeometry()
        // The same identity lives in the active session and every checkpoint.
        // It can therefore prove continuity after a dropout as well as restore.
        guard let origin = liveOriginAnchor else { throw MappingSessionError.notReady }
        worldMap.anchors.removeAll { $0.name == Self.mapOriginAnchorName }
        worldMap.anchors.append(origin)
        let data = try await Task.detached(priority: .userInitiated) {
            let worldData = try NSKeyedArchiver.archivedData(withRootObject: worldMap, requiringSecureCoding: true)
            guard worldData.count <= MapLimits.maxWorldMapBytes else { throw MappingSessionError.tooLarge }
            // This reference image helps users recognize the exact capture area.
            // The only camera buffer retained is this one-shot image, never ARFrame.
            let source = CIImage(cvPixelBuffer: imageBuffer).oriented(orientation)
            let scale = min(1.0, 1024.0 / max(source.extent.width, source.extent.height))
            let image = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let preview = CIContext().jpegRepresentation(of: image,
                colorSpace: CGColorSpaceCreateDeviceRGB(), options: [:])
            if let preview, preview.count > MapLimits.maxReferenceImageBytes {
                throw MappingSessionError.tooLarge
            }
            return (worldData, preview)
        }.value
        // Encoding an already valid immutable snapshot must survive a later
        // dropout/pause. Only a deliberate change of world invalidates it.
        guard generation == sessionGeneration else { throw MappingSessionError.changedSession }
        if holdReconstructionAfterCapture, canSaveWorldMap {
            // Copy once more after encoding, then stop reconstruction intake.
            // No throwing work remains after the hold begins: the coordinator
            // can always retain this immutable capture if the disk write fails.
            let (finalGeometry, _, _) = try copyMappingGeometry()
            let result = MappingSessionCapture(geometry: finalGeometry, worldMapData: data.0, referenceImageData: data.1)
            reconstructionHeld = true
            heldMeshRemovals = []
            session.run(makeConfiguration())
            return result
        }
        return MappingSessionCapture(geometry: geometry, worldMapData: data.0, referenceImageData: data.1)
    }

    nonisolated static func decodeWorldMap(_ data: Data) async throws -> ARWorldMap {
        guard !data.isEmpty, data.count <= MapLimits.maxWorldMapBytes else { throw MappingSessionError.invalidArchive }
        return try await Task.detached(priority: .userInitiated) {
            guard let map = try NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: data) else {
                throw MappingSessionError.invalidArchive
            }
            return map
        }.value
    }

    nonisolated static func describe(_ state: ARCamera.TrackingState) -> String {
        switch state {
        case .normal:
            return "Normal"
        case .notAvailable:
            return "Not available"
        case .limited(let reason):
            switch reason {
            case .initializing: return "Limited — initializing"
            case .excessiveMotion: return "Limited — too much motion"
            case .insufficientFeatures: return "Limited — not enough detail"
            case .relocalizing: return "Limited — relocalizing"
            @unknown default: return "Limited"
            }
        @unknown default:
            return "Unknown"
        }
    }
}

nonisolated struct MappingSessionCapture: Sendable {
    let geometry: SavedMapGeometry
    let worldMapData: Data
    let referenceImageData: Data?
}

nonisolated enum MappingSessionError: LocalizedError, Equatable {
    case unsupported, notReady, noSurface, tooLarge, changedSession, invalidArchive, captureBusy, captureTimedOut

    var errorDescription: String? {
        switch self {
        case .unsupported: return "Mapping requires an ARKit device with a LiDAR scanner, such as iPhone 15 Pro Max."
        case .notReady: return "Keep scanning slowly until tracking is normal and the room is mapped before saving."
        case .noSurface: return "No LiDAR surfaces have been captured yet. Point the camera at nearby surfaces and scan again."
        case .tooLarge: return "This scan is too large to save as one place. Start a separate map for the next area."
        case .changedSession: return "The scan changed or tracking stopped while saving. Please try saving again."
        case .invalidArchive: return "The saved localization data could not be opened. The 3D preview may still be available."
        case .captureBusy: return "A map checkpoint is already being captured. Wait for it to finish before saving again."
        case .captureTimedOut: return "Camera tracking did not return a map in time. Retry sensing, or save the last available checkpoint."
        }
    }
}

/// ARKit's callback has no cancellation API. Finish at most once, allowing a
/// timeout/reset to release the caller while safely ignoring a late callback.
@MainActor
final class WorldMapSnapshotRequest {
    var continuation: CheckedContinuation<ARWorldMap, Error>?
    var timeoutTask: Task<Void, Never>?

    func finish(_ result: Result<ARWorldMap, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        continuation.resume(with: result)
    }
}
