//
//  NavigationEngine.swift
//  test
//
//  Wearer Mode runtime. ONE loop, one tick per new LiDAR frame (~10 Hz):
//
//    ARFrame → world points → floor → ObstacleMap → PathScanner → AlertPolicy → haptics / speech
//
//  It replaces the old chain of five independently polling loops (fusion,
//  spatial, hazard map, proximity driver, guidance) whose sleeps stacked up to
//  ~0.5 s of extra delay between the sensor and the vibration. The YOLO detector
//  only supplies a word for speech ("chair"); it never decides an alert.
//
//  Experimental supplementary aid — NOT validated for independent navigation.
//

import Foundation
import Observation
import QuartzCore
import simd
import UIKit

/// One alert-level or sensing change, for the debug views and the Inspector log.
struct AlertTransition: Identifiable {
    let id = UUID()
    let at: TimeInterval
    let level: AlertLevel
    let sensing: SensingStatus
    let obstacle: PathObstacle?
    let spoken: String?
    let captureToDecisionMs: Double?
}

@MainActor
@Observable
final class NavigationEngine {
    var profile = NavigationProfile()
    /// Run the object detector so speech can name things ("chair"). Costs battery/heat.
    var identifyObjects = true

    private(set) var running = false
    private(set) var sensing: SensingStatus = .noDepth
    private(set) var decision = AlertDecision(level: .clear, obstacle: nil, haptic: nil, speech: nil)
    private(set) var assessment: PathAssessment?
    private(set) var map = ObstacleMap()
    private(set) var user: UserFrame?
    private(set) var speed: Float = 0
    private(set) var aheadLabel: String?
    private(set) var lastSpoken = ""
    private(set) var computeMs: Double?
    private(set) var captureToDecisionMs: Double?
    private(set) var transitions: [AlertTransition] = []

    static let tickInterval = 0.1
    static let maxTransitions = 50

    private unowned let haptics: HapticCoordinator
    private unowned let speech: SpeechCoordinator
    private unowned let vision: VisionInferenceEngine
    private unowned let fusion: SpatialFusionEngine
    private weak var provider: ARSensorProvider?
    private weak var ar: ARSessionManager?

    @ObservationIgnored private var policy = AlertPolicy()
    @ObservationIgnored private var loopTask: Task<Void, Never>?
    @ObservationIgnored private var lastFrameTimestamp: TimeInterval = -1
    @ObservationIgnored private var lastPosition: SIMD3<Float>?
    @ObservationIgnored private var lastPositionTime: TimeInterval = 0
    @ObservationIgnored private var ownsDetector = false

    init(haptics: HapticCoordinator, speech: SpeechCoordinator,
         vision: VisionInferenceEngine, fusion: SpatialFusionEngine) {
        self.haptics = haptics
        self.speech = speech
        self.vision = vision
        self.fusion = fusion
    }

    func attach(provider: ARSensorProvider, ar: ARSessionManager) {
        self.provider = provider
        self.ar = ar
    }

    // MARK: - Lifecycle

    func start() {
        guard !running, let ar else { return }
        running = true
        // Guidance needs the camera, and iOS stops the camera when the screen locks.
        UIApplication.shared.isIdleTimerDisabled = true
        speech.configureAudioIfNeeded()
        if ar.runState != .running { ar.start() }
        if identifyObjects && !vision.isEnabled {
            vision.targetHz = 6
            vision.start()
            fusion.start()
            ownsDetector = true
        }
        resetState()
        speech.speak("Guidance started. Hold the phone upright at chest height.", priority: .high, minRepeat: 0)
        loopTask = Task { [weak self] in await self?.loop() }
    }

    func stop() {
        guard running else { return }
        running = false
        loopTask?.cancel(); loopTask = nil
        UIApplication.shared.isIdleTimerDisabled = false
        if ownsDetector {
            fusion.stop()
            vision.stop()
            ownsDetector = false
        }
        resetState()
        speech.speak("Guidance stopped.", priority: .high, minRepeat: 0)
    }

    func toggle() { running ? stop() : start() }

    func describeSurroundings() {
        guard running else {
            speech.speak("Start guidance first.", priority: .high, minRepeat: 0)
            return
        }
        let text = SurroundingsDescriber.describe(sensing: sensing, assessment: assessment, aheadLabel: aheadLabel)
        speech.speak(text, priority: .high, minRepeat: 0)
        lastSpoken = text
    }

    private func resetState() {
        policy.reset()
        map.reset()
        sensing = .noDepth
        decision = AlertDecision(level: .clear, obstacle: nil, haptic: nil, speech: nil)
        assessment = nil
        user = nil
        speed = 0
        aheadLabel = nil
        lastFrameTimestamp = -1
        lastPosition = nil
    }

    // MARK: - Loop

    private func loop() async {
        while !Task.isCancelled && running {
            let started = CACurrentMediaTime()
            await tick()
            let elapsed = CACurrentMediaTime() - started
            try? await Task.sleep(for: .seconds(max(0.01, Self.tickInterval - elapsed)))
        }
    }

