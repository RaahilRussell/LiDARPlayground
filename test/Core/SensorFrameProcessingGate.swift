import Foundation

/// Persists across view-task restarts. Cancellation of the awaiting view task
/// does not release its sensor buffers until the detached worker actually ends.
@MainActor
final class SensorFrameProcessingGate {
    private var activeWork: UUID?

    func begin() -> UUID? {
        guard activeWork == nil else { return nil }
        let token = UUID()
        activeWork = token
        return token
    }

    func finish(_ token: UUID) {
        guard activeWork == token else { return }
        activeWork = nil
    }
}
