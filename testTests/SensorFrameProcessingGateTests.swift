import Foundation
import Testing
@testable import test

@Suite("Sensor view processing backpressure")
struct SensorFrameProcessingGateTests {
    @MainActor
    @Test func canceledViewTaskKeepsGateUntilItsWorkerReleasesBuffers() async throws {
        let gate = SensorFrameProcessingGate()
        var continuation: CheckedContinuation<Void, Never>?
        let oldViewTask = Task { @MainActor in
            guard let token = gate.begin() else { return }
            defer { gate.finish(token) }
            await withCheckedContinuation { continuation = $0 }
        }
        while continuation == nil { await Task.yield() }
        let workerCompletion = try #require(continuation)
        oldViewTask.cancel()

        // SwiftUI can restart .task(id:) before its predecessor's pixel work ends.
        let restartedWork = gate.begin()
        #expect(restartedWork == nil)
        workerCompletion.resume()
        await oldViewTask.value

        let nextWork = try #require(gate.begin())
        gate.finish(nextWork)
    }

    @MainActor
    @Test func lateCompletionCannotReleaseANewerWorker() throws {
        let gate = SensorFrameProcessingGate()
        let old = try #require(gate.begin())
        gate.finish(old)
        let current = try #require(gate.begin())
        gate.finish(old)
        let overlapping = gate.begin()
        #expect(overlapping == nil)
        gate.finish(current)
        let following = try #require(gate.begin())
        gate.finish(following)
    }
}
