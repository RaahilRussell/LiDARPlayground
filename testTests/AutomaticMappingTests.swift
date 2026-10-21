import Foundation
import Testing
@testable import test

@Suite("Automatic map checkpoints")
struct AutomaticMappingTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    @Test func firstReadyFrameCanSaveAndThenWaitsForInterval() {
        #expect(decision(lastSavedAt: nil))
        #expect(!decision(lastSavedAt: now.addingTimeInterval(-19)))
        #expect(decision(lastSavedAt: now.addingTimeInterval(-20)))
    }

    @Test func pauseBackgroundBadTrackingAndBusyEachBlockSaving() {
        #expect(!decision(ready: false))
        #expect(!decision(foreground: false))
        #expect(!decision(userPaused: true))
        #expect(!decision(busy: true))
        #expect(!decision(enabled: false))
    }

    @Test func transientFailureBackoffPreventsARepeatedSaveLoop() {
        #expect(!decision(lastAttemptAt: now.addingTimeInterval(-4)))
        #expect(decision(lastAttemptAt: now.addingTimeInterval(-5)))
    }

    @Test func rolloverLeavesRoomBeforeHardArchiveLimit() {
        #expect(!AutomaticMappingPolicy.needsSegment(vertices: 3, faces: 1, anchors: 1))
        #expect(AutomaticMappingPolicy.needsSegment(vertices: MapLimits.maxVertices * 7 / 10, faces: 0, anchors: 0))
        #expect(AutomaticMappingPolicy.needsSegment(vertices: 0, faces: MapLimits.maxTriangles * 7 / 10, anchors: 0))
        #expect(AutomaticMappingPolicy.needsSegment(vertices: 0, faces: 0, anchors: MapLimits.maxMeshAnchors * 7 / 10))
    }

    @MainActor
    @Test func explicitPauseSurvivesBackgroundAndForeground() {
        let manager = ARSessionManager()
        manager.pause()
        let pauseRevision = manager.pauseRevision
        manager.handleResignActive()
        manager.handleBecameActive()
        #expect(manager.isUserPaused)
        #expect(manager.runState == .paused)
        #expect(manager.pauseRevision == pauseRevision)
        manager.pause()
        #expect(manager.pauseRevision == pauseRevision + 1)
    }

    @Test func currentFrameCanLeadTheDelegateWithoutBeingDiscarded() {
        #expect(ARSessionManager.acceptsFrameTimestamp(100.02,
            lastAccepted: 100, minimum: 99, now: 100.03))
        #expect(ARSessionManager.acceptsFrameTimestamp(100,
            lastAccepted: 100, minimum: 99, now: 100.03))
    }

    @Test func frameGatesStillRejectStalePreResetAndUndeliveredRuns() {
        #expect(!ARSessionManager.acceptsFrameTimestamp(100,
            lastAccepted: 100.02, minimum: 99, now: 100.03))
        #expect(!ARSessionManager.acceptsFrameTimestamp(100,
            lastAccepted: 100, minimum: 100.01, now: 100.03))
        #expect(!ARSessionManager.acceptsFrameTimestamp(100,
            lastAccepted: 0, minimum: 99, now: 100.03))
        #expect(!ARSessionManager.acceptsFrameTimestamp(100,
            lastAccepted: 100, minimum: 99, now: 100.51))
        #expect(!ARSessionManager.acceptsFrameTimestamp(100.1,
            lastAccepted: 100, minimum: 99, now: 100.03))
        #expect(!ARSessionManager.acceptsFrameTimestamp(.nan,
            lastAccepted: 100, minimum: 99, now: 100.03))
    }

    @Test func processingLagIsAllowedButPreResumeResultsAreRejected() {
        #expect(ARSessionManager.acceptsObservationTimestamp(100.01,
            lastAccepted: 100.08, minimum: 100, now: 100.1))
        #expect(!ARSessionManager.acceptsObservationTimestamp(99.99,
            lastAccepted: 100.08, minimum: 100, now: 100.1))
        #expect(!ARSessionManager.acceptsObservationTimestamp(100.01,
            lastAccepted: 0, minimum: 100, now: 100.1))
        #expect(!ARSessionManager.acceptsObservationTimestamp(100.01,
            lastAccepted: 100.6, minimum: 100, now: 100.6))
    }

    @MainActor
    @Test func failedCheckpointDoesNotChangeCameraRunningIntent() {
        let manager = ARSessionManager()
        let mapping = MappingCoordinator(manager: manager)
        let stateBeforeFailure = manager.runState
        mapping.handleAutomaticSaveFailure(NSError(domain: NSCocoaErrorDomain,
            code: NSFileWriteOutOfSpaceError))
        #expect(mapping.automaticSaveNeedsAttention)
        #expect(manager.runState == stateBeforeFailure)
        #expect(!manager.isUserPaused)
        mapping.retryAutomaticSave()
        #expect(!mapping.automaticSaveNeedsAttention)
        #expect(manager.runState == stateBeforeFailure)
    }

    @MainActor
    @Test func retrySavingDoesNotOverrideExplicitCameraPause() {
        let manager = ARSessionManager()
        let mapping = MappingCoordinator(manager: manager)
        mapping.pauseAutomaticMapping()
        mapping.handleAutomaticSaveFailure(NSError(domain: NSCocoaErrorDomain,
            code: NSFileWriteOutOfSpaceError))
        mapping.retryAutomaticSave()
        #expect(manager.isUserPaused)
        #expect(manager.runState == .paused)
    }

    @MainActor
    @Test func interruptionEndingDoesNotRestartAnExplicitlyPausedCamera() {
        let manager = ARSessionManager()
        manager.pause()
        manager.sessionWasInterrupted(manager.session)
        manager.sessionInterruptionEnded(manager.session)
        #expect(manager.isUserPaused)
        #expect(manager.runState == .paused)
        #expect(!manager.isRelocalizing)
    }

    private func decision(lastSavedAt: Date? = nil, lastAttemptAt: Date? = nil,
                          ready: Bool = true, foreground: Bool = true,
                          userPaused: Bool = false, busy: Bool = false,
                          enabled: Bool = true) -> Bool {
        AutomaticMappingPolicy.shouldSave(now: now, lastSavedAt: lastSavedAt,
            lastAttemptAt: lastAttemptAt, ready: ready, foreground: foreground,
            userPaused: userPaused, busy: busy, enabled: enabled)
    }
}
