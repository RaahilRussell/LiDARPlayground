import Foundation
import Testing
@testable import test

@MainActor
@Suite("Shared perception lifecycle")
struct PerceptionLifecycleTests {
    @Test func assistFirstThenAIKeepsVisionUntilBothRelease() {
        var demand = PerceptionPipelineDemand()
        let assist = UUID(), camera = UUID()
        let first = demand.acquire(.guidance, for: assist, running: [])
        #expect(first.start == .guidance)
        let second = demand.acquire(.vision, for: camera, running: .guidance)
        #expect(second.start.isEmpty)
        let stoppedAssist = demand.release(assist)
        #expect(!stoppedAssist.stop.contains(.vision))
        #expect(stoppedAssist.stop == [.fusion, .spatial, .proximity])
        let stoppedAI = demand.release(camera)
        #expect(stoppedAI.stop == .vision)
    }

    @Test func AIFirstThenAssistKeepsVisionWhenAIViewDisappears() {
        var demand = PerceptionPipelineDemand()
        let camera = UUID(), assist = UUID()
        _ = demand.acquire(.vision, for: camera, running: [])
        let second = demand.acquire(.guidance, for: assist, running: .vision)
        #expect(second.start == [.fusion, .spatial, .proximity])
        let disappearing = demand.release(camera)
        #expect(disappearing.stop.isEmpty)
        let final = demand.release(assist)
        #expect(final.stop == .guidance)
    }

    @Test func destinationAppearingBeforeOldViewDisappearsRetainsSharedEngines() {
        var demand = PerceptionPipelineDemand()
        let oldView = UUID(), newView = UUID()
        _ = demand.acquire(.fused, for: oldView, running: [])
        _ = demand.acquire(.fused, for: newView, running: .fused)
        let oldDisappears = demand.release(oldView)
        #expect(oldDisappears.stop.isEmpty)
        let repeated = demand.release(oldView)
        #expect(repeated.stop.isEmpty)
        let newDisappears = demand.release(newView)
        #expect(newDisappears.stop == .fused)
    }

    @Test func disappearingBeforeDestinationAppearsCanRestartCleanly() {
        var demand = PerceptionPipelineDemand()
        let first = UUID(), second = UUID()
        _ = demand.acquire(.vision, for: first, running: [])
        let stopped = demand.release(first)
        #expect(stopped.stop == .vision)
        let started = demand.acquire(.fused, for: second, running: [])
        #expect(started.start == .fused)
    }

    @Test func preexistingManualPipelineIsNotStoppedByViewRelease() {
        var demand = PerceptionPipelineDemand()
        let view = UUID()
        let started = demand.acquire(.guidance, for: view, running: [.vision, .proximity])
        #expect(started.start == [.fusion, .spatial])
        let stopped = demand.release(view)
        #expect(stopped.stop == [.fusion, .spatial])
    }

    @Test func reacquiringSameConsumerDoesNotAddAnUnreleasableReference() {
        var demand = PerceptionPipelineDemand()
        let view = UUID()
        _ = demand.acquire(.vision, for: view, running: [])
        _ = demand.acquire(.vision, for: view, running: .vision)
        let stopped = demand.release(view)
        #expect(stopped.stop == .vision)
    }

    private func system() -> PerceptionSystem {
        let result = PerceptionSystem()
        result.speech.enabled = false
        result.haptics.enabled = false
        result.spatialCue.enabled = false
        // No camera/model inference is needed to exercise lifecycle ownership.
        result.vision.isEnabled = true
        return result
    }

    private func cleanUp(_ system: PerceptionSystem) {
        system.guidance.stop(); system.proximityDriver.stop()
        system.spatial.stop(); system.fusion.stop(); system.vision.stop()
    }

    @Test func routeSpeechHandoffKeepsCVSpatialAndProximityRunning() {
        let system = system()
        defer { cleanUp(system) }
        let consumer = UUID()
        system.acquire(.guidance, for: consumer)
        system.vision.targetHz = 17
        system.beginNavigationSpeech()
        #expect(!system.guidance.canSpeak)
        #expect(system.vision.isEnabled && system.fusion.isRunning && system.spatial.isRunning)
        #expect(system.proximityDriver.running)
        #expect(system.vision.targetHz == 17)
        #expect(!system.haptics.enabled && !system.speech.enabled)
        system.endNavigationSpeech()
        #expect(system.guidance.canSpeak)
        #expect(system.proximityDriver.running)
    }

