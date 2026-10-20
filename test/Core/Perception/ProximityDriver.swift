//
//  ProximityDriver.swift
//  test
//
//  Phase 6 — feeds the ProximityEvaluator from GEOMETRY, independent of the
//  segmentation model (works with YOLO disabled). It uses the per-region nearest
//  depth + confidence from the spatial engine. A Training/Demo mode injects mock
//  obstacles for repeatable haptic tests, always flagged as simulated.
//

import Foundation
import Observation
import QuartzCore

@MainActor
@Observable
final class ProximityDriver {
    var running = false
    var demoMode = false
    var mockDistance: Float = 0.8
    var mockRegion: SpatialRegion = .center

    private unowned let proximity: ProximityEvaluator
    private unowned let spatial: SpatialAlgorithmsEngine
    private weak var provider: ARSensorProvider?
    private var loopTask: Task<Void, Never>?

    init(proximity: ProximityEvaluator, spatial: SpatialAlgorithmsEngine) {
        self.proximity = proximity
        self.spatial = spatial
    }

    func attach(provider: ARSensorProvider) { self.provider = provider }

    func start() {
        guard loopTask == nil else { return }
        running = true
        loopTask = Task { [weak self] in await self?.loop() }
    }
    func stop() { running = false; loopTask?.cancel(); loopTask = nil }

    private func loop() async {
        while !Task.isCancelled {
            if running { step() }
            try? await Task.sleep(for: .milliseconds(150))
        }
    }

    private func step() {
        let now = CACurrentMediaTime()
        if demoMode {
            proximity.evaluate(nearest: mockDistance, confidence: 1.0, region: mockRegion,
                               label: nil, isSimulated: true, inputTimestamp: now)
            return
        }
        // Real geometry: pick the nearest occupied/low-confidence region.
        let candidates = spatial.occupancy.filter {
            $0.occupancy == .occupied || $0.occupancy == .lowConfidence
        }
        if let nearest = candidates.min(by: {
            ($0.nearestMeters ?? .greatestFiniteMagnitude) < ($1.nearestMeters ?? .greatestFiniteMagnitude)
        }) {
            proximity.evaluate(nearest: nearest.nearestMeters, confidence: nearest.meanConfidence,
                               region: nearest.id, label: nil, isSimulated: false, inputTimestamp: now)
        } else if spatial.occupancy.allSatisfy({ $0.occupancy == .unknown }) && !spatial.occupancy.isEmpty {
            // Nothing observed → honestly report uncertain rather than "clear".
            proximity.evaluate(nearest: nil, confidence: nil, region: nil,
                               label: nil, isSimulated: false, inputTimestamp: now)
        }
    }
}
