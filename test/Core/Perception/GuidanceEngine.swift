//
//  GuidanceEngine.swift
//  test
//
//  Wearer Mode brain. Starts the shared perception pipeline (one ARSession),
//  turns proximity state into spoken + haptic warnings, and answers on-demand
//  "describe my surroundings" queries. Haptics fire via the ProximityEvaluator;
//  this adds speech and throttled announcement logic on top.
//
//  Experimental supplementary aid — NOT validated for independent navigation.
//

import Foundation
import ARKit
import Observation
import QuartzCore

@MainActor
@Observable
final class GuidanceEngine {
    enum Verbosity: String, CaseIterable, Identifiable {
        case quiet = "Quiet", normal = "Normal", verbose = "Verbose"
        var id: String { rawValue }
    }

    var verbosity: Verbosity = .normal
    @ObservationIgnored var onWillStart: (() -> Void)?
    @ObservationIgnored var activatePipelines: (() -> Void)?
    @ObservationIgnored var deactivatePipelines: (() -> Void)?
    private(set) var running = false
    private(set) var statusText = "Stopped"
    private(set) var navigationOwnsSpeech = false
    private(set) var foregroundActive = true
    var canSpeak: Bool { foregroundActive && !navigationOwnsSpeech }

    private unowned let speech: SpeechCoordinator
    private unowned let haptics: HapticCoordinator
    let spatialCue: SpatialCueCoordinator
    private unowned let proximity: ProximityEvaluator
    private unowned let proximityDriver: ProximityDriver
    private unowned let spatial: SpatialAlgorithmsEngine
    private unowned let fusion: SpatialFusionEngine
    private unowned let vision: VisionInferenceEngine
    private unowned let hazardMap: WorldHazardMap
    private weak var ar: ARSessionManager?

    private var loopTask: Task<Void, Never>?
    private var lastState: ProximityState = .clear
    private var lastRegion: SpatialRegion?
    private var lastLabel: String?
    private var lastCriticalRepeat: TimeInterval = 0
    private var lastHazardAnnouncement: TimeInterval = 0
    private var recoveryAnnouncements = AlertRecoveryAnnouncements()

    /// Manual Haptics Lab samples can share the diagnostic evaluator, but they
    /// must never be presented as observations from the live camera.
    var liveProximityEvent: ProximityEvent? {
        guard let event = proximity.lastEvent, !event.isSimulated else { return nil }
        return event
    }

    init(speech: SpeechCoordinator, haptics: HapticCoordinator,
         spatialCue: SpatialCueCoordinator, proximity: ProximityEvaluator,
         proximityDriver: ProximityDriver, spatial: SpatialAlgorithmsEngine,
         fusion: SpatialFusionEngine, vision: VisionInferenceEngine, hazardMap: WorldHazardMap) {
        self.speech = speech
        self.haptics = haptics
        self.spatialCue = spatialCue
        self.proximity = proximity
        self.proximityDriver = proximityDriver
        self.spatial = spatial
        self.fusion = fusion
        self.vision = vision
        self.hazardMap = hazardMap
    }

    func attach(ar: ARSessionManager) { self.ar = ar }

    // MARK: - Lifecycle

    func start() {
        guard !running else { return }
        onWillStart?()
        running = true
        speech.configureAudioIfNeeded()
        ar?.start()
        activatePipelines?()
        statusText = "Running"
        lastState = .clear
        lastRegion = nil
        lastLabel = nil
        lastHazardAnnouncement = 0
        recoveryAnnouncements = AlertRecoveryAnnouncements()
        if canSpeak { speech.speak("Guidance started.", priority: .high) }
        loopTask = Task { [weak self] in await self?.loop() }
    }

    func stop() {
        guard running else { return }
        running = false
        loopTask?.cancel(); loopTask = nil
        // Another consumer may have joined after guidance started. The shared
        // demand coordinator stops only pipelines that nobody still needs.
        deactivatePipelines?()
        // Keep the single ARSession RUNNING — pausing/resuming it churns the camera
        // capture source (FigCaptureSourceRemote errors). Only background pauses it.
        statusText = "Stopped"
        if canSpeak { speech.speak("Guidance stopped.", priority: .high) }
    }

    func toggle() { running ? stop() : start() }

    /// Speech ownership is independent of live inference and haptic feedback.
    func setNavigationSpeechActive(_ active: Bool) {
        navigationOwnsSpeech = active
        updateSuspensionStatus()
    }

    func setForegroundActive(_ active: Bool) {
        foregroundActive = active
        updateSuspensionStatus()
    }

    private func updateSuspensionStatus() {
        guard running else { return }
        if !foregroundActive { statusText = "Paused while app is inactive" }
        else if navigationOwnsSpeech { statusText = "Route directions speaking · proximity feedback remains active" }
        else { statusText = "Running"; lastState = .uncertain }
    }

    // MARK: - Announcement loop

    private func loop() async {
        while !Task.isCancelled && running {
            announce()
            try? await Task.sleep(for: .milliseconds(400))
        }
    }

