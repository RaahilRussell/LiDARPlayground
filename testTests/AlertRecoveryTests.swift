import Foundation
import Testing
@testable import test

@MainActor
@Suite("Alert recovery")
struct AlertRecoveryTests {
    @Test func nextAlertRestartsHardwareAfterIdleOrInterruption() {
        var recovery = FeedbackEngineRecovery()
        #expect(recovery.shouldAttemptStart(at: 10))
        recovery.started()
        #expect(!recovery.shouldAttemptStart(at: 11))
        recovery.stopped()
        #expect(recovery.shouldAttemptStart(at: 11))
        recovery.started()
        #expect(recovery.isReady)
    }

    @Test func ongoingHardwareFailureBacksOffThenRetriesWithoutDisablingPreference() {
        var recovery = FeedbackEngineRecovery()
        recovery.failed(at: 10)
        #expect(!recovery.isReady)
        #expect(!recovery.shouldAttemptStart(at: 10.5))
        #expect(recovery.shouldAttemptStart(at: 11))
        recovery.started()
        #expect(recovery.isReady)
        #expect(!recovery.shouldAttemptStart(at: .nan))
    }

    @Test func freshCameraDepthCanWarnWhileWorldTrackingRecovers() {
        let status = AlertInputStatus.evaluate(cameraAvailable: true, depthAvailable: true,
                                              geometryCurrent: true, worldTrackingValid: false)
        #expect(status == .limitedTracking)
        #expect(status.hasCurrentMeasurements)
        let restored = AlertInputStatus.evaluate(cameraAvailable: true, depthAvailable: true,
                                                geometryCurrent: true, worldTrackingValid: true)
        #expect(restored == .live)
    }

    @Test func staleGeometryAndMissingSensorsCannotKeepObstacleAlertsActive() {
        let cameraMissing = AlertInputStatus.evaluate(cameraAvailable: false, depthAvailable: true,
                                                      geometryCurrent: true, worldTrackingValid: true)
        let depthMissing = AlertInputStatus.evaluate(cameraAvailable: true, depthAvailable: false,
                                                     geometryCurrent: true, worldTrackingValid: true)
        let geometryStale = AlertInputStatus.evaluate(cameraAvailable: true, depthAvailable: true,
                                                      geometryCurrent: false, worldTrackingValid: true)
        #expect(cameraMissing == .waitingForCamera)
        #expect(depthMissing == .waitingForDepth)
        #expect(geometryStale == .waitingForGeometry)
        #expect(!cameraMissing.hasCurrentMeasurements && !depthMissing.hasCurrentMeasurements
                && !geometryStale.hasCurrentMeasurements)
    }

    @Test func sensorLossAndRecoveryAnnounceOncePerTransition() {
        var announcements = AlertRecoveryAnnouncements()
        let initial = announcements.update(available: true)
        let lost = announcements.update(available: false)
        let stillLost = announcements.update(available: false)
        let recovered = announcements.update(available: true)
        let stillRecovered = announcements.update(available: true)
        let lostAgain = announcements.update(available: false)
        #expect(initial == nil)
        #expect(lost == .unavailable && stillLost == nil)
        #expect(recovered == .resumed && stillRecovered == nil)
        #expect(lostAgain == .unavailable)
    }

    @Test func waitingForInitialSensorDataExplainsAutomaticRecovery() {
        var announcements = AlertRecoveryAnnouncements()
        let waiting = announcements.update(available: false)
        let resumed = announcements.update(available: true)
        #expect(waiting == .unavailable && resumed == .resumed)
        #expect(!AlertInputStatus.stopped.hasCurrentMeasurements)
        #expect(!AlertInputStatus.demo.hasCurrentMeasurements)
    }

    @Test func missingFramesDoNotStopRequestedAlertLoops() async throws {
        let manager = ARSessionManager()
        let system = PerceptionSystem()
        system.speech.enabled = false
        system.haptics.enabled = false
        system.spatialCue.enabled = false
        system.configure(with: manager)
        let consumer = UUID()
        system.acquire([.spatial, .proximity], for: consumer)
        defer { system.release(consumer) }
        try await Task.sleep(for: .milliseconds(350))
        #expect(system.proximityDriver.running && system.spatial.isRunning)
        #expect(system.proximityDriver.inputStatus == .waitingForCamera)
        #expect(system.proximity.currentState == .uncertain)
        #expect(system.proximityDriver.primaryDistance == nil)
    }

    @Test func slowerOCRCanPublishWithinItsWindowWithoutWeakeningLiveAlertFreshness() {
        #expect(ARSessionManager.acceptsObservationTimestamp(100.2, lastAccepted: 102.4,
                                                            minimum: 100, now: 102.5, maxAge: 3))
        #expect(!ARSessionManager.acceptsObservationTimestamp(100.2, lastAccepted: 102.4,
                                                             minimum: 100, now: 102.5))
    }

    @Test func longerOCRWindowStillRejectsPreResumeFramesAndInvalidWindows() {
        #expect(!ARSessionManager.acceptsObservationTimestamp(99.9, lastAccepted: 100.2,
                                                             minimum: 100, now: 100.4, maxAge: 3))
        #expect(!ARSessionManager.acceptsObservationTimestamp(100.1, lastAccepted: 0,
                                                             minimum: 100, now: 100.4, maxAge: 3))
        for maxAge in [-1.0, Double.nan, Double.infinity] {
            #expect(!ARSessionManager.acceptsObservationTimestamp(100.1, lastAccepted: 100.2,
                                                                 minimum: 100, now: 100.4, maxAge: maxAge))
        }
    }
}
