//
//  PerceptionInspector.swift
//  test
//
//  Phase 8 — drives the Inspector tab. Two strictly separated sources:
//   • LIVE: polls the shared ARSession via ARSensorProvider (~4 Hz), reduces each
//     frame to metadata + small previews off the main actor (single in flight),
//     and logs spatial/proximity transitions from the live engines.
//   • DEMO: a deterministic synthetic scenario (DemoScenario) run through the
//     real occupancy + proximity logic with its OWN state machine. It never
//     feeds the live ProximityEvaluator and only reaches the Taptic Engine when
//     the user explicitly opts in. Demo output is always labeled DEMO.
//
//  Memory: no SensorFrame/ARFrame or pixel buffer is stored on this object; the
//  analysis task holds one snapshot only while it runs. History is bounded.
//

import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import Observation
import QuartzCore
import simd

/// Small, display-only images derived from one frame (≤ depth resolution).
nonisolated struct FramePreviews: @unchecked Sendable {   // CGImage is immutable
    var rgb: CGImage?
    var depth: CGImage?
    var confidence: CGImage?
    var stats: DepthStatistics?
}

@MainActor
@Observable
final class PerceptionInspector {
    enum Source: String, CaseIterable, Identifiable {
        case live = "Live sensors"
        case demo = "Demo (synthetic)"
        var id: String { rawValue }
    }

    static let pollInterval: Duration = .milliseconds(250)

    private(set) var source: Source = .live
    var previewsEnabled = true
    private(set) var metadata: FrameMetadata?
    private(set) var previews: FramePreviews?
    private(set) var previewProcessMs: Double?
    private(set) var log = EventLog()

    // Demo
    private(set) var demoRunning = false
    private(set) var demoOutput: DemoStepOutput?
    private(set) var demoDepthImage: CGImage?
    /// Off by default: demo transitions never vibrate unless explicitly enabled.
    var demoHapticsOptIn = false

    private weak var provider: ARSensorProvider?
    private weak var system: PerceptionSystem?
    private let modelConsumer = UUID()
    private let proximityConsumer = UUID()
    private(set) var runningModel = false
    private(set) var runningSpatialProximity = false
    @ObservationIgnored private var liveTask: Task<Void, Never>?
    @ObservationIgnored private var demoTask: Task<Void, Never>?
    @ObservationIgnored private var analysisInFlight = false
    @ObservationIgnored private var pollingOperation = 0
    @ObservationIgnored private var demoRunner = DemoRunner()
    @ObservationIgnored private var lastTrackingNormal: Bool?
    @ObservationIgnored private var lastOccupancy: [RegionOccupancy] = []
    @ObservationIgnored private var lastFloorPresent: Bool?
    @ObservationIgnored private var lastProximityEventId: UUID?
    @ObservationIgnored private var lastLoggedLiveState: ProximityState?
    @ObservationIgnored private var lastDemoOccupancy: [RegionOccupancy] = []

    func attach(provider: ARSensorProvider, system: PerceptionSystem) {
        self.provider = provider
        self.system = system
    }

    // MARK: - Lifecycle (driven by the view)

    func start() {
        guard liveTask == nil, source == .live else { return }
        pollingOperation += 1
        liveTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.liveTick()
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
    }

    /// View/background lifetime controls only polling and synthetic playback.
    /// Explicit model/proximity toggles control the app-wide live pipelines.
    func stop() {
        liveTask?.cancel(); liveTask = nil
        invalidatePreviews()
        stopDemo()
    }

    /// Backgrounding: same as stop; the view restarts polling on return.
    func pause() { stop() }

    func setSource(_ newSource: Source) {
        guard newSource != source else { return }
        source = newSource
        switch newSource {
        case .demo:
            // Demo has its own evaluator. Stop live polling, while preserving
            // real sensing used by other app features.
            liveTask?.cancel(); liveTask = nil
            invalidatePreviews()
            log.append(origin: .demo, kind: .system, message: "Demo mode ON — displaying synthetic data; live pipelines unchanged",
                       at: CACurrentMediaTime())
        case .live:
            stopDemo()
            demoOutput = nil
            demoDepthImage = nil
            log.append(origin: .live, kind: .system, message: "Live mode ON — demo stopped",
                       at: CACurrentMediaTime())
            start()
        }
    }

    func clearLog() { log.clear() }

    // MARK: - Live pipelines

    /// An explicit inspector demand. Turning this off releases only this
    /// consumer; Assist or another visible tool may still need the same engine.
    func setModelRunning(_ on: Bool) {
        guard let system, on != runningModel else { return }
        if on {
            guard source == .live else { return }
            system.acquire(.vision, for: modelConsumer)
        } else {
            system.release(modelConsumer)
        }
        runningModel = on
    }

