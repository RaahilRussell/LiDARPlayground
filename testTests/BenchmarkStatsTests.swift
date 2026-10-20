//
//  BenchmarkStatsTests.swift
//  testTests
//
//  Phase 9 — the statistics and counting rules behind the Benchmarks tab,
//  checked against hand-computed values.
//

import Foundation
import Testing
@testable import test

@MainActor
@Suite("Benchmark statistics")
struct BenchmarkStatsTests {

    // MARK: Percentiles / summary stats

    @Test func percentileInterpolatesBetweenRanks() {
        let s: [Double] = [1, 2, 3, 4]
        #expect(LatencyStats.percentile(sorted: s, 0) == 1)
        #expect(LatencyStats.percentile(sorted: s, 0.5) == 2.5)
        #expect(LatencyStats.percentile(sorted: s, 1) == 4)
        #expect(LatencyStats.percentile(sorted: s, 7) == 4, "clamped")
        #expect(LatencyStats.percentile(sorted: [], 0.5).isNaN)
    }

    @Test func summaryStatsMatchHandComputation() throws {
        let stats = try #require(LatencyStats(samples: (1...100).map(Double.init).shuffled()))
        #expect(stats.count == 100)
        #expect(stats.mean == 50.5)
        #expect(stats.min == 1 && stats.max == 100)
        #expect(abs(stats.p50 - 50.5) < 1e-9)
        #expect(abs(stats.p95 - 95.05) < 1e-9)
        #expect(abs(stats.p99 - 99.01) < 1e-9)

        let sd = try #require(LatencyStats(samples: [2, 4, 4, 4, 5, 5, 7, 9]))
        #expect(sd.stdDev == 2)
    }

    @Test func noSamplesMeansNoStatsNotZero() {
        #expect(LatencyStats(samples: []) == nil)
        #expect(LatencyStats(samples: [.nan, .infinity]) == nil)
        #expect(LatencyStats(samples: [.nan, 3])?.count == 1)
    }

    // MARK: Bounded buffer

    @Test func boundedBufferKeepsNewestInOrder() {
        var b = BoundedBuffer<Int>(capacity: 3)
        #expect(b.isEmpty && b.last == nil)
        for i in 1...5 { b.append(i) }
        #expect(b.elements == [3, 4, 5])
        #expect(b.count == 3 && b.last == 5 && b.totalAppended == 5)
        b.append(6)
        #expect(b.elements == [4, 5, 6])
        b.removeAll()
        #expect(b.isEmpty && b.totalAppended == 0)
    }

    // MARK: Dropped / skipped definitions

    @Test func missedCameraFrameRule() {
        let n = 1.0 / 60
        #expect(FrameCadenceCounter.missedSlots(gap: n, nominal: n) == 0)
        #expect(FrameCadenceCounter.missedSlots(gap: 1.4 * n, nominal: n) == 0, "jitter is not a drop")
        #expect(FrameCadenceCounter.missedSlots(gap: 1.6 * n, nominal: n) == 1)
        #expect(FrameCadenceCounter.missedSlots(gap: 2 * n, nominal: n) == 1)
        #expect(FrameCadenceCounter.missedSlots(gap: 3 * n, nominal: n) == 2)
        #expect(FrameCadenceCounter.missedSlots(gap: 1, nominal: 0) == 0)
    }

    @Test func cadenceCounterAccumulatesGaps() {
        let n = 1.0 / 60
        var c = FrameCadenceCounter(nominalInterval: n)
        for t in [0, n, 2 * n, 2 * n, 5 * n, 6 * n] { c.record(timestamp: t) }
        #expect(c.framesDelivered == 6)
        #expect(c.missedFrames == 2)                    // one 3-interval gap
        #expect(abs(c.longestGap - 3 * n) < 1e-12)
    }

    @Test func skippedInferenceSlotRule() {
        #expect(BenchmarkMath.skippedInferenceSlots(cycleSeconds: 0.05, targetInterval: 0.1) == 0)
        #expect(BenchmarkMath.skippedInferenceSlots(cycleSeconds: 0.15, targetInterval: 0.1) == 0, "late, not skipped")
        #expect(BenchmarkMath.skippedInferenceSlots(cycleSeconds: 0.2, targetInterval: 0.1) == 1)
        #expect(BenchmarkMath.skippedInferenceSlots(cycleSeconds: 0.35, targetInterval: 0.1) == 2)
        #expect(BenchmarkMath.skippedInferenceSlots(cycleSeconds: .nan, targetInterval: 0.1) == 0)
    }