    @Test func stoppingAssistRetainsLaterFusedViewConsumer() {
        let system = system()
        defer { cleanUp(system) }
        system.guidance.start()
        let fusedView = UUID()
        system.acquire(.guidance, for: fusedView)
        system.guidance.stop()
        #expect(system.vision.isEnabled && system.fusion.isRunning && system.spatial.isRunning)
        #expect(system.proximityDriver.running)
        system.release(fusedView)
        #expect(!system.fusion.isRunning && !system.spatial.isRunning && !system.proximityDriver.running)
        #expect(system.vision.isEnabled) // Preexisting manual inference remains enabled.
    }

    @Test func repeatedBackgroundAndForegroundPreserveIntentWithoutBackgroundFeedback() {
        let system = system()
        defer { cleanUp(system) }
        system.proximityDriver.start()
        system.beginNavigationSpeech()
        system.handleLeftForeground()
        system.handleLeftForeground()
        #expect(!system.proximityDriver.running)
        #expect(system.vision.isEnabled)
        system.handleEnteredForeground()
        system.handleEnteredForeground()
        #expect(system.proximityDriver.running)
        #expect(!system.guidance.canSpeak) // Route still owns speech after resume.
        system.endNavigationSpeech()
        #expect(system.guidance.canSpeak)
    }

    @Test func releasingLastConsumerWhileInactiveDoesNotRestartFeedbackOnReturn() {
        let system = system()
        defer { cleanUp(system) }
        let consumer = UUID()
        system.acquire([.spatial, .proximity], for: consumer)
        system.handleLeftForeground()
        system.release(consumer)
        system.handleEnteredForeground()
        #expect(!system.proximityDriver.running && !system.spatial.isRunning)
    }

    @Test func inspectorToggleReleasesOnlyItsOwnConsumer() {
        let system = system()
        defer { cleanUp(system) }
        let manager = ARSessionManager()
        system.configure(with: manager)
        let fused = UUID()
        system.acquire([.spatial, .proximity], for: fused)
        system.inspector.setSpatialProximityRunning(true)
        system.inspector.stop()
        #expect(system.proximityDriver.running) // Hiding Inspector is not a global stop.
        system.inspector.setSpatialProximityRunning(false)
        #expect(system.proximityDriver.running && system.spatial.isRunning)
        system.release(fused)
        #expect(!system.proximityDriver.running && !system.spatial.isRunning)
    }

    @Test func inactiveLaunchDefersFeedbackUntilForeground() {
        let system = system()
        defer { cleanUp(system) }
        system.handleLeftForeground()
        let consumer = UUID()
        system.acquire([.spatial, .proximity], for: consumer)
        #expect(!system.proximityDriver.running && !system.guidance.canSpeak)
        system.handleEnteredForeground()
        #expect(system.proximityDriver.running && system.guidance.canSpeak)
    }

    @Test func inspectorRejectsResultsFromPreviousPollingOrCameraSession() {
        #expect(PerceptionInspector.acceptsPreview(operation: 2, currentOperation: 2,
                                                   sessionGeneration: 4, currentSessionGeneration: 4,
                                                   timestamp: 10, now: 10.1))
        #expect(!PerceptionInspector.acceptsPreview(operation: 2, currentOperation: 3,
                                                    sessionGeneration: 4, currentSessionGeneration: 4,
                                                    timestamp: 10, now: 10.1))
        #expect(!PerceptionInspector.acceptsPreview(operation: 2, currentOperation: 2,
                                                    sessionGeneration: 4, currentSessionGeneration: 5,
                                                    timestamp: 10, now: 10.1))
    }

    @Test func inspectorRejectsSlowOrInvalidPreviewResults() {
        for timestamp in [9.4, 10.1, Double.nan, Double.infinity] {
            #expect(!PerceptionInspector.acceptsPreview(operation: 2, currentOperation: 2,
                                                        sessionGeneration: 4, currentSessionGeneration: 4,
                                                        timestamp: timestamp, now: 10))
        }
    }
}
