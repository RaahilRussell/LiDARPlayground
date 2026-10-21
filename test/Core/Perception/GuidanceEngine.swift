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
    private(set) var running = false
    private(set) var statusText = "Stopped"

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
        vision.targetHz = 6          // modest rate — thermal/battery friendly
        vision.start()
        spatial.start()
        fusion.start()
        proximityDriver.demoMode = false
        proximityDriver.source = .fusedObjects   // object-aware alerts, geometry fallback
        proximityDriver.running = true
        proximityDriver.start()
        statusText = "Running"
        lastState = .clear
        lastRegion = nil
        lastLabel = nil
        lastHazardAnnouncement = 0
        speech.speak("Guidance started.", priority: .high)
        loopTask = Task { [weak self] in await self?.loop() }
    }

    func stop() {
        guard running else { return }
        running = false
        loopTask?.cancel(); loopTask = nil
        proximityDriver.stop()
        fusion.stop()
        spatial.stop()
        vision.stop()
        proximity.reset()
        // Keep the single ARSession RUNNING — pausing/resuming it churns the camera
        // capture source (FigCaptureSourceRemote errors). Only background pauses it.
        statusText = "Stopped"
        speech.speak("Guidance stopped.", priority: .high)
    }

    func toggle() { running ? stop() : start() }

    // MARK: - Announcement loop

    private func loop() async {
        while !Task.isCancelled && running {
            announce()
            try? await Task.sleep(for: .milliseconds(400))
        }
    }

    private func announce() {
        guard ar?.runState == .running else { statusText = "Sensing paused"; return }
        let state = proximity.currentState
        let event = proximity.lastEvent
        let distance = event?.distanceMeters
        let region = event?.region
        let label = event?.triggeringLabel
        let height = event?.obstacleHeight
        let now = CACurrentMediaTime()
        statusText = "Running — \(state.rawValue)"
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
                let name = label ?? height?.spokenName ?? "obstacle"
                speech.speak("\(name.capitalized) \(direction(region)), \(distancePhrase(distance)).",
                             priority: .high, minRepeat: 1.8)
                lastHazardAnnouncement = now
            }
        case .caution:
            if (state != lastState || hazardChanged) && canAnnounceHazard && verbosity != .quiet {
                let name = label ?? height?.spokenName ?? "object"
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
                speech.speak("Clear.", minRepeat: 4)
            }
        }
        lastState = state
        lastRegion = region
        lastLabel = label
    }

    // MARK: - On-demand description

    func describeSurroundings() {
        guard running else {
            speech.speak("Start guidance first.", priority: .high)
            return
        }
        guard ar?.runState == .running, ar?.trackingIsNormal == true,
              ar?.isRelocalizing == false else {
            speech.speak("Sensor tracking is unavailable. Please wait for tracking to recover.", priority: .high)
            return
        }
        var parts: [String] = []

        // Side-aware summary from the persistent world hazard map (covers things
        // already panned past / out of the current FOV).
        for region in [SpatialRegion.left, .center, .right] {
            let name = describeRegionName(region)
            if let zone = hazardMap.zones.first(where: { $0.region == region }) {
                let label = zone.label ?? "obstacle"
                parts.append("\(name): \(label), \(zone.height.spokenName) at \(distancePhrase(zone.distance))")
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
