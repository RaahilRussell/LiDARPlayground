//
//  SpatialFusionEngine.swift
//  test
//
//  Phase 3 — fuses YOLO detections with LiDAR depth to build 3D object
//  observations. For each detection we map its (portrait-normalized) box into the
//  depth buffer, ERODE it to cut edge contamination, and take ROBUST PERCENTILE
//  depth over only valid + confident pixels. Objects with too little valid depth
//  are marked uncertain — a class label is never treated as proof of geometry.
//
//  NOTE: this build erodes the bounding box (central crop) rather than the raw
//  instance mask; mask-pixel erosion is a documented future refinement. The
//  robust statistics + coverage gating still guard against edge contamination.
//

import ARKit
import Observation
import QuartzCore
import simd

@MainActor
@Observable
final class SpatialFusionEngine {
    private(set) var observations: [ObjectObservation] = []
    private(set) var lastFusionMs: Double = 0
    var erosion: Float = 0.15          // fraction trimmed from each box side
    var minCoverage: Float = 0.15      // below this → uncertain
    var nearPercentile: Float = 0.15

    private weak var provider: ARSensorProvider?
    private weak var vision: VisionInferenceEngine?
    private var loopTask: Task<Void, Never>?
    private var lastDetectionTimestamp: TimeInterval = -1
    private(set) var sessionGeneration: Int = -1

    func attach(provider: ARSensorProvider, vision: VisionInferenceEngine) {
        self.provider = provider
        self.vision = vision
    }