    private func announce() {
        guard canSpeak else { updateSuspensionStatus(); return }
        let cameraCurrent = ar.flatMap { manager in
            manager.session.currentFrame.map { manager.isCurrentFrame($0) }
        } ?? false
        let available = cameraCurrent && proximityDriver.inputStatus.hasCurrentMeasurements
        if let change = recoveryAnnouncements.update(available: available) {
            lastState = .uncertain; lastRegion = nil; lastLabel = nil
            switch change {
            case .unavailable:
                speech.speak("Sensor data is unavailable. Alerts will resume automatically when fresh data returns.",
                             priority: .high, minRepeat: 8)
            case .resumed:
                speech.speak("Live sensor alerts resumed.", minRepeat: 8)
            }
        }
        guard available else {
            statusText = cameraCurrent ? proximityDriver.statusText : AlertInputStatus.waitingForCamera.message
            return
        }
        guard let event = liveProximityEvent else {
            statusText = "Waiting for live proximity data"; return
        }
        let state = event.state
        let distance = event.distanceMeters
        let region = event.region
        let label = event.triggeringLabel
        let now = CACurrentMediaTime()
        statusText = "\(proximityDriver.statusText) — \(state.rawValue)"
        // Bearing can wobble between adjacent buckets while the user turns. A
        // side-direction change is meaningful, but only after a quiet window; label
        // changes remain immediate because they usually indicate a new object.
        let regionChanged = region != lastRegion
        let hazardChanged = label != lastLabel
            || (regionChanged && now - lastHazardAnnouncement >= 4.0)
        let canAnnounceHazard = now - lastHazardAnnouncement >= 1.0

        // The continuous haptic/audio cue is handled by FeedbackCoordinator. Speech
        // is event-oriented: announce a new side/object, not every sensor frame.
        switch state {
        case .critical:
            if state != lastState || now - lastCriticalRepeat > 2 {
                speech.speak("Stop. Very close \(direction(region)), \(distancePhrase(distance)).",
                             priority: .high, minRepeat: 1.2)
                lastCriticalRepeat = now
                lastHazardAnnouncement = now
            }
        case .near:
            if (state != lastState || hazardChanged) && canAnnounceHazard {
                let name = label ?? "obstacle"
                speech.speak("\(name.capitalized) \(direction(region)), \(distancePhrase(distance)).",
                             priority: .high, minRepeat: 1.8)
                lastHazardAnnouncement = now
            }
        case .caution:
            if (state != lastState || hazardChanged) && canAnnounceHazard && verbosity != .quiet {
                let name = label ?? "object"
                let verb = region == .left || region == .right ? "Passing" : "Ahead"
                speech.speak("\(verb): \(name), \(direction(region)), \(distancePhrase(distance)).",
                             minRepeat: 3)
                lastHazardAnnouncement = now
            }
        case .uncertain:
            if state != lastState, verbosity != .quiet {
                speech.speak("Sensor unsure of what's ahead.", minRepeat: 5)
            }
        case .clear:
            if lastState != .clear, lastState != .uncertain, verbosity != .quiet {
                speech.speak("No nearby obstacle detected in the observed area.", minRepeat: 4)
            }
        }
        lastState = state
        lastRegion = region
        lastLabel = label
    }

    // MARK: - On-demand description

    func describeSurroundings() {
        guard canSpeak else { updateSuspensionStatus(); return }
        guard running else {
            speech.speak("Start guidance first.", priority: .high)
            return
        }
        guard let ar, let frame = ar.session.currentFrame, ar.isCurrentFrame(frame),
              proximityDriver.inputStatus.hasCurrentMeasurements else {
            speech.speak("Current sensor data is unavailable. Alerts will resume automatically.", priority: .high)
            return
        }
        guard ar.isCurrentWorldFrame(frame) else {
            if let event = liveProximityEvent, let distance = event.distanceMeters, distance < 10 {
                speech.speak("Map tracking is recovering. Current depth detects an obstacle \(direction(event.region)), \(distancePhrase(distance)).",
                             priority: .high, minRepeat: 0)
            } else {
                speech.speak("Map tracking is recovering. I cannot describe the surrounding area yet.", priority: .high)
            }
            return
        }
        var parts: [String] = []

        // Side-aware summary from the persistent world hazard map (covers things
        // already panned past / out of the current FOV).
        for region in [SpatialRegion.left, .center, .right] {
            let name = describeRegionName(region)
            if let zone = hazardMap.zones.first(where: { $0.region == region }) {
                let label = zone.label ?? "obstacle"
                parts.append("\(name): \(label) at \(distancePhrase(zone.distance))")
            } else {
                parts.append("\(name): no confirmed observation")
            }
        }

        let sentence = hazardMap.hazards.isEmpty
            ? "I don't have enough information yet. Please pan slowly left and right."
            : parts.joined(separator: ". ") + "."
        speech.speak(sentence, priority: .high, minRepeat: 0)
    }

    // MARK: - Phrasing

    private func direction(_ region: SpatialRegion?) -> String {
        switch region {
        case .left: return "on your left"
        case .right: return "on your right"
        case .center, .none: return "ahead"
        }
    }

    private func describeRegionName(_ region: SpatialRegion) -> String {
        switch region {
        case .left: return "Left"
        case .center: return "Ahead"
        case .right: return "Right"
        }
    }

    private func distancePhrase(_ meters: Float?) -> String {
        guard let m = meters, m.isFinite else { return "unknown distance" }
        if m < 1 { return "less than one meter" }
        return "\(Int(m.rounded())) meters"
    }
}