    private func tick() async {
        let now = CACurrentMediaTime()
        guard let provider, provider.isRunning, let frame = provider.snapshot(),
              let depthMap = frame.depthMap else {
            apply(.noDepth, now: now, frameTimestamp: nil)
            return
        }
        guard frame.timestamp != lastFrameTimestamp else { return }
        lastFrameTimestamp = frame.timestamp

        guard frame.trackingIsNormal else {
            // Poses may jump while tracking is limited: the map would be wrong.
            map.reset()
            lastPosition = nil
            speed = 0
            apply(.trackingLimited, now: now, frameTimestamp: frame.timestamp)
            return
        }
        guard let user = UserFrame(cameraTransform: frame.cameraTransform) else {
            apply(.phoneNotUpright, now: now, frameTimestamp: frame.timestamp)
            return
        }
        updateSpeed(user: user, timestamp: frame.timestamp)

        let started = CACurrentMediaTime()
        let result = await Self.process(frame: frame, depthMap: depthMap, map: map, user: user)
        guard running else { return }
        computeMs = (CACurrentMediaTime() - started) * 1000
        map = result.map
        self.user = user

        guard map.floorY != nil else {
            apply(.findingFloor, now: CACurrentMediaTime(), frameTimestamp: frame.timestamp)
            return
        }
        assessment = result.assessment
        aheadLabel = label(near: result.assessment.ahead)
        apply(.ok, now: CACurrentMediaTime(), frameTimestamp: frame.timestamp)
    }

    /// Forward walking speed from successive camera positions on the floor plane.
    private func updateSpeed(user: UserFrame, timestamp: TimeInterval) {
        defer { lastPosition = user.position; lastPositionTime = timestamp }
        guard let last = lastPosition, timestamp > lastPositionTime else { return }
        let dt = Float(timestamp - lastPositionTime)
        let delta = SIMD2<Float>(user.position.x - last.x, user.position.z - last.z)
        let forwardSpeed = max(0, simd_dot(delta, user.forward) / dt)
        speed = 0.7 * speed + 0.3 * forwardSpeed
    }

    nonisolated private static func process(frame: SensorFrame, depthMap: CVPixelBuffer,
                                            map: ObstacleMap, user: UserFrame) async
        -> (map: ObstacleMap, assessment: PathAssessment) {
        await Task.detached(priority: .userInitiated) {
            var updated = map
            let projection = CameraProjection(
                intrinsics: frame.intrinsics, imageResolution: frame.imageResolution,
                depthWidth: CVPixelBufferGetWidth(depthMap), depthHeight: CVPixelBufferGetHeight(depthMap),
                cameraTransform: frame.cameraTransform)
            let points = DepthSampler.worldPoints(depthMap: depthMap, confidenceMap: frame.confidenceMap,
                                                  projection: projection)
            if let floorY = FloorEstimator.floorY(points: points, camera: user.position) {
                updated.updateFloor(y: floorY)
            }
            if updated.floorY != nil {
                updated.integrate(points: points, user: user.position, now: frame.timestamp,
                                  isVisible: projection.isVisible)
            }
            return (updated, PathScanner.assess(map: updated, user: user))
        }.value
    }

    /// The detector's word for the obstacle ahead: a confident fused detection whose
    /// world position is within 0.6 m of the obstacle cell.
    private func label(near obstacle: PathObstacle?) -> String? {
        guard identifyObjects, let obstacle else { return nil }
        var best: (label: String, distance: Float)?
        for obs in fusion.observations where !obs.uncertain {
            guard let w = obs.positionWorld else { continue }
            let d = simd_distance(SIMD2<Float>(w.x, w.z), obstacle.cellCenter)
            if d < 0.6, d < (best?.distance ?? .greatestFiniteMagnitude) { best = (obs.label, d) }
        }
        return best?.label
    }

    // MARK: - Decide and output

    private func apply(_ status: SensingStatus, now: TimeInterval, frameTimestamp: TimeInterval?) {
        sensing = status
        if status != .ok {
            assessment = nil
            aheadLabel = nil
        }
        policy.profile = profile
        let next = policy.decide(AlertInput(
            now: now, sensing: status, ahead: assessment?.ahead, speed: speed,
            openings: assessment?.openings ?? [], label: aheadLabel))
        captureToDecisionMs = frameTimestamp.map { (CACurrentMediaTime() - $0) * 1000 }

        if let cue = next.haptic { haptics.play(cue) }
        if let utterance = next.speech {
            speech.speak(utterance.text, priority: utterance.interrupt ? .high : .normal, minRepeat: 0)
            lastSpoken = utterance.text
        }
        let previousSensing = transitions.first?.sensing
        if next.level != decision.level || status != previousSensing {
            transitions.insert(AlertTransition(at: now, level: next.level, sensing: status,
                                               obstacle: next.obstacle, spoken: next.speech?.text,
                                               captureToDecisionMs: captureToDecisionMs), at: 0)
            if transitions.count > Self.maxTransitions {
                transitions.removeLast(transitions.count - Self.maxTransitions)
            }
        }
        decision = next
    }
}
