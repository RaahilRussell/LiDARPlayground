import Foundation

/// A stopped camera is different from limited world tracking: only missing
/// frames trigger another run. Attempts are bounded until sustained data returns.
nonisolated struct SensorRecoveryPolicy {
    static let maximumAttempts = 3
    static let startupGrace: TimeInterval = 5
    static let stalledFrameInterval: TimeInterval = 3
    static let retryInterval: TimeInterval = 8
    static let stableInterval: TimeInterval = 5

    private(set) var attempts = 0
    private(set) var lastAttempt: TimeInterval?
    private var healthySince: TimeInterval?

    enum Decision: Equatable { case wait, retry, exhausted }

    func decision(now: TimeInterval, runStartedAt: TimeInterval,
                  lastFrameAt: TimeInterval, foreground: Bool,
                  wantsRunning: Bool, interrupted: Bool, failed: Bool) -> Decision {
        guard foreground, wantsRunning, !interrupted, now.isFinite else { return .wait }
        if let lastAttempt, now - lastAttempt < Self.retryInterval { return .wait }
        if !failed {
            let lastActivity = max(runStartedAt, lastFrameAt)
            let grace = lastFrameAt > 0 ? Self.stalledFrameInterval : Self.startupGrace
            guard now - lastActivity >= grace else { return .wait }
        }
        return attempts < Self.maximumAttempts ? .retry : .exhausted
    }

    mutating func didAttempt(at now: TimeInterval) {
        attempts += 1
        lastAttempt = now
        healthySince = nil
    }

    mutating func observedFrame(at now: TimeInterval) {
        if healthySince == nil { healthySince = now }
        if let healthySince, now - healthySince >= Self.stableInterval {
            attempts = 0
            lastAttempt = nil
        }
    }

    mutating func lostFrames() { healthySince = nil }
    mutating func reset() { self = Self() }
}
