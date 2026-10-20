//
//  ProximityStateMachine.swift
//  test
//
//  Phase 9 — the pure proximity decision logic extracted from ProximityEvaluator
//  so it can be fixture-tested and reused by the Inspector demo mode without
//  touching shared live state or haptics. Behavior is identical to the Phase 5/6
//  evaluator: geometry + confidence (never labels), immediate escalation, and
//  hysteresis before de-escalating. Thresholds are test values, not safety
//  standards.
//

nonisolated struct ProximityThresholds: Equatable, Sendable {
    var criticalDistance: Float = 0.5
    var nearDistance: Float = 1.0
    var cautionDistance: Float = 2.0
    var hysteresis: Float = 0.15
    var minConfidence: Float = 0.4
}

nonisolated struct ProximityStateMachine: Sendable {
    var thresholds = ProximityThresholds()
    private(set) var state: ProximityState = .clear

    init(thresholds: ProximityThresholds = ProximityThresholds()) {
        self.thresholds = thresholds
    }

    /// Feeds one geometric input. Missing, non-finite, or low-confidence distance
    /// is UNCERTAIN — never CLEAR. Returns whether the state changed.
    @discardableResult
    mutating func step(nearest: Float?, confidence: Float?) -> Bool {
        var target: ProximityState
        if let d = nearest, d.isFinite, let c = confidence, c >= thresholds.minConfidence {
            target = rawState(for: d)
        } else {
            target = .uncertain
        }
        target = applyHysteresis(target, distance: nearest)
        let changed = target != state
        state = target
        return changed
    }

    mutating func reset() { state = .clear }

    func rawState(for d: Float) -> ProximityState {
        if d <= thresholds.criticalDistance { return .critical }
        if d <= thresholds.nearDistance { return .near }
        if d <= thresholds.cautionDistance { return .caution }
        return .clear
    }

    /// Require clearing a threshold by `hysteresis` before DE-escalating, so the
    /// state doesn't flap at a boundary. Escalation is immediate.
    private func applyHysteresis(_ target: ProximityState, distance: Float?) -> ProximityState {
        guard let d = distance, d.isFinite, target != .uncertain, state != .uncertain else {
            return target
        }
        if Self.severity(target) >= Self.severity(state) { return target } // escalating → accept
        let h = thresholds.hysteresis
        switch state {
        case .critical: return d > thresholds.criticalDistance + h ? target : .critical
        case .near: return d > thresholds.nearDistance + h ? target : .near
        case .caution: return d > thresholds.cautionDistance + h ? target : .caution
        default: return target
        }
    }

    static func severity(_ s: ProximityState) -> Int {
        switch s {
        case .clear: return 0
        case .caution: return 1
        case .near: return 2
        case .critical: return 3
        case .uncertain: return -1
        }
    }
}
