//
//  ProximityStateMachine.swift
//  test
//
//  Phase 9 — the original proximity state machine. It now only drives the
//  Inspector's synthetic demo mode; Wearer Mode decides alerts in AlertPolicy.
//  Geometry + confidence (never labels), immediate escalation, and hysteresis
//  before de-escalating. Thresholds are test values, not safety standards.
//

nonisolated struct ProximityThresholds: Equatable, Sendable {
    var criticalDistance: Float = 0.5
    var nearDistance: Float = 1.0
    var cautionDistance: Float = 2.0
    var hysteresis: Float = 0.15
    var minConfidence: Float = 0.4
    // Time-to-collision tiers (seconds). Scaled down from ADAS (~4 s / ~2 s) for
    // walking speed, keeping ≥ ~1.5 s human reaction lead at the critical tier.
    var ttcCritical: Float = 1.5
    var ttcNear: Float = 2.5
    var ttcCaution: Float = 4.0
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
    mutating func step(nearest: Float?, confidence: Float?, ttc: Float? = nil,
                       inPath: Bool = true) -> Bool {
        var target: ProximityState
        if let d = nearest, d.isFinite, let c = confidence, c >= thresholds.minConfidence {
            var distanceState = rawState(for: d)
            // Walking ALONGSIDE something (lateral, not on a collision course) is not
            // critical — cap the distance-only severity at caution. A closing hazard
            // still escalates through the TTC tier below.
            if !inPath, Self.severity(distanceState) > Self.severity(.caution) {
                distanceState = .caution
            }
            // A lateral object can have a changing range simply because the user is
            // walking past it. Do not turn that pass-by motion into an urgent TTC alert.
            // TTC remains useful in the walking corridor, where it represents a real
            // approach toward the user's path.
            let timeState = inPath ? ttcState(for: ttc) : .clear
            target = moreSevere(distanceState, timeState)
        } else {
            target = .uncertain
        }
        target = applyHysteresis(target, distance: nearest)
        let changed = target != state
        state = target
        return changed
    }

    /// TTC tier: closing fast on something raises the alert earlier than distance alone.
    func ttcState(for ttc: Float?) -> ProximityState {
        guard let t = ttc, t.isFinite, t > 0 else { return .clear }
        if t <= thresholds.ttcCritical { return .critical }
        if t <= thresholds.ttcNear { return .near }
        if t <= thresholds.ttcCaution { return .caution }
        return .clear
    }

    private func moreSevere(_ a: ProximityState, _ b: ProximityState) -> ProximityState {
        Self.severity(a) >= Self.severity(b) ? a : b
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
