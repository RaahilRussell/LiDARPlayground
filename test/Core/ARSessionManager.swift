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

    /// Changes whenever previously published world coordinates become invalid.
    private(set) var sessionGeneration: Int = 0
    private(set) var worldMappingStatus: ARFrame.WorldMappingStatus = .notAvailable
    private(set) var isRelocalizing = false
    private(set) var hasLocalizedMap = false
    private(set) var relocalizationTimedOut = false

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
        guard runState == .running, trackingIsNormal, !isRelocalizing, meshFaceCount > 0,
              let frame = session.currentFrame,
              frame.timestamp >= minimumFrameTimestamp,
              CACurrentMediaTime() - frame.timestamp < 0.5 else { return false }
        return worldMappingStatus == .extending || worldMappingStatus == .mapped
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
    private var meshStats: [UUID: (v: Int, f: Int)] = [:]

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
    private var pendingInitialWorldMap: ARWorldMap?
    private var pendingRunOptions: ARSession.RunOptions = []
    private var restoringSavedMap = false
    private var restorationAnchorID: UUID?
    private static let mapOriginAnchorName = "LiDARPlayground.saved-map-origin.v1"
    private var relocalizationTimeoutTask: Task<Void, Never>?
    private var minimumFrameTimestamp: TimeInterval = 0

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

        if supportsMeshClassification {
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
        guard runState != .running else { return }
        userWantsRunning = true
        errorMessage = nil
        runState = .running
        runRequestedConfiguration()
    }

    func pause() {
        userWantsRunning = false
        session.pause()
        runState = .paused
        invalidateLiveMetrics()
    }

    /// Full reset: discards tracking, anchors, and any accumulated mesh map.
    func reset() {
        guard supportsWorldTracking else { return }
        errorMessage = nil
        pendingInitialWorldMap = nil
        restoringSavedMap = false
        restorationAnchorID = nil
        hasLocalizedMap = false
        finishRelocalization()
        sessionGeneration += 1
        minimumFrameTimestamp = CACurrentMediaTime()
        clearDerivedState()
        pendingRunOptions = [.resetTracking, .removeExistingAnchors, .resetSceneReconstruction]
        if userWantsRunning {
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

    private func runRequestedConfiguration() {
        let configuration = makeConfiguration()
        configuration.initialWorldMap = pendingInitialWorldMap
        let options = pendingRunOptions
        pendingRunOptions = []
        session.run(configuration, options: options)
    }

    func restoreWorldMap(_ worldMap: ARWorldMap) throws {
        guard supportsWorldTracking, supportsMesh else { throw MappingSessionError.unsupported }
        guard let origin = worldMap.anchors.first(where: { $0.name == Self.mapOriginAnchorName }) else {
            throw MappingSessionError.invalidArchive
        }
        sessionGeneration += 1
        minimumFrameTimestamp = CACurrentMediaTime()
        clearDerivedState()
        hasLocalizedMap = false
        restoringSavedMap = true
        restorationAnchorID = origin.identifier
        pendingInitialWorldMap = worldMap
        pendingRunOptions = [.resetTracking, .removeExistingAnchors, .resetSceneReconstruction]
        userWantsRunning = true
        errorMessage = nil
        runState = .running
        finishRelocalization()
        beginRelocalization()
        runRequestedConfiguration()
    }

    func cancelRelocalization() { startNewMap() }

    // MARK: - Scene phase handling

    func handleResignActive() {
        // ARKit will interrupt automatically; we just reflect state. Don't call
        // pause() here or we won't be told when the interruption ends.
        if runState == .running {
            runState = .interrupted
            invalidateLiveMetrics()
        }
    }

    func handleBecameActive() {
        if userWantsRunning && runState != .running {
            runState = .running
            runRequestedConfiguration()
        }
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
            self.updateTracking(camera.trackingState)
        }
    }

    nonisolated func sessionWasInterrupted(_ session: ARSession) {
        MainActor.assumeIsolated {
            if self.userWantsRunning { self.runState = .interrupted }
            self.invalidateLiveMetrics()
        }
    }

    nonisolated func sessionInterruptionEnded(_ session: ARSession) {
        MainActor.assumeIsolated {
            if self.userWantsRunning { self.runState = .running }
        }
    }

    nonisolated func sessionShouldAttemptRelocalization(_ session: ARSession) -> Bool {
        // Never silently replace the coordinate space of a saved/live map after
        // an interruption. The UI provides an explicit Start New Map escape.
        true
    }

    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        let message = error.localizedDescription
        MainActor.assumeIsolated {
            self.errorMessage = message
            self.runState = .idle
            self.userWantsRunning = false
            self.invalidateLiveMetrics()
            self.finishRelocalization()
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
        MainActor.assumeIsolated { self.applyMesh(updates: [:], removed: ids) }
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
        for (id, value) in updates { meshStats[id] = value }
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
        meshStats.removeAll()
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
        let hasRestoredOrigin = !restoringSavedMap || frame.anchors.contains { $0.identifier == restorationAnchorID }
        updateTracking(frame.camera.trackingState, acceptsLocalization: hasRestoredOrigin)
        worldMappingStatus = frame.worldMappingStatus
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
        frameTimestampTap?(t)
        isDepthAvailable = (frame.sceneDepth != nil) || (frame.smoothedSceneDepth != nil)

        updatePose(frame: frame, time: t)
        maybeComputeValidDepth(frame: frame)
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

        Task { [weak self] in
            let fraction = await ARSessionManager.usableFractionAsync(confidence)
            guard let self else { return }
            if self.sessionGeneration == generation, self.runState == .running {
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
        isDepthAvailable = false
        validDepthFraction = nil
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

    private func beginRelocalization() {
        guard !isRelocalizing else { return }
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
        let anchors = frame.anchors.compactMap { $0 as? ARMeshAnchor }
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
            .first { $0.activationState == .foregroundActive }?.interfaceOrientation ?? .portrait
        // Interface and physical device landscape orientations are opposites.
        switch orientation {
        case .portrait: return .right
        case .portraitUpsideDown: return .left
        case .landscapeLeft: return .down
        case .landscapeRight: return .up
        default: return .right
        }
    }

    func captureMappingSnapshot() async throws -> MappingSessionCapture {
        guard supportsMesh else { throw MappingSessionError.unsupported }
        guard canSaveWorldMap else { throw MappingSessionError.notReady }
        let generation = sessionGeneration
        let worldMap: ARWorldMap = try await withCheckedThrowingContinuation { continuation in
            session.getCurrentWorldMap { map, error in
                if let error { continuation.resume(throwing: error) }
                else if let map { continuation.resume(returning: map) }
                else { continuation.resume(throwing: MappingSessionError.notReady) }
            }
        }
        guard generation == sessionGeneration, canSaveWorldMap else { throw MappingSessionError.changedSession }
        let (geometry, imageBuffer, orientation) = try copyMappingGeometry()
        // A restored anchor proves a normal frame belongs to this saved world,
        // not a final frame from the session that ran immediately before loading.
        // Replacing the marker also prevents old map markers from accumulating.
        worldMap.anchors.removeAll { $0.name == Self.mapOriginAnchorName }
        worldMap.anchors.append(ARAnchor(name: Self.mapOriginAnchorName, transform: matrix_identity_float4x4))
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
        guard generation == sessionGeneration, canSaveWorldMap else { throw MappingSessionError.changedSession }
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

nonisolated enum MappingSessionError: LocalizedError {
    case unsupported, notReady, noSurface, tooLarge, changedSession, invalidArchive

    var errorDescription: String? {
        switch self {
        case .unsupported: return "Mapping requires an ARKit device with a LiDAR scanner, such as iPhone 15 Pro Max."
        case .notReady: return "Keep scanning slowly until tracking is normal and the room is mapped before saving."
        case .noSurface: return "No LiDAR surfaces have been captured yet. Point the camera at nearby surfaces and scan again."
        case .tooLarge: return "This scan is too large to save as one place. Start a separate map for the next area."
        case .changedSession: return "The scan changed or tracking stopped while saving. Please try saving again."
        case .invalidArchive: return "The saved localization data could not be opened. The 3D preview may still be available."
        }
    }
}
