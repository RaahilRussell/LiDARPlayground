//
//  InspectorModelTests.swift
//  testTests
//
//  Phase 9 — Inspector helpers: pixel-format labels, depth statistics, the
//  bounded event log, occupancy change detection, and the latency breakdown
//  (measured values only; missing stages stay nil).
//

import CoreVideo
import Testing
@testable import test

@MainActor
@Suite("Inspector models")
struct InspectorModelTests {

    @Test func fourCCLabels() {
        #expect(FourCC.string(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) == "420f")
        #expect(FourCC.string(kCVPixelFormatType_DepthFloat32) == "fdep")
        #expect(FourCC.string(0x0000_0001) == "0x00000001")
    }

    @Test func depthStatisticsIgnoreInvalid() {
        let s = DepthStatistics.compute(depth: [0, 1, 2, 3, .nan], confidence: [0, 1, 2, 2, 2])
        #expect(abs(s.validFraction - 0.6) < 1e-9)
        #expect(s.minMeters == 1 && s.medianMeters == 2 && s.maxMeters == 3)
        #expect(s.confidenceLow == 0.2 && s.confidenceMedium == 0.2 && s.confidenceHigh == 0.6)

        let empty = DepthStatistics.compute(depth: [0, 0], confidence: nil)
        #expect(empty.validFraction == 0 && empty.minMeters == nil && empty.confidenceHigh == nil)
    }

    @Test func eventLogIsBoundedNewestFirst() {
        var log = EventLog()
        for i in 0..<(EventLog.capacity + 50) {
            log.append(origin: i.isMultiple(of: 2) ? .live : .demo, kind: .proximity, message: "\(i)", at: Double(i))
        }
        let events = log.newestFirst
        #expect(events.count == EventLog.capacity)
        #expect(events.first?.id == EventLog.capacity + 49)
        #expect(events.last?.id == 50)
        #expect(zip(events, events.dropFirst()).allSatisfy { $0.id > $1.id })
        log.clear()
        #expect(log.newestFirst.isEmpty)
    }

    @Test func occupancyDiffReportsOnlyChanges() {
        func region(_ id: SpatialRegion, _ c: OccupancyClass) -> RegionOccupancy {
            RegionOccupancy(id: id, nearestMeters: 1, meanConfidence: 1, sampleCount: 10, occupancy: c)
        }
        let before = [region(.left, .observedFree), region(.center, .unknown)]
        let after = [region(.left, .observedFree), region(.center, .occupied), region(.right, .unknown)]
        let changes = OccupancyDiff.changes(previous: before, current: after)
        #expect(changes == [OccupancyChange(region: .center, from: .unknown, to: .occupied),
                            OccupancyChange(region: .right, from: nil, to: .unknown)])
        #expect(OccupancyDiff.changes(previous: after, current: after).isEmpty)
    }

    @Test func latencyBreakdownUsesOnlyMeasuredValues() {
        let stages = LatencyBreakdown.stages(captureToResultMs: 60, endToEndMs: 40, preMs: 0, inferenceMs: 25,
                                             postMs: 5, fusionMs: nil, spatialMs: 12, depthRefineMs: nil,
                                             navigationComputeMs: nil, captureToDecisionMs: nil)
        let byName = Dictionary(uniqueKeysWithValues: stages.map { ($0.name, $0.ms) })
        #expect(byName["Unattributed"] == .some(10))
        #expect(byName["Capture → inference start"] == .some(20))
        #expect(byName["RGB+depth fusion"] == .some(nil))
        #expect(byName["Spatial algorithms"] == .some(12))

        let idle = LatencyBreakdown.stages(captureToResultMs: nil, endToEndMs: nil, preMs: nil, inferenceMs: nil,
                                           postMs: nil, fusionMs: nil, spatialMs: nil, depthRefineMs: nil,
                                           navigationComputeMs: nil, captureToDecisionMs: nil)
        #expect(idle.allSatisfy { $0.ms == nil }, "nothing running → nothing reported")

        let skew = LatencyBreakdown.stages(captureToResultMs: 30, endToEndMs: 20, preMs: 0, inferenceMs: 25,
                                           postMs: 1, fusionMs: nil, spatialMs: nil, depthRefineMs: nil,
                                           navigationComputeMs: nil, captureToDecisionMs: nil)
        #expect(skew.first { $0.name == "Unattributed" }?.ms == 0, "clock skew is clamped, not negative")
    }
}
