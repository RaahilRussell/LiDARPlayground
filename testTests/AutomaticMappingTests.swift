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
        manager.handleResignActive()
        manager.handleBecameActive()
        #expect(manager.isUserPaused)
        #expect(manager.runState == .paused)
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
