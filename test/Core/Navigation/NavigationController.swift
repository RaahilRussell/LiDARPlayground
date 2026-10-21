import ARKit
import CoreVideo
import Observation
import QuartzCore

/// Experimental directions along paths the phone has actually traversed.
/// This is not an obstacle-avoidance or accessibility mobility safety system.
@MainActor
@Observable
final class NavigationController {
    private(set) var graph = SavedNavigationGraph()
    private(set) var isRecording = false
    private(set) var routeActive = false
    private(set) var instruction = "Walk a path, then mark destinations along it."
    private(set) var state: NavigationState = .idle
    private(set) var remainingMeters: Float = 0
    private(set) var capacityReached = false
    var spokenDirections = true {
        didSet { if !spokenDirections, routeActive { speech?.stopAll() } }
    }
    var errorMessage: String?
    /// The app stops the other speech owner before the first route instruction.
    @ObservationIgnored var onRouteWillStart: (() -> Void)?

    @ObservationIgnored private unowned let manager: ARSessionManager
    @ObservationIgnored private var speech: SpeechCoordinator?
    @ObservationIgnored private var recorder = NavigationRecorder()
    @ObservationIgnored private var follower: NavigationFollower?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation: Int
    @ObservationIgnored private var requiresLocalization = false
    @ObservationIgnored private var lastSpeechTime: TimeInterval = 0
    @ObservationIgnored private var lastSpeechState: NavigationState = .idle
    @ObservationIgnored private var lastSpeechBucket = -1
    @ObservationIgnored private var restoredNodeIDs = Set<UUID>()

    init(manager: ARSessionManager, speech: SpeechCoordinator? = nil) {
        self.manager = manager; self.speech = speech; self.generation = manager.sessionGeneration
    }

    func configureSpeech(_ speech: SpeechCoordinator) { self.speech = speech }

