//
//  ProximityEvaluator.swift
//  test
//
//  Phase 5/6 — experimental proximity state machine driven by GEOMETRY + its
//  confidence (never by class labels alone). CLEAR/CAUTION/NEAR/CRITICAL/UNCERTAIN
//  with hysteresis + cooldown to prevent oscillation. Thresholds are configurable
//  for controlled testing — they are NOT assumed safety standards.
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
    private var stateEnteredAt: TimeInterval = 0

    init(haptics: HapticCoordinator) { self.haptics = haptics }

    /// Evaluate one proximity input. `nearest`/`confidence` come from geometry.
    @discardableResult
    func evaluate(nearest: Float?, confidence: Float?, region: SpatialRegion?,
                  label: String?, isSimulated: Bool, inputTimestamp: TimeInterval) -> ProximityEvent {
        let decidedAt = CACurrentMediaTime()

        // Decide target state.
        var target: ProximityState
        if let d = nearest, d.isFinite, let c = confidence, c >= minConfidence {
            target = rawState(for: d)
        } else {
            target = .uncertain
        }
        target = applyHysteresis(target, distance: nearest)

        if target != currentState {
            currentState = target
            stateEnteredAt = decidedAt
        }

        // Map state → pattern and enqueue (coordinator applies cooldown + priority).
        let pattern = Self.pattern(for: currentState)
        var enqueuedAt: TimeInterval?
        if let pattern { enqueuedAt = haptics.play(pattern) }

        let event = ProximityEvent(
            id: UUID(), state: currentState, distanceMeters: nearest, region: region,
            depthConfidence: confidence, triggeringLabel: label, isSimulated: isSimulated,
            inputTimestamp: inputTimestamp, decidedAt: decidedAt, hapticEnqueuedAt: enqueuedAt,
            patternName: pattern?.rawValue,
            processingLatencyMs: (decidedAt - inputTimestamp) * 1000)

        lastEvent = event
        recentEvents.insert(event, at: 0)
        if recentEvents.count > 50 { recentEvents.removeLast(recentEvents.count - 50) }
        return event
    }

    func reset() {
        currentState = .clear
        lastEvent = nil
        recentEvents.removeAll()
    }

    // MARK: - State logic

    private func rawState(for d: Float) -> ProximityState {
        if d <= criticalDistance { return .critical }
        if d <= nearDistance { return .near }
        if d <= cautionDistance { return .caution }
        return .clear
    }

    /// Require clearing a threshold by `hysteresis` before DE-escalating, so the
    /// state doesn't flap at a boundary. Escalation is immediate.
    private func applyHysteresis(_ target: ProximityState, distance: Float?) -> ProximityState {
        guard let d = distance, d.isFinite, target != .uncertain, currentState != .uncertain else {
            return target
        }
        if severity(target) >= severity(currentState) { return target } // escalating → accept
        // De-escalating: only if we've moved comfortably past the boundary.
        switch currentState {
        case .critical: return d > criticalDistance + hysteresis ? target : .critical
        case .near: return d > nearDistance + hysteresis ? target : .near
        case .caution: return d > cautionDistance + hysteresis ? target : .caution
        default: return target
        }
    }

    private func severity(_ s: ProximityState) -> Int {
        switch s {
        case .clear: return 0
        case .caution: return 1
        case .near: return 2
        case .critical: return 3
        case .uncertain: return -1
        }
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
