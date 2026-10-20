//
//  ProximityTests.swift
//  testTests
//
//  Phase 9 — proximity state machine (thresholds, uncertainty, hysteresis) and
//  the evaluator's bounded, labeled event history. Haptics are disabled here.
//

import QuartzCore
import Testing
@testable import test

@MainActor
@Suite("Proximity")
struct ProximityTests {

    private func state(after inputs: [(Float?, Float?)]) -> ProximityState {
        var m = ProximityStateMachine()
        for (d, c) in inputs { m.step(nearest: d, confidence: c) }
        return m.state
    }

    nonisolated static let thresholdCases: [(Float, ProximityState)] = [
        (3.0, .clear), (2.0, .caution), (1.0, .near), (0.7, .near), (0.5, .critical), (0.1, .critical),
    ]

    @Test(arguments: ProximityTests.thresholdCases)
    func thresholdsFromClear(distance: Float, expected: ProximityState) {
        #expect(state(after: [(distance, 1)]) == expected)
    }

    @Test func missingOrUntrustedDepthIsUncertainNotClear() {
        #expect(state(after: [(nil, 1)]) == .uncertain)
        #expect(state(after: [(Float.nan, 1)]) == .uncertain)
        #expect(state(after: [(Float.infinity, 1)]) == .uncertain)
        #expect(state(after: [(1.0, nil)]) == .uncertain)
        #expect(state(after: [(1.0, 0.39)]) == .uncertain)
        #expect(state(after: [(3.0, 0.39)]) == .uncertain, "low confidence never reads as clear")
    }

    @Test func escalationIsImmediate() {
        var m = ProximityStateMachine()
        let first = m.step(nearest: 3, confidence: 1)
        #expect(first == false)  // already clear
        let second = m.step(nearest: 0.3, confidence: 1)
        #expect(second)
        #expect(m.state == .critical)
    }

    @Test func deEscalationRequiresHysteresis() {
        var m = ProximityStateMachine()
        m.step(nearest: 0.9, confidence: 1)
        #expect(m.state == .near)
        m.step(nearest: 1.1, confidence: 1)                // < 1.0 + 0.15
        #expect(m.state == .near)
        m.step(nearest: 1.2, confidence: 1)                // clears the band
        #expect(m.state == .caution)
    }

    @Test func boundaryJitterDoesNotFlap() {
        var m = ProximityStateMachine()
        var changes = 0
        for i in 0..<40 { if m.step(nearest: i.isMultiple(of: 2) ? 0.98 : 1.04, confidence: 1) { changes += 1 } }
        #expect(changes == 1, "one transition into NEAR, then stable")
        #expect(m.state == .near)
    }

    @Test func recoversDirectlyFromUncertain() {
        #expect(state(after: [(nil, nil), (3.0, 1)]) == .clear)
        #expect(state(after: [(0.4, 1), (nil, nil), (2.5, 1)]) == .clear)
    }

    @Test func customThresholdsAreHonoured() {
        var m = ProximityStateMachine(thresholds: ProximityThresholds(criticalDistance: 0.2, nearDistance: 0.4,
                                                                      cautionDistance: 0.6, hysteresis: 0.05,
                                                                      minConfidence: 0.9))
        m.step(nearest: 0.5, confidence: 0.95)
        #expect(m.state == .caution)
        m.step(nearest: 0.5, confidence: 0.8)
        #expect(m.state == .uncertain)
    }

    @Test func evaluatorHistoryIsBoundedAndLabeled() {
        let haptics = HapticCoordinator()
        haptics.enabled = false
        let evaluator = ProximityEvaluator(haptics: haptics)
        let now = CACurrentMediaTime()
        for i in 0..<(ProximityEvaluator.maxRecentEvents + 15) {
            evaluator.evaluate(nearest: Float(i % 3) + 0.3, confidence: 1, region: .center, label: nil,
                               isSimulated: i.isMultiple(of: 2), inputTimestamp: now)
        }
        #expect(evaluator.recentEvents.count == ProximityEvaluator.maxRecentEvents)
        #expect(evaluator.recentEvents.first?.id == evaluator.lastEvent?.id, "newest first")
        #expect(evaluator.recentEvents.allSatisfy { $0.hapticEnqueuedAt == nil }, "haptics disabled → nothing enqueued")
        #expect(evaluator.recentEvents.contains { $0.isSimulated } && evaluator.recentEvents.contains { !$0.isSimulated })

        evaluator.reset()
        #expect(evaluator.recentEvents.isEmpty && evaluator.currentState == .clear)
    }
}
