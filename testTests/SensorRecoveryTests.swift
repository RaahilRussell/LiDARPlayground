import ARKit
import Foundation
import Testing
@testable import test

@Suite("Preserving scans during sensor recovery")
struct SensorRecoveryTests {
    @Test func initialRunGetsTimeToDeliverItsFirstFrame() {
        let policy = SensorRecoveryPolicy()
        #expect(decision(policy, now: 104.9) == .wait)
        #expect(decision(policy, now: 105) == .retry)
    }

    @Test func freshImagesDoNotTriggerRecoveryForLimitedWorldTracking() {
        let policy = SensorRecoveryPolicy()
        #expect(decision(policy, now: 110, frameAt: 109.9) == .wait)
        #expect(decision(policy, now: 110, frameAt: 107) == .retry)
    }

    @Test func explicitPauseBackgroundAndSystemInterruptionPreventRetries() {
        let policy = SensorRecoveryPolicy()
        #expect(decision(policy, now: 120, foreground: false, failed: true) == .wait)
        #expect(decision(policy, now: 120, wantsRunning: false, failed: true) == .wait)
        #expect(decision(policy, now: 120, interrupted: true, failed: true) == .wait)
    }

    @Test func fatalFailureIsImmediateButSubsequentRetriesAreBoundedAndSpaced() {
        var policy = SensorRecoveryPolicy()
        #expect(decision(policy, now: 100, failed: true) == .retry)
        policy.didAttempt(at: 100)
        #expect(decision(policy, now: 107.9, failed: true) == .wait)
        #expect(decision(policy, now: 108, failed: true) == .retry)
        policy.didAttempt(at: 108)
        policy.didAttempt(at: 116)
        #expect(decision(policy, now: 124, failed: true) == .exhausted)
        #expect(policy.attempts == 3)
    }

    @Test func oneReturningFrameDoesNotCreateAnInfiniteRecoveryLoop() {
        var policy = SensorRecoveryPolicy()
        policy.didAttempt(at: 100)
        policy.didAttempt(at: 108)
        policy.didAttempt(at: 116)
        policy.observedFrame(at: 117)
        policy.lostFrames()
        #expect(decision(policy, now: 124, failed: true) == .exhausted)
        policy.observedFrame(at: 125)
        policy.observedFrame(at: 130)
        #expect(policy.attempts == 0)
        #expect(decision(policy, now: 134, failed: true) == .retry)
    }

    @Test func deliberateRetryStartsAFreshBoundedBudget() {
        var policy = SensorRecoveryPolicy()
        for time in [100.0, 108.0, 116.0] { policy.didAttempt(at: time) }
        policy.reset()
        #expect(policy.attempts == 0)
        #expect(decision(policy, now: 117, failed: true) == .retry)
    }

    @MainActor
    @Test func failureDoesNotChangeGenerationOrOverrideExplicitPause() {
        let manager = ARSessionManager()
        manager.pause()
        let generation = manager.sessionGeneration
        let pauseRevision = manager.pauseRevision
        manager.session(manager.session, didFailWithError: NSError(domain: "Test sensor failure", code: 1))
        #expect(manager.sessionGeneration == generation)
        #expect(manager.pauseRevision == pauseRevision)
        #expect(manager.isUserPaused)
        #expect(manager.runState == .paused)
        #expect(!manager.canRetrySensorRecovery)
        manager.retrySensorRecovery()
        #expect(manager.runState == .paused)
        #expect(manager.sessionGeneration == generation)
    }

    @MainActor
    @Test func fatalFailureWhileBackgroundedDoesNotStartTheCamera() {
        let manager = ARSessionManager()
        manager.handleResignActive()
        manager.session(manager.session, didFailWithError: NSError(domain: "Test sensor failure", code: 1))
        #expect(manager.runState == .idle)
        #expect(!manager.canRetrySensorRecovery)
        #expect(!manager.isRecoveringSensors)
        #expect(manager.sessionGeneration == 0)
    }

    @MainActor
    @Test(arguments: [MappingSessionError.captureTimedOut, .changedSession])
    func mapCaptureTimeoutOrCancellationIgnoresLateARKitCallbacks(firstFailure: MappingSessionError) async {
        let request = WorldMapSnapshotRequest()
        var observed: MappingSessionError?
        do {
            let _: ARWorldMap = try await withCheckedThrowingContinuation { continuation in
                request.continuation = continuation
                request.finish(.failure(firstFailure))
                // ARKit has no cancellation API. Its delayed completion must
                // neither resume twice nor replace the timeout/reset result.
                request.finish(.failure(MappingSessionError.notReady))
            }
        } catch { observed = error as? MappingSessionError }
        #expect(observed == firstFailure)
        #expect(request.continuation == nil)
        #expect(request.timeoutTask == nil)
    }

    private func decision(_ policy: SensorRecoveryPolicy, now: TimeInterval,
                          frameAt: TimeInterval = 0, foreground: Bool = true,
                          wantsRunning: Bool = true, interrupted: Bool = false,
                          failed: Bool = false) -> SensorRecoveryPolicy.Decision {
        policy.decision(now: now, runStartedAt: 100, lastFrameAt: frameAt,
            foreground: foreground, wantsRunning: wantsRunning,
            interrupted: interrupted, failed: failed)
    }
}