    func setSpatialProximityRunning(_ on: Bool) {
        guard let system, on != runningSpatialProximity else { return }
        if on {
            guard source == .live else { return }
            system.acquire([.spatial, .proximity], for: proximityConsumer)
        } else {
            system.release(proximityConsumer)
        }
        runningSpatialProximity = on
    }

    // MARK: - Live polling

    private func liveTick() {
        guard source == .live, let provider, let system else { return }
        let now = CACurrentMediaTime()

        if let frame = provider.cameraSnapshot() {
            metadata = Self.metadata(of: frame, now: now)
            if lastTrackingNormal != frame.trackingIsNormal {
                if lastTrackingNormal != nil {
                    log.append(origin: .live, kind: .tracking,
                               message: frame.trackingIsNormal ? "Tracking normal" : "Tracking limited",
                               at: now)
                }
                lastTrackingNormal = frame.trackingIsNormal
            }
            if previewsEnabled && !analysisInFlight { analyze(frame) }
        } else {
            invalidatePreviews()
        }

        logSpatialChanges(system.spatial, at: now)
        logProximity(system.proximity)
    }

    /// Runs the pixel work off the main actor; the snapshot is released afterwards.
    private func analyze(_ frame: SensorFrame) {
        analysisInFlight = true
        let started = CACurrentMediaTime()
        let operation = pollingOperation
        let generation = provider?.sessionGeneration
        Task { [weak self] in
            let result = await Self.makePreviews(frame)
            guard let self else { return }
            self.analysisInFlight = false
            guard self.source == .live, self.liveTask != nil,
                  let provider = self.provider, let generation,
                  Self.acceptsPreview(operation: operation, currentOperation: self.pollingOperation,
                                      sessionGeneration: generation, currentSessionGeneration: provider.sessionGeneration,
                                      timestamp: frame.timestamp, now: CACurrentMediaTime()),
                  provider.isCurrentObservation(timestamp: frame.timestamp) else { return }
            self.previews = result
            self.previewProcessMs = (CACurrentMediaTime() - started) * 1000
        }
    }

    private func invalidatePreviews() {
        pollingOperation += 1
        metadata = nil
        previews = nil
        previewProcessMs = nil
    }

    nonisolated static func acceptsPreview(operation: Int, currentOperation: Int,
                                           sessionGeneration: Int, currentSessionGeneration: Int,
                                           timestamp: TimeInterval, now: TimeInterval) -> Bool {
        operation == currentOperation && sessionGeneration == currentSessionGeneration
            && ARSensorProvider.isFresh(timestamp: timestamp, now: now)
    }

    private func logSpatialChanges(_ spatial: SpatialAlgorithmsEngine, at now: TimeInterval) {
        guard runningSpatialProximity else { return }
        for change in OccupancyDiff.changes(previous: lastOccupancy, current: spatial.occupancy) where change.from != nil {
            log.append(origin: .live, kind: .occupancy,
                       message: "\(change.region.rawValue.uppercased()): \(change.from!.rawValue) → \(change.to.rawValue)",
                       at: now, latencyMs: spatial.lastMs)
        }
        lastOccupancy = spatial.occupancy
        let floorPresent = spatial.floor != nil
        if let last = lastFloorPresent, last != floorPresent {
            log.append(origin: .live, kind: .floor,
                       message: floorPresent ? "Floor plane found (\(spatial.floor?.inliers ?? 0) inliers)" : "Floor plane lost",
                       at: now)
        }
        lastFloorPresent = floorPresent
    }

    private func logProximity(_ proximity: ProximityEvaluator) {
        guard let event = proximity.lastEvent, event.id != lastProximityEventId else { return }
        lastProximityEventId = event.id
        guard event.state != lastLoggedLiveState else { return }
        lastLoggedLiveState = event.state
        let distance = event.distanceMeters.map { String(format: "%.2f m", $0) } ?? "no distance"
        let haptic = event.hapticEnqueuedAt != nil ? (event.patternName ?? "haptic") : "no haptic"
        let prefix = event.isSimulated ? "[simulated input] " : ""
        log.append(origin: .live, kind: .proximity,
                   message: "\(prefix)\(event.state.rawValue) · \(distance) · \(event.region?.rawValue ?? "—") · \(haptic)",
                   at: event.decidedAt, latencyMs: event.processingLatencyMs)
    }

    // MARK: - Demo

