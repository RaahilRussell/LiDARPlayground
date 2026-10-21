//
//  ProximityEvaluator.swift
//  test
//
//  Phase 5/6 — experimental proximity state machine driven by GEOMETRY + its
//  confidence (never by class labels alone). CLEAR/CAUTION/NEAR/CRITICAL/UNCERTAIN
//  with hysteresis + cooldown to prevent oscillation. Thresholds are configurable
//  for controlled testing — they are NOT assumed safety standards. The decision
//  logic itself lives in ProximityStateMachine (pure, fixture-tested).
//

import Foundation
import Observation
import QuartzCore

@MainActor
@Observable
final class ProximityEvaluator {
    // Configurable test thresholds (metres). Not safety-certified.
    var criticalDistance: Float = 0.5
    var nearDistance: Float = 1.0
    var cautionDistance: Float = 2.0
    var hysteresis: Float = 0.15
    var minConfidence: Float = 0.4

    private(set) var currentState: ProximityState = .clear
    private(set) var lastEvent: ProximityEvent?
    private(set) var recentEvents: [ProximityEvent] = []

    private unowned let haptics: HapticCoordinator
    private var machine = ProximityStateMachine()
    private var stateEnteredAt: TimeInterval = 0

    /// Bound on `recentEvents` so the inspector history never grows unbounded.
    static let maxRecentEvents = 50

    init(haptics: HapticCoordinator) { self.haptics = haptics }

    /// Evaluate one proximity input. `nearest`/`confidence` come from geometry.
    @discardableResult
    func evaluate(nearest: Float?, confidence: Float?, region: SpatialRegion?,
                  label: String?, isSimulated: Bool, inputTimestamp: TimeInterval,
                  ttc: Float? = nil, bearing: Float? = nil, inPath: Bool = true) -> ProximityEvent {
        let decidedAt = CACurrentMediaTime()

        // Decide target state (pure logic lives in ProximityStateMachine).
        machine.thresholds = ProximityThresholds(
            criticalDistance: criticalDistance, nearDistance: nearDistance,
            cautionDistance: cautionDistance, hysteresis: hysteresis, minConfidence: minConfidence)
        if machine.step(nearest: nearest, confidence: confidence, ttc: ttc, inPath: inPath) {
            stateEnteredAt = decidedAt
        }
        currentState = machine.state

        // The pattern is recorded for the inspector; the actual graded haptic +
        // audio output is produced continuously by FeedbackCoordinator.
        let pattern = Self.pattern(for: currentState)
        let enqueuedAt: TimeInterval? = nil
        _ = haptics   // ownership kept for API compatibility; feedback is centralized

        let event = ProximityEvent(
            id: UUID(), state: currentState, distanceMeters: nearest, region: region,
            depthConfidence: confidence, triggeringLabel: label, isSimulated: isSimulated,
            inputTimestamp: inputTimestamp, decidedAt: decidedAt, hapticEnqueuedAt: enqueuedAt,
            patternName: pattern?.rawValue,
            processingLatencyMs: (decidedAt - inputTimestamp) * 1000,
            ttcSeconds: ttc, bearingDegrees: bearing)

        lastEvent = event
        recentEvents.insert(event, at: 0)
        if recentEvents.count > Self.maxRecentEvents {
            recentEvents.removeLast(recentEvents.count - Self.maxRecentEvents)
        }
        return event
    }

    func reset() {
        machine.reset()
        currentState = .clear
        lastEvent = nil
        recentEvents.removeAll()
    }

    static func pattern(for state: ProximityState) -> HapticPattern? {
        switch state {
        case .clear: return nil
        case .caution: return .shortLight
        case .near: return .twoPulseWarning
        case .critical: return .criticalProximity
        case .uncertain: return .uncertainty
        }
    }
}
