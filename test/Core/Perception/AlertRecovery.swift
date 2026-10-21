import Foundation

/// Hardware output may stop independently of the user's enabled preference.
/// Retry on the next alert, with a short backoff if an interruption persists.
nonisolated struct FeedbackEngineRecovery {
    private(set) var isReady = false
    private var retryAfter: TimeInterval = 0

    func shouldAttemptStart(at now: TimeInterval) -> Bool {
        !isReady && now.isFinite && now >= retryAfter
    }

    mutating func started() { isReady = true; retryAfter = 0 }
    mutating func stopped() { isReady = false; retryAfter = 0 }
    mutating func failed(at now: TimeInterval) {
        isReady = false
        retryAfter = now.isFinite ? now + 1 : 0
    }
}

nonisolated enum AlertInputStatus: Equatable {
    case stopped, waitingForCamera, waitingForDepth, waitingForGeometry
    case live, limitedTracking, demo

    var hasCurrentMeasurements: Bool { self == .live || self == .limitedTracking }
    var message: String {
        switch self {
        case .stopped: return "Alerts stopped"
        case .waitingForCamera: return "Waiting for fresh camera data · alerts resume automatically"
        case .waitingForDepth: return "Waiting for fresh LiDAR depth · alerts resume automatically"
        case .waitingForGeometry: return "Updating nearby distances · alerts resume automatically"
        case .live: return "Live proximity alerts"
        case .limitedTracking: return "Live depth alerts · map tracking is recovering"
        case .demo: return "Simulated alerts · no live obstacle observation"
        }
    }

    static func evaluate(cameraAvailable: Bool, depthAvailable: Bool,
                         geometryCurrent: Bool, worldTrackingValid: Bool) -> Self {
        guard cameraAvailable else { return .waitingForCamera }
        guard depthAvailable else { return .waitingForDepth }
        guard geometryCurrent else { return .waitingForGeometry }
        return worldTrackingValid ? .live : .limitedTracking
    }
}

nonisolated struct AlertRecoveryAnnouncements {
    nonisolated enum Change: Equatable { case unavailable, resumed }
    private var lastAvailable: Bool?

    mutating func update(available: Bool) -> Change? {
        defer { lastAvailable = available }
        if !available, lastAvailable != false { return .unavailable }
        if available, lastAvailable == false { return .resumed }
        return nil
    }
}
