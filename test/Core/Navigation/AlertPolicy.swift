//
//  AlertPolicy.swift
//  test
//
//  Every "should the user feel or hear something now?" decision lives here, as a
//  pure state machine fed one tick at a time. It is the place to change behaviour
//  after testing with blind users; nothing else in the app decides alerts.
//
//  The rules, and why:
//   1. Only the walking corridor alerts. A wall beside you is not a collision, and
//      unnecessary alerts slow cane users down without reducing collisions.
//   2. Cane users (default) get at most a gentle notice for ground obstacles: the
//      cane finds those. Full escalation and speech are reserved for obstacles
//      the cane passes under (bottom edge above 0.686 m, the ADA cane-sweep line).
//   3. Haptics carry the continuous signal (they work in noise and do not mask
//      traffic sounds). Three discrete levels, cadence + strength rise together;
//      one tap = ground, double tap = overhanging, long soft buzz = cannot see.
//   4. Speech is rare and specific: an overhanging obstacle, a stop, a blocked
//      path with a clearer side, or sensing lost/regained. Never "clear".
//   5. Standing still: no continuous pulses, only a single pulse when the level
//      rises. Walking: time-to-contact at the current speed can raise the level.
//   6. Losing the sensor is never silent and never reported as "clear".
//

import simd

nonisolated enum AlertLevel: Int, Comparable, CaseIterable, Sendable {
    case clear, notice, warning, stop

    static func < (a: AlertLevel, b: AlertLevel) -> Bool { a.rawValue < b.rawValue }

    var title: String {
        switch self {
        case .clear: return "CLEAR"
        case .notice: return "NOTICE"
        case .warning: return "WARNING"
        case .stop: return "STOP"
        }
    }
}

nonisolated enum SensingStatus: String, Sendable {
    case ok = "Sensing"
    case noDepth = "No LiDAR depth"
    case trackingLimited = "Tracking limited"
    case findingFloor = "Finding floor"
    case phoneNotUpright = "Phone not upright"

    var spokenWarning: String {
        switch self {
        case .ok: return ""
        case .noDepth: return "Sensor can't see. Slow down."
        case .trackingLimited: return "Tracking lost. Slow down and move the phone slowly."
        case .findingFloor: return "Finding the floor. Tilt the phone a little lower."
        case .phoneNotUpright: return "Hold the phone upright, facing ahead."
        }
    }
}

nonisolated struct NavigationProfile: Equatable, Sendable {
    /// Ground obstacles stay at NOTICE: the long cane detects them.
    var caneUser = true
    var speech = true
    var haptics = true
}

nonisolated struct AlertThresholds: Equatable, Sendable {
    var noticeDistance: Float = 3.0
    var warningDistance: Float = 1.8
    var stopDistance: Float = 1.0
    /// Time-to-contact tiers in seconds, used only while walking.
    var noticeTTC: Float = 4.0
    var warningTTC: Float = 2.5
    var stopTTC: Float = 1.2
    /// Below this forward speed (m/s) the user counts as standing still.
    var walkingSpeed: Float = 0.3
    /// A lower level must hold this long before the alert steps down.
    var releaseSeconds: Double = 0.6
    /// Sensing must be lost this long before the user is told.
    var sensingGraceSeconds: Double = 1.0
    /// After an announcement, a different obstacle at the same level waits this long.
    var repeatSpeechSeconds: Double = 6
}

nonisolated struct HapticCue: Equatable, Sendable {
    nonisolated enum Texture: String, Sendable { case tap, doubleTap, buzz }
    var texture: Texture
    var intensity: Float
    var sharpness: Float

    /// The pulse for an obstacle at `level`; nil for `.clear`.
    static func obstacle(_ kind: ObstacleKind, level: AlertLevel) -> HapticCue? {
        let texture: Texture = kind == .overhead ? .doubleTap : .tap
        switch level {
        case .clear: return nil
        case .notice: return HapticCue(texture: texture, intensity: 0.4, sharpness: 0.3)
        case .warning: return HapticCue(texture: texture, intensity: 0.7, sharpness: 0.6)
        case .stop: return HapticCue(texture: texture, intensity: 1.0, sharpness: 0.9)
        }
    }

    static let sensingLost = HapticCue(texture: .buzz, intensity: 0.5, sharpness: 0.1)

    /// Seconds between pulses while walking.
    static func interval(for level: AlertLevel) -> Double {
        switch level {
        case .clear: return .infinity
        case .notice: return 1.2
        case .warning: return 0.5
        case .stop: return 0.18
        }
    }
}

