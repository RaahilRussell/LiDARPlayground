//
//  ARSessionManager.swift
//  test
//
//  The single owner of the app's one ARSession. Every view observes this
//  object; no other object is allowed to create or run an ARSession.
//

import ARKit
import Observation
import QuartzCore
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
        userWantsRunning = true
        errorMessage = nil
        session.run(makeConfiguration(), options: [])
        runState = .running
    }

    func pause() {
        userWantsRunning = false
        session.pause()
        runState = .paused
    }

    /// Full reset: discards tracking, anchors, and any accumulated mesh map.
    func reset() {
        guard supportsWorldTracking else { return }
        userWantsRunning = true
        errorMessage = nil
        session.run(makeConfiguration(), options: [.resetTracking, .removeExistingAnchors])
        clearDerivedState()
        runState = .running
    }

    // MARK: - Scene phase handling

    func handleResignActive() {
        // ARKit will interrupt automatically; we just reflect state. Don't call
        // pause() here or we won't be told when the interruption ends.
        if runState == .running { runState = .interrupted }
    }

    func handleBecameActive() {
        if userWantsRunning && runState != .running {
            session.run(makeConfiguration(), options: [])
            runState = .running
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
        let desc = Self.describe(camera.trackingState)
        let normal: Bool
        if case .normal = camera.trackingState { normal = true } else { normal = false }
        MainActor.assumeIsolated {
            self.trackingDescription = desc
            self.trackingIsNormal = normal
        }
    }

    nonisolated func sessionWasInterrupted(_ session: ARSession) {
        MainActor.assumeIsolated { self.runState = .interrupted }
    }

    nonisolated func sessionInterruptionEnded(_ session: ARSession) {
        MainActor.assumeIsolated {
            if self.userWantsRunning { self.runState = .running }
        }
    }

    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        let message = error.localizedDescription
        MainActor.assumeIsolated {
            self.errorMessage = message
            self.runState = .idle
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

    /// Clears the accumulated mesh map (and movement trail) without stopping tracking.
    func resetMeshMap() {
        guard supportsWorldTracking else { return }
        session.run(makeConfiguration(), options: [.removeExistingAnchors])
        clearDerivedState()
    }

    private func clearDerivedState() {
        meshStats.removeAll()
        meshAnchorCount = 0
        meshVertexCount = 0
        meshFaceCount = 0
        trail.removeAll()
        initialPosition = nil
        displacementMeters = 0
    }

    // MARK: - Per-frame ingest (main thread, lightweight only)

    private func ingest(frame: ARFrame) {
        let t = frame.timestamp
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

        Task { [weak self] in
            let fraction = await ARSessionManager.usableFractionAsync(confidence)
            self?.validDepthFraction = fraction
            self?.validDepthComputeInFlight = false
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
