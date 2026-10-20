//
//  DepthAlgorithmTests.swift
//  testTests
//
//  Phase 9 — depth refinement filters: invalid depth is never invented,
//  confidence is respected, and smoothing never crosses discontinuities.
//

import Foundation
import Testing
@testable import test

@MainActor
@Suite("Depth refinement")
struct DepthAlgorithmTests {

    @Test func fieldExtractionZeroesInvalidDepth() throws {
        let values: [Float] = [1.5, .nan, -2, 0, .infinity, 3.25]
        let buffer = try #require(Fixtures.depthBuffer(width: 3, height: 2, values: values))
        let f = DepthRefinement.field(from: buffer, confidence: nil)
        #expect(f.width == 3 && f.height == 2)
        #expect(f.depth == [1.5, 0, 0, 0, 0, 3.25])
        #expect(f.confidence == nil)
        #expect(abs(f.validFraction - 2.0 / 6.0) < 1e-9)
    }

    @Test func medianRemovesSpikeAndKeepsInvalid() {
        var f = Fixtures.field(width: 5, height: 5, value: 2)
        f.depth[12] = 5        // spike in the centre
        f.depth[0] = 0         // invalid corner
        let out = DepthRefinement.confidenceMedian(f, params: FilterParams(kernelRadius: 1))
        #expect(out[12] == 2)
        #expect(out[0] == 0, "invalid pixels must stay invalid")
    }

    @Test func medianIgnoresLowConfidenceNeighbours() {
        var f = Fixtures.field(width: 3, height: 3, value: 9, confidence: 0)
        f.depth[4] = 2
        f.confidence?[4] = 2
        let out = DepthRefinement.confidenceMedian(f, params: FilterParams(kernelRadius: 1, minConfidence: 2))
        #expect(out[4] == 2, "only the confident centre sample may contribute")
    }

    @Test func bilateralDoesNotCrossDiscontinuity() {
        let f = Fixtures.stepField()
        let out = DepthRefinement.jointBilateral(f, guide: nil,
                                                 params: FilterParams(kernelRadius: 2, discontinuityThreshold: 0.15))
        for (i, v) in out.enumerated() {
            #expect(abs(v - f.depth[i]) < 1e-5, "pixel \(i) leaked across the edge: \(v)")
        }
    }

    @Test func bilateralNeverFillsHoles() {
        var f = Fixtures.field(width: 5, height: 5, value: 2)
        f.depth[12] = 0
        let out = DepthRefinement.jointBilateral(f, guide: nil, params: FilterParams())
        #expect(out[12] == 0)
    }

    @Test func temporalBlendsOnlyAgreeingPixels() {
        let f = Fixtures.field(width: 2, height: 1, value: 2)
        let params = FilterParams(discontinuityThreshold: 0.15, temporalStrength: 0.5)
        let out = DepthRefinement.temporal(f, previous: [2.1, 3.0], params: params)
        #expect(abs(out[0] - 2.05) < 1e-5)
        #expect(out[1] == 2, "disagreeing history is rejected")
        #expect(DepthRefinement.temporal(f, previous: [1], params: params) == f.depth, "size mismatch → no blend")
        #expect(DepthRefinement.temporal(f, previous: nil, params: params) == f.depth)
    }

    @Test func edgesMarkOnlyTheDiscontinuity() {
        let f = Fixtures.stepField(width: 8, height: 6)
        let e = DepthRefinement.edges(f.depth, width: 8, height: 6, threshold: 0.5)
        for y in 1..<5 {
            #expect(e[y * 8 + 3] && e[y * 8 + 4], "row \(y) boundary not detected")
            #expect(!e[y * 8 + 1] && !e[y * 8 + 6], "flat region flagged in row \(y)")
        }
    }
}