    func start() {
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in await self?.loop() }
    }
    func stop() { loopTask?.cancel(); loopTask = nil; clearResults() }

    func clearResults() { observations = []; lastDetectionTimestamp = -1 }

    private func loop() async {
        while !Task.isCancelled {
            await tick()
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func tick() async {
        guard let provider, let vision else { return }
        if sessionGeneration != provider.sessionGeneration {
            clearResults()
            sessionGeneration = provider.sessionGeneration
        }
        observations.removeAll {
            !ARSensorProvider.isFresh(timestamp: $0.timestamp, now: CACurrentMediaTime())
        }
        guard provider.isRunning, provider.snapshot() != nil,
              vision.resultSessionGeneration == provider.sessionGeneration,
              let result = vision.latestResult,
              result.frameTimestamp != lastDetectionTimestamp,
              let frame = vision.latestFrame,
              frame.timestamp == result.frameTimestamp,
              ARSensorProvider.isFresh(timestamp: frame.timestamp, now: CACurrentMediaTime()),
              let depthMap = frame.smoothedDepthMap ?? frame.depthMap else { return }
        lastDetectionTimestamp = result.frameTimestamp

        let start = CACurrentMediaTime()
        let obs = Self.fuse(objects: result.objects, frame: frame, depthMap: depthMap,
                            erosion: erosion, minCoverage: minCoverage, nearPct: nearPercentile)
        lastFusionMs = (CACurrentMediaTime() - start) * 1000
        observations = obs
    }

    // MARK: - Fusion math (pure)

    nonisolated static func fuse(objects: [DetectedObject], frame: SensorFrame,
                                 depthMap: CVPixelBuffer, erosion: Float,
                                 minCoverage: Float, nearPct: Float) -> [ObjectObservation] {
        let dw = CVPixelBufferGetWidth(depthMap)
        let dh = CVPixelBufferGetHeight(depthMap)
        guard dw > 0, dh > 0 else { return [] }
        let confidenceMatches = frame.confidenceMap.map {
            CVPixelBufferGetWidth($0) == dw && CVPixelBufferGetHeight($0) == dh
        } ?? false
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
        if let c = frame.confidenceMap { CVPixelBufferLockBaseAddress(c, .readOnly) }
        defer { if let c = frame.confidenceMap { CVPixelBufferUnlockBaseAddress(c, .readOnly) } }

        guard let dbase = CVPixelBufferGetBaseAddress(depthMap) else { return [] }
        let drb = CVPixelBufferGetBytesPerRow(depthMap)
        let cbase = confidenceMatches ? frame.confidenceMap.flatMap { CVPixelBufferGetBaseAddress($0) } : nil
        let crb = frame.confidenceMap.map { CVPixelBufferGetBytesPerRow($0) } ?? 0
        let now = CACurrentMediaTime()

        var results: [ObjectObservation] = []
        for obj in objects {
            let requestedBox = obj.boxNormalized
            guard requestedBox.minX.isFinite, requestedBox.minY.isFinite,
                  requestedBox.maxX.isFinite, requestedBox.maxY.isFinite else { continue }
            let box = requestedBox.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            guard !box.isNull, !box.isEmpty else { continue }
            // Portrait (.right) box → depth-buffer normalized rect (90° CW mapping):
            // bx = dy, by = 1 - dx  ⇒  bx∈[box.minY,box.maxY], by∈[1-box.maxX,1-box.minX]
            var bxMin = Float(box.minY), bxMax = Float(box.maxY)
            var byMin = Float(1 - box.maxX), byMax = Float(1 - box.minX)
            // Erode (central crop).
            let ex = (bxMax - bxMin) * erosion, ey = (byMax - byMin) * erosion
            bxMin += ex; bxMax -= ex; byMin += ey; byMax -= ey
            guard bxMax > bxMin, byMax > byMin else { continue }

            let x0 = max(0, Int(bxMin * Float(dw))), x1 = min(dw - 1, Int(bxMax * Float(dw)))
            let y0 = max(0, Int(byMin * Float(dh))), y1 = min(dh - 1, Int(byMax * Float(dh)))
            guard x1 >= x0, y1 >= y0 else { continue }

            var depths = [Float](); depths.reserveCapacity((x1 - x0 + 1) * (y1 - y0 + 1))
            var total = 0, confSum = 0, confCount = 0
            for y in y0...y1 {
                let drow = dbase.advanced(by: y * drb).assumingMemoryBound(to: Float32.self)
                let crow = cbase?.advanced(by: y * crb).assumingMemoryBound(to: UInt8.self)
                for x in x0...x1 {
                    total += 1
                    let d = drow[x]
                    if d.isFinite && d > 0, let crow,
                       Int(crow[x]) >= ARConfidenceLevel.medium.rawValue {
                        depths.append(d)
                        confSum += Int(crow[x]); confCount += 1
                    }
                }
            }

            let coverage = total > 0 ? Float(depths.count) / Float(total) : 0
            let depthConf = confCount > 0 ? Float(confSum) / Float(confCount) / 2.0 : 0
            let uncertain = coverage < minCoverage || depths.count < 8

            depths.sort()
            let near = depths.isEmpty ? Float.nan : percentile(depths, nearPct)
            let median = depths.isEmpty ? Float.nan : percentile(depths, 0.5)

            // 3D position from the eroded-box centre at median depth.
            let cxn = (bxMin + bxMax) / 2, cyn = (byMin + byMax) / 2
            let cam = unprojectCamera(nx: cxn, ny: cyn, depth: median.isFinite ? median : 1,
                                      intrinsics: frame.intrinsics, dw: dw, dh: dh,
                                      imageRes: frame.imageResolution)
            let world: SIMD3<Float>? = frame.trackingIsNormal && !uncertain
                ? { let w = frame.cameraTransform * SIMD4<Float>(cam, 1); return SIMD3(w.x, w.y, w.z) }()
                : nil
            let azimuth = atan2(cam.x, -cam.z) * 180 / .pi

            // Region from horizontal box centre in the portrait display.
            let centerX = box.midX
            let region: SpatialRegion = centerX < 0.4 ? .left : (centerX > 0.6 ? .right : .center)

            results.append(ObjectObservation(
                id: obj.id, label: obj.label, confidence: obj.confidence,
                validDepthCoverage: coverage, depthConfidence: depthConf,
                nearestMeters: near, medianMeters: median,
                positionCamera: cam, positionWorld: world,
                azimuthDegrees: azimuth, region: region,
                boxNormalized: box, timestamp: frame.timestamp,
                ageSeconds: max(0, now - frame.timestamp), uncertain: uncertain))
        }
        return results
    }

    nonisolated static func percentile(_ sorted: [Float], _ p: Float) -> Float {
        guard !sorted.isEmpty else { return .nan }
        let idx = min(sorted.count - 1, max(0, Int(p * Float(sorted.count - 1))))
        return sorted[idx]
    }

    nonisolated static func unprojectCamera(nx: Float, ny: Float, depth d: Float,
                                            intrinsics: simd_float3x3, dw: Int, dh: Int,
                                            imageRes: CGSize) -> SIMD3<Float> {
        let sx = Float(dw) / Float(imageRes.width)
        let sy = Float(dh) / Float(imageRes.height)
        let fx = intrinsics[0][0] * sx, fy = intrinsics[1][1] * sy
        let cx = intrinsics[2][0] * sx, cy = intrinsics[2][1] * sy
        let u = nx * Float(dw), v = ny * Float(dh)
        let xc = (u - cx) * d / fx
        let yc = (v - cy) * d / fy
        return SIMD3<Float>(xc, -yc, -d)
    }
}