nonisolated struct Utterance: Equatable, Sendable {
    var text: String
    /// Cut off whatever is being spoken.
    var interrupt: Bool
}

nonisolated struct AlertInput: Sendable {
    var now: Double
    var sensing: SensingStatus
    var ahead: PathObstacle?
    /// Walking speed along the heading, m/s, never negative.
    var speed: Float
    var openings: [Opening]
    /// Object class for the obstacle ahead, if the detector recognised one. Only
    /// ever changes wording; geometry alone decides the level.
    var label: String?
}

nonisolated struct AlertDecision: Equatable, Sendable {
    var level: AlertLevel
    var obstacle: PathObstacle?
    var haptic: HapticCue?
    var speech: Utterance?
}

nonisolated struct AlertPolicy: Sendable {
    var profile: NavigationProfile
    var thresholds: AlertThresholds

    private(set) var level: AlertLevel = .clear
    private var heldObstacle: PathObstacle?
    private var belowSince: Double?
    private var lastPulse: Double = -.infinity
    private var lastAnnouncedCell: SIMD2<Float>?
    private var lastAnnouncedLevel: AlertLevel = .clear
    private var lastAnnouncedAt: Double = -.infinity
    private var sensingLostSince: Double?
    private var announcedSensingLoss = false
    private var lastSensingBuzz: Double = -.infinity

    init(profile: NavigationProfile = NavigationProfile(), thresholds: AlertThresholds = AlertThresholds()) {
        self.profile = profile
        self.thresholds = thresholds
    }

    mutating func reset() {
        self = AlertPolicy(profile: profile, thresholds: thresholds)
    }

    mutating func decide(_ input: AlertInput) -> AlertDecision {
        guard input.sensing == .ok else { return sensingLost(input) }

        var speech: Utterance?
        if announcedSensingLoss && profile.speech {
            speech = Utterance(text: "Sensing again.", interrupt: false)
        }
        sensingLostSince = nil
        announcedSensingLoss = false

        let previous = level
        let target = targetLevel(input)
        if target >= level {
            level = target
            belowSince = nil
        } else if let since = belowSince {
            if input.now - since >= thresholds.releaseSeconds {
                level = target
                belowSince = nil
            }
        } else {
            belowSince = input.now
        }

        if let ahead = input.ahead { heldObstacle = ahead }
        if level == .clear {
            heldObstacle = nil
            lastAnnouncedCell = nil
            lastAnnouncedLevel = .clear
        }
        guard let obstacle = heldObstacle else {
            return AlertDecision(level: level, obstacle: nil, haptic: nil, speech: speech)
        }

        let haptic = pulse(for: obstacle, escalated: level > previous, input: input)
        if let announcement = announcement(for: obstacle, escalated: level > previous, input: input) {
            speech = announcement
        }
        return AlertDecision(level: level, obstacle: obstacle, haptic: haptic, speech: speech)
    }

    // MARK: - Level

    func targetLevel(_ input: AlertInput) -> AlertLevel {
        guard let ahead = input.ahead else { return .clear }
        var target = Self.tier(ahead.distance, notice: thresholds.noticeDistance,
                               warning: thresholds.warningDistance, stop: thresholds.stopDistance)
        if input.speed >= thresholds.walkingSpeed {
            let ttc = ahead.distance / input.speed
            target = max(target, Self.tier(ttc, notice: thresholds.noticeTTC,
                                           warning: thresholds.warningTTC, stop: thresholds.stopTTC))
        }
        if profile.caneUser && ahead.kind == .ground {
            target = min(target, .notice)
        }
        return target
    }

    private static func tier(_ value: Float, notice: Float, warning: Float, stop: Float) -> AlertLevel {
        if value <= stop { return .stop }
        if value <= warning { return .warning }
        if value <= notice { return .notice }
        return .clear
    }

    // MARK: - Haptics

    private mutating func pulse(for obstacle: PathObstacle, escalated: Bool, input: AlertInput) -> HapticCue? {
        guard profile.haptics, level > .clear else { return nil }
        let walking = input.speed >= thresholds.walkingSpeed
        guard escalated || (walking && input.now - lastPulse >= HapticCue.interval(for: level)) else { return nil }
        lastPulse = input.now
        return HapticCue.obstacle(obstacle.kind, level: level)
    }

    // MARK: - Speech

    private mutating func announcement(for obstacle: PathObstacle, escalated: Bool,
                                       input: AlertInput) -> Utterance? {
        guard profile.speech, level >= .warning else { return nil }
        let sameObstacle = lastAnnouncedCell.map { simd_distance($0, obstacle.cellCenter) < 0.75 } ?? false
        if sameObstacle {
            // The same obstacle is only re-announced when it gets more urgent.
            guard level > lastAnnouncedLevel else { return nil }
        } else {
            // A different obstacle at the same level waits out the repeat window.
            guard escalated || input.now - lastAnnouncedAt >= thresholds.repeatSpeechSeconds else { return nil }
        }

        lastAnnouncedCell = obstacle.cellCenter
        lastAnnouncedLevel = level
        lastAnnouncedAt = input.now

        let name = Self.name(of: obstacle, label: input.label)
        var text = level == .stop
            ? "Stop. \(name), \(Self.distancePhrase(obstacle.distance))."
            : "\(name) ahead, \(Self.distancePhrase(obstacle.distance))."
        if let side = Self.clearerSide(input.openings) {
            text += " Clearer to your \(side)."
        }
        return Utterance(text: text, interrupt: level == .stop)
    }

    static func name(of obstacle: PathObstacle, label: String?) -> String {
        guard obstacle.kind == .overhead else {
            return label.map { $0.prefix(1).uppercased() + String($0.dropFirst()) } ?? "Obstacle"
        }
        // Adult shoulders sit near 1.4 m: anything whose bottom edge is higher hits the head.
        let height: String
        if obstacle.bottom >= 1.4 { height = "Head height" }
        else if obstacle.bottom >= 1.0 { height = "Chest height" }
        else { height = "Waist height" }
        return "\(height) \(label ?? "obstacle")"
    }

    static func distancePhrase(_ meters: Float) -> String {
        if meters < 1 { return "less than 1 meter" }
        let m = Int(meters.rounded())
        return m == 1 ? "1 meter" : "\(m) meters"
    }

    /// The side with an observed free stretch of at least 2 m, if the path ahead is
    /// shorter than that. Never points into unexplored space.
    static func clearerSide(_ openings: [Opening]) -> String? {
        let ahead = openings.first { $0.bearingDegrees == 0 }?.freeMeters ?? 0
        let best = openings
            .filter { abs($0.bearingDegrees) >= 20 && $0.freeMeters >= 2 && $0.freeMeters > ahead + 0.5 }
            .max { $0.freeMeters < $1.freeMeters }
        guard let best else { return nil }
        return best.bearingDegrees < 0 ? "left" : "right"
    }

    // MARK: - Sensing lost

    private mutating func sensingLost(_ input: AlertInput) -> AlertDecision {
        level = .clear
        heldObstacle = nil
        belowSince = nil
        let since = sensingLostSince ?? input.now
        sensingLostSince = since
        guard input.now - since >= thresholds.sensingGraceSeconds else {
            return AlertDecision(level: .clear, obstacle: nil, haptic: nil, speech: nil)
        }

        var speech: Utterance?
        if !announcedSensingLoss {
            announcedSensingLoss = true
            if profile.speech { speech = Utterance(text: input.sensing.spokenWarning, interrupt: true) }
        }
        var haptic: HapticCue?
        if profile.haptics && input.now - lastSensingBuzz >= 4 {
            lastSensingBuzz = input.now
            haptic = .sensingLost
        }
        return AlertDecision(level: .clear, obstacle: nil, haptic: haptic, speech: speech)
    }
}
