//
//  DemoModeTests.swift
//  testTests
//
//  Phase 9 — the Inspector's synthetic demo is deterministic, exercises every
//  proximity state, reports UNCERTAIN (never CLEAR) without valid depth, and
//  never reaches haptics without opt-in.
//

import Testing
@testable import test

@MainActor
@Suite("Demo mode")
struct DemoModeTests {

    private func run(_ steps: Int) -> [DemoStepOutput] {
        var runner = DemoRunner()
        return (0..<steps).map { _ in runner.advance() }
    }

    @Test func framesArePureFunctionsOfTheStep() {
        for step in [0, 10, 30, 47, 55, 63] {
            let a = DemoScenario.frame(at: step), b = DemoScenario.frame(at: step)
            #expect(a.cameraPoints == b.cameraPoints && a.confidences == b.confidences && a.depth == b.depth)
        }
        let wrapped = DemoScenario.frame(at: DemoScenario.length + 5)
        #expect(wrapped.step == 5 && wrapped.cameraPoints == DemoScenario.frame(at: 5).cameraPoints)
        #expect(DemoScenario.frame(at: -1).step == DemoScenario.length - 1)
    }

    @Test func twoRunsProduceIdenticalStateSequences() {
        let a = run(2 * DemoScenario.length).map(\.state)
        let b = run(2 * DemoScenario.length).map(\.state)
        #expect(a == b)
    }

    @Test func scriptVisitsEveryStateInOrder() {
        let out = run(DemoScenario.length)
        #expect(out[0].state == .clear)                         // 3.0 m
        #expect(out.contains { $0.state == .caution })
        #expect(out.contains { $0.state == .near })
        #expect((24..<32).allSatisfy { out[$0].state == .critical }, "hold at 0.4 m")
        #expect(out[43].state == .clear, "recede to 2.6 m clears past hysteresis")
        #expect(out.last?.state == .clear)
        let firstCritical = out.firstIndex { $0.state == .critical } ?? 0
        let firstNear = out.firstIndex { $0.state == .near } ?? 0
        let firstCaution = out.firstIndex { $0.state == .caution } ?? 0
        #expect(firstCaution < firstNear && firstNear < firstCritical, "approach escalates monotonically")
    }

    @Test func dropoutIsUnknownAndUncertainNeverClear() {
        let out = run(DemoScenario.length)
        for i in 44..<52 {
            #expect(out[i].frame.segment == .dropout)
            #expect(out[i].occupancy.allSatisfy { $0.occupancy == .unknown }, "no samples → unknown, not free")
            #expect(out[i].state == .uncertain)
            #expect(out[i].input == nil)
        }
        for i in 52..<58 {
            #expect(out[i].occupancy.allSatisfy { $0.occupancy == .lowConfidence })
            #expect(out[i].state == .uncertain, "low-confidence depth must not read as a distance")
        }
    }

    @Test func dropoutDepthImageIsAllInvalid() {
        #expect(DemoScenario.frame(at: 46).depth.allSatisfy { $0 == 0 })
        #expect(DemoScenario.frame(at: 60).depth.allSatisfy { $0 == DemoScenario.wallMeters })
        #expect(DemoScenario.frame(at: 0).depth.count == DemoScenario.depthWidth * DemoScenario.depthHeight)
    }

    @Test func hapticsRequireExplicitOptIn() {
        for changed in [true, false] {
            #expect(DemoRunner.shouldPlayHaptic(stateChanged: changed, optedIn: false) == false)
        }
        #expect(DemoRunner.shouldPlayHaptic(stateChanged: true, optedIn: true))
        #expect(DemoRunner.shouldPlayHaptic(stateChanged: false, optedIn: true) == false)
    }

    @Test func selectorReturnsNilWithoutObservations() {
        let unknown = SpatialAlgorithms.occupancy(cameraPoints: [], confidences: [])
        #expect(ProximityInputSelector.select(from: unknown) == nil)
        let frame = DemoScenario.frame(at: 10)
        let occ = SpatialAlgorithms.occupancy(cameraPoints: frame.cameraPoints, confidences: frame.confidences)
        let pick = ProximityInputSelector.select(from: occ)
        #expect(pick?.region == .center)
        #expect(abs((pick?.meters ?? 0) - (frame.obstacleMeters ?? -1)) < 1e-4)
    }

    @Test func resetRestartsTheScript() {
        var runner = DemoRunner()
        for _ in 0..<30 { _ = runner.advance() }
        runner.reset()
        #expect(runner.step == 0 && runner.machine.state == .clear)
        let first = runner.advance()
        #expect(first.frame.step == 0)
    }
}