    @Test func achievedRateUsesCompletionSpan() {
        #expect(BenchmarkMath.achievedRateHz(sampleCount: 11, firstTime: 5, lastTime: 6) == 10)
        #expect(BenchmarkMath.achievedRateHz(sampleCount: 1, firstTime: 5, lastTime: 5) == nil)
        #expect(BenchmarkMath.achievedRateHz(sampleCount: 3, firstTime: nil, lastTime: 6) == nil)
    }

    @Test func thermalTrackerRecordsStartLatestWorst() {
        var t = ThermalTracker()
        for s in [ProcessInfo.ThermalState.nominal, .nominal, .fair, .serious, .fair] { t.record(s) }
        #expect(t.start == .nominal && t.latest == .fair && t.worst == .serious)
        #expect(t.transitions == 3)
    }

    // MARK: Accumulator

    @Test func accumulatorExcludesWarmupAndForeignSamples() {
        var acc = VariantAccumulator(variant: .small, warmupSamples: 2, nominalFrameInterval: 1.0 / 60)
        acc.recordFrame(timestamp: 0)                    // before window → ignored
        acc.ingest(.notReady(.modelNotLoaded))
        let warm1 = acc.ingest(.completed(Fixtures.sample(.small, at: 1, inferenceMs: 500)))
        let warm2 = acc.ingest(.completed(Fixtures.sample(.small, at: 2, inferenceMs: 400)))
        #expect(!warm1 && !warm2)
        #expect(acc.isMeasuring && acc.measurementStart == 2)
        let foreign = acc.ingest(.completed(Fixtures.sample(.nano, at: 2.5)))
        #expect(!foreign, "other variant")
        for (i, ms) in [10.0, 20, 30].enumerated() {
            acc.ingest(.completed(Fixtures.sample(.small, at: 3 + Double(i), inferenceMs: ms, objects: 3, skipped: 1)))
        }
        for k in 0..<4 { acc.recordFrame(timestamp: 3 + Double(k) / 60) }

        let r = acc.summary(windowSeconds: 3, loadMs: 120, computeDescription: "test", outcome: .completed)
        #expect(r.measuredSamples == 3 && r.warmupDiscarded == 2)
        #expect(r.inference?.p50 == 20 && r.inference?.max == 30, "warm-up 500/400 ms excluded")
        #expect(r.achievedHz == 1)
        #expect(r.meanObjects == 3 && r.skippedSlots == 3)
        #expect(r.notReadyTicks == 1)
        #expect(r.cameraFramesDelivered == 4 && r.cameraFramesMissed == 0)
        #expect(r.loadMs == 120 && r.outcome == .completed)
        #expect(acc.foreignSamplesIgnored == 1)
    }

    @Test func zeroWarmupCountsFirstSampleAndCapIsEnforced() {
        var acc = VariantAccumulator(variant: .nano, warmupSamples: 0, nominalFrameInterval: 1.0 / 60)
        let counted = acc.ingest(.completed(Fixtures.sample(at: 0)))
        #expect(counted)
        for i in 1...(VariantAccumulator.maxSamples + 3) { acc.ingest(.completed(Fixtures.sample(at: Double(i)))) }
        #expect(acc.measuredCount == VariantAccumulator.maxSamples)
        #expect(acc.samplesOverCap == 4)
    }

    @Test func failedResultCarriesNoMeasurements() {
        let r = VariantBenchmarkResult.failed(.medium, reason: "Model file not bundled", computeDescription: "x")
        #expect(r.outcome == .failed("Model file not bundled"))
        #expect(r.inference == nil && r.achievedHz == nil && r.measuredSamples == 0 && r.longestFrameGapMs == nil)
    }

    @Test func plansCoverAllVariants() {
        #expect(BenchmarkPlan.compareAll.variants == ModelVariant.allCases)
        #expect(BenchmarkPlan.compareAll.totalSeconds == 60)
        #expect(BenchmarkPlan.profile(.small).totalSeconds == 60)
        #expect(BenchmarkPlan.profile(.small).variants == [.small])
    }
}