    func startRecording() {
        guard task == nil else { return }
        isRecording = true
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.tick()
                do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            }
        }
    }

    /// Lifecycle pause preserves the graph and route, but breaks recording
    /// continuity. A resumed route must pass fresh tracking and path checks.
    func pause() {
        task?.cancel(); task = nil; isRecording = false
        recorder.breakContinuity()
        if routeActive {
            speech?.stopAll(); state = .paused
            instruction = "Directions paused. Resume scanning to locate the phone again."
        }
    }

    func beginNewPlace() {
        cancelNavigation()
        generation = manager.sessionGeneration; requiresLocalization = false
        recorder = NavigationRecorder(); restoredNodeIDs.removeAll()
        publishGraph(); errorMessage = nil
        instruction = "Walk a path, then mark destinations along it."
    }

    func restore(graph: SavedNavigationGraph?) {
        cancelNavigation()
        generation = manager.sessionGeneration; requiresLocalization = true
        do {
            try graph?.validate()
            recorder = NavigationRecorder(graph: graph ?? SavedNavigationGraph())
            restoredNodeIDs = Set(graph?.nodes.map(\.id) ?? [])
            errorMessage = nil
        } catch {
            recorder = NavigationRecorder(); restoredNodeIDs.removeAll()
            errorMessage = error.localizedDescription
        }
        publishGraph()
        instruction = "Look around to locate this saved place before navigating."
    }

    func graphForSaving() -> SavedNavigationGraph? {
        guard generation == manager.sessionGeneration, !graph.nodes.isEmpty else { return nil }
        return graph
    }

    func addLabel(name: String) {
        do {
            guard let pose = currentPose() else { throw NavigationError.noPose }
            try recorder.addLabel(name: name, pose: pose, now: CACurrentMediaTime())
            publishGraph(); errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    func navigate(to labelID: UUID) {
        // A new explicit destination replaces the old intent even when the
        // requested path cannot be established. Never keep speaking old turns.
        cancelNavigation()
        guard let label = graph.labels.first(where: { $0.id == labelID }) else {
            errorMessage = NavigationError.noRoute.localizedDescription; return
        }
        beginRoute(to: label.nodeID, name: label.name)
    }

    func navigateToStart() {
        cancelNavigation()
        guard let start = graph.startNodeID else {
            errorMessage = NavigationError.noRoute.localizedDescription; return
        }
        beginRoute(to: start, name: "the start of this path")
    }

    func cancelNavigation() {
        if routeActive { speech?.stopAll() }
        follower = nil; routeActive = false; state = .idle; remainingMeters = 0
        lastSpeechState = .idle; lastSpeechTime = 0; lastSpeechBucket = -1
        instruction = "Directions stopped. Path recording continues while scanning."
    }

    private func beginRoute(to destination: UUID, name: String) {
        do {
            guard let pose = currentPose() else { throw NavigationError.noPose }
            let start: UUID
            // On restore, starting on the saved path is an initial location
            // lookup only. It never connects the newly recorded component.
            if restoredNodeIDs.contains(destination) {
                var savedGraph = graph
                savedGraph.nodes = graph.nodes.filter { restoredNodeIDs.contains($0.id) }
                start = try NavigationRouter.startingNode(graph: savedGraph, pose: pose)
            } else {
                start = try NavigationRouter.startingNode(graph: graph, pose: pose,
                                                         preferredID: recorder.currentNodeID)
            }
            let route = try NavigationRouter.route(graph: graph, from: start, to: destination, name: name)
            onRouteWillStart?()
            follower = NavigationFollower(route: route); routeActive = true; errorMessage = nil
            lastSpeechState = .idle; lastSpeechTime = 0
            speech?.configureAudioIfNeeded()
            startRecording(); tick()
        } catch { errorMessage = error.localizedDescription }
    }

    private func tick() {
        guard generation == manager.sessionGeneration else {
            // A reset must never reuse coordinates from the previous AR world.
            beginNewPlace(); return
        }
        let now = CACurrentMediaTime()
        let frame = acceptedFrame(now: now)
        let pose = frame.flatMap { Self.pose(from: $0) }
        let changed = recorder.record(pose, now: now)
        if changed || capacityReached != recorder.capacityReached { publishGraph() }
        guard routeActive, var activeFollower = follower else { return }
        let obstruction = frame.map { Self.obstruction(in: $0) } ?? .unknown
        let update = activeFollower.update(pose: pose, now: now, obstruction: obstruction)
        follower = activeFollower
        instruction = update.text; state = update.state; remainingMeters = update.remainingMeters
        speak(update, now: now)
        if state == .arrived { routeActive = false; follower = nil }
    }

    private func publishGraph() {
        graph = recorder.graph; capacityReached = recorder.capacityReached
    }

    private func currentPose() -> NavigationPose? {
        acceptedFrame(now: CACurrentMediaTime()).flatMap { Self.pose(from: $0) }
    }

    private func acceptedFrame(now: TimeInterval) -> ARFrame? {
        guard generation == manager.sessionGeneration, manager.runState == .running,
              !manager.isRelocalizing, (!requiresLocalization || manager.hasLocalizedMap),
              let frame = manager.session.currentFrame,
              frame.timestamp == manager.lastFrameTimestamp,
              ARSensorProvider.isFresh(timestamp: frame.timestamp, now: now),
              case .normal = frame.camera.trackingState else { return nil }
        return frame
    }

    private static func pose(from frame: ARFrame) -> NavigationPose? {
        let transform = frame.camera.transform
        let forwardX = -transform.columns.2.x, forwardZ = -transform.columns.2.z
        guard hypot(forwardX, forwardZ) > 0.3 else { return nil }
        return NavigationPose(position: MapPosition(x: transform.columns.3.x,
            y: transform.columns.3.y, z: transform.columns.3.z),
            headingRadians: atan2(forwardX, -forwardZ), timestamp: frame.timestamp)
    }

    private static func obstruction(in frame: ARFrame) -> NavigationObstruction {
        guard let data = frame.smoothedSceneDepth ?? frame.sceneDepth,
              let confidence = data.confidenceMap else { return .unknown }
        let depth = data.depthMap
        let width = CVPixelBufferGetWidth(depth), height = CVPixelBufferGetHeight(depth)
        guard width > 0, height > 0, CVPixelBufferGetWidth(confidence) == width,
              CVPixelBufferGetHeight(confidence) == height,
              CVPixelBufferGetPixelFormatType(depth) == kCVPixelFormatType_DepthFloat32 else { return .unknown }
        guard CVPixelBufferLockBaseAddress(depth, .readOnly) == kCVReturnSuccess else { return .unknown }
        defer { CVPixelBufferUnlockBaseAddress(depth, .readOnly) }
        guard CVPixelBufferLockBaseAddress(confidence, .readOnly) == kCVReturnSuccess else { return .unknown }
        defer { CVPixelBufferUnlockBaseAddress(confidence, .readOnly) }
        guard let depthBase = CVPixelBufferGetBaseAddress(depth),
              let confidenceBase = CVPixelBufferGetBaseAddress(confidence) else { return .unknown }
        let depthStride = CVPixelBufferGetBytesPerRow(depth), confidenceStride = CVPixelBufferGetBytesPerRow(confidence)
        var depths: [Float] = [], qualities: [UInt8] = []
        // Only the camera's central forward area is sampled. Outside it and
        // beyond the sensor's observed range remain unknown.
        for y in stride(from: height / 4, to: height * 3 / 4, by: 4) {
            let row = depthBase.advanced(by: y * depthStride).assumingMemoryBound(to: Float32.self)
            let quality = confidenceBase.advanced(by: y * confidenceStride).assumingMemoryBound(to: UInt8.self)
            for x in stride(from: width * 35 / 100, to: width * 65 / 100, by: 4) {
                depths.append(row[x]); qualities.append(quality[x])
            }
        }
        return NavigationObstruction.classify(depths: depths, confidence: qualities)
    }

    private func speak(_ update: NavigationInstruction, now: TimeInterval) {
        guard spokenDirections else { return }
        let urgent = [NavigationState.trackingLost, .offRoute, .obstacle, .depthUnknown, .arrived].contains(update.state)
        let changed = update.state != lastSpeechState
        let bucket = Int(update.remainingMeters / 5)
        guard (changed && urgent) || (now - lastSpeechTime >= 6 && (changed || bucket != lastSpeechBucket)) else { return }
        speech?.speak(update.text, priority: urgent ? .high : .normal, minRepeat: 6)
        lastSpeechState = update.state; lastSpeechTime = now; lastSpeechBucket = bucket
    }
}