    func startDemo() {
        guard source == .demo, demoTask == nil else { return }
        demoRunning = true
        demoTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.stepDemo()
                try? await Task.sleep(for: .seconds(DemoScenario.tickSeconds))
            }
        }
    }

    func stopDemo() {
        demoTask?.cancel(); demoTask = nil
        demoRunning = false
    }

    func resetDemo() {
        demoRunner.reset()
        lastDemoOccupancy = []
        demoOutput = nil
        demoDepthImage = nil
    }

    /// One deterministic step (also used by the manual "Step" button).
    func stepDemo() {
        guard source == .demo else { return }
        let out = demoRunner.advance()
        demoOutput = out
        demoDepthImage = DepthRefinement.colorize(out.frame.depth, width: DemoScenario.depthWidth,
                                                  height: DemoScenario.depthHeight, range: 0...5)
        let now = CACurrentMediaTime()
        for change in OccupancyDiff.changes(previous: lastDemoOccupancy, current: out.occupancy) where change.from != nil {
            log.append(origin: .demo, kind: .occupancy,
                       message: "\(change.region.rawValue.uppercased()): \(change.from!.rawValue) → \(change.to.rawValue)",
                       at: now)
        }
        lastDemoOccupancy = out.occupancy
        guard out.stateChanged else { return }
        var message = "\(out.state.rawValue) · \(out.input.map { String(format: "%.2f m", $0) } ?? "no valid depth") · step \(out.frame.step)"
        if DemoRunner.shouldPlayHaptic(stateChanged: out.stateChanged, optedIn: demoHapticsOptIn),
           let pattern = ProximityEvaluator.pattern(for: out.state),
           system?.haptics.play(pattern) != nil {
            message += " · haptic (opt-in): \(pattern.rawValue)"
        } else {
            message += " · no haptic"
        }
        log.append(origin: .demo, kind: .proximity, message: message, at: now)
    }

    // MARK: - Pure-ish helpers

    static func metadata(of f: SensorFrame, now: TimeInterval) -> FrameMetadata {
        let pos = SIMD3<Float>(f.cameraTransform.columns.3.x, f.cameraTransform.columns.3.y,
                               f.cameraTransform.columns.3.z)
        return FrameMetadata(
            timestamp: f.timestamp,
            frameAgeMs: (now - f.timestamp) * 1000,
            imageWidth: CVPixelBufferGetWidth(f.capturedImage),
            imageHeight: CVPixelBufferGetHeight(f.capturedImage),
            imagePixelFormat: FourCC.string(CVPixelBufferGetPixelFormatType(f.capturedImage)),
            depthWidth: f.depthMap.map { CVPixelBufferGetWidth($0) },
            depthHeight: f.depthMap.map { CVPixelBufferGetHeight($0) },
            hasSmoothedDepth: f.smoothedDepthMap != nil,
            hasConfidence: f.confidenceMap != nil,
            trackingNormal: f.trackingIsNormal,
            fx: f.intrinsics[0][0], fy: f.intrinsics[1][1], cx: f.intrinsics[2][0], cy: f.intrinsics[2][1],
            position: pos)
    }

    nonisolated private static func makePreviews(_ frame: SensorFrame) async -> FramePreviews {
        await Task.detached(priority: .utility) {
            guard let depthMap = frame.depthMap else {
                let rgb = DepthRefinement.rgbImage(DepthRefinement.rgbGuide(frame.capturedImage, width: 256, height: 192),
                                                   width: 256, height: 192)
                return FramePreviews(rgb: rgb, depth: nil, confidence: nil, stats: nil)
            }
            let field = DepthRefinement.field(from: depthMap, confidence: frame.rawConfidenceMap)
            let w = field.width, h = field.height
            let guide = DepthRefinement.rgbGuide(frame.capturedImage, width: w, height: h)
            return FramePreviews(
                rgb: DepthRefinement.rgbImage(guide, width: w, height: h),
                depth: DepthRefinement.colorize(field.depth, width: w, height: h, range: 0...5),
                confidence: field.confidence.flatMap { Self.confidenceImage($0, width: w, height: h) },
                stats: DepthStatistics.compute(depth: field.depth, confidence: field.confidence))
        }.value
    }

    /// low = red, medium = amber, high = green.
    nonisolated static func confidenceImage(_ conf: [UInt8], width: Int, height: Int) -> CGImage? {
        guard conf.count == width * height else { return nil }
        var px = [UInt8](repeating: 255, count: width * height * 4)
        for i in 0..<conf.count {
            let o = i * 4
            switch conf[i] {
            case 0: px[o] = 235; px[o + 1] = 70; px[o + 2] = 70
            case 1: px[o] = 250; px[o + 1] = 190; px[o + 2] = 50
            default: px[o] = 70; px[o + 1] = 215; px[o + 2] = 110
            }
        }
        return px.withUnsafeMutableBytes { raw -> CGImage? in
            guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            return ctx.makeImage()
        }
    }
}
