//
//  DepthTabView.swift
//  test
//
//  Feature 2 — Depth heatmap + numeric stats + tap-to-measure + range control.
//  Feature 3 — Confidence heatmap, confidence filter, usable-depth %.
//  Feature 9 — Experimental centre-point distance probe.
//
//  Depth buffers are tiny (256×192), but we still process them off the main
//  thread and throttle to ~12 Hz. The heatmap is shown aspect-fit with a 90°
//  orientation so portrait taps map cleanly back to buffer coordinates.
//  NOTE: exact overlay alignment with the live camera is awaiting on-device
//  verification (no LiDAR in Simulator).
//

import ARKit
import SwiftUI

struct DepthTabView: View {
    @Environment(ARSessionManager.self) private var ar

    @State private var heatmap: CGImage?
    @State private var stats: DepthStats?
    @State private var showConfidence = false
    @State private var filterLowConfidence = false
    @State private var rangeMax: Float = 5.0

    // Measurement probe (normalized buffer coordinates, origin top-left landscape).
    @State private var probePoint = CGPoint(x: 0.5, y: 0.5)
    @State private var probeMeters: Float?
    @State private var probeConfidence: Int?

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            if !ar.supportsSceneDepth {
                unsupported
            } else {
                VStack(spacing: 10) {
                    heatmapView
                    controls
                    statsPanel
                }
                .padding(10)
            }
        }
        .task(id: taskKey) { await runProcessingLoop() }
    }

    /// Restart the loop when a user toggle changes what we render.
    private var taskKey: String {
        "\(showConfidence)-\(filterLowConfidence)-\(rangeMax)-\(ar.depthSource.rawValue)"
    }

    // MARK: - Heatmap + probe

    private var heatmapView: some View {
        GeometryReader { geo in
            let fitted = fittedRect(in: geo.size)
            ZStack(alignment: .topLeading) {
                Color.black
                if let heatmap {
                    Image(decorative: heatmap, scale: 1, orientation: .right)
                        .resizable()
                        .scaledToFit()
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                crosshair(in: fitted)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in updateProbe(location: value.location, fitted: fitted) }
            )
        }
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func crosshair(in fitted: CGRect) -> some View {
        // buffer(bx,by) -> displayed(dx,dy) for 90° CW: dx = 1 - by, dy = bx
        let dx = 1 - probePoint.y
        let dy = probePoint.x
        let px = fitted.minX + CGFloat(dx) * fitted.width
        let py = fitted.minY + CGFloat(dy) * fitted.height
        return Image(systemName: "plus.circle")
            .font(.system(size: 22, weight: .bold))
            .foregroundStyle(.white)
            .shadow(radius: 2)
            .position(x: px, y: py)
    }

    private func updateProbe(location: CGPoint, fitted: CGRect) {
        guard fitted.contains(location) else { return }
        let dx = (location.x - fitted.minX) / fitted.width
        let dy = (location.y - fitted.minY) / fitted.height
        // invert 90° CW: bx = dy, by = 1 - dx
        probePoint = CGPoint(x: dy, y: 1 - dx)
    }

    /// Aspect-fit rect for the portrait-oriented (3:4) depth image.
    private func fittedRect(in size: CGSize) -> CGRect {
        guard let heatmap else { return CGRect(origin: .zero, size: size) }
        // After the .right orientation the displayed image is height×width.
        let imgAspect = CGFloat(heatmap.height) / CGFloat(heatmap.width) // e.g. 192/256
        let boxAspect = size.width / size.height
        var w = size.width, h = size.height
        if imgAspect > boxAspect { // image relatively taller -> limit by height
            h = size.height
            w = h * imgAspect
        } else {
            w = size.width
            h = w / imgAspect
        }
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    // MARK: - Controls

    private var controls: some View {
        Panel {
            VStack(spacing: 10) {
                HStack {
                    Picker("Source", selection: Binding(
                        get: { ar.depthSource },
                        set: { ar.depthSource = $0 })) {
                        ForEach(DepthSource.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .disabled(!ar.supportsSmoothedSceneDepth)
                }
                Toggle("Confidence heatmap", isOn: $showConfidence)
                    .font(.footnote)
                Toggle("Hide low-confidence pixels", isOn: $filterLowConfidence)
                    .font(.footnote)
                if !showConfidence {
                    HStack {
                        Text("Range").font(.caption).foregroundStyle(.secondary)
                        Slider(value: $rangeMax, in: 1...10, step: 0.5)
                        Text(String(format: "0–%.1f m", rangeMax))
                            .font(Theme.mono).frame(width: 70, alignment: .trailing)
                    }
                }
            }
            .tint(Theme.accent)
        }
    }

    // MARK: - Stats + probe readout

    private var statsPanel: some View {
        Panel {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Stat(label: "Min", value: statString(\.minMeters))
                    Stat(label: "Median", value: statString(\.medianMeters))
                    Stat(label: "Max", value: statString(\.maxMeters))
                }
                HStack {
                    Stat(label: "Resolution",
                         value: stats.map { "\($0.width)×\($0.height)" } ?? "—")
                    Stat(label: "Center",
                         value: stats?.centerMeters.map { String(format: "%.2f m", $0) } ?? "—")
                    Stat(label: "Valid",
                         value: stats.map { String(format: "%.0f%%", $0.validFraction * 100) } ?? "—",
                         tint: Theme.accent)
                }
                Divider().overlay(Theme.panelStroke)
                distanceProbe
            }
        }
    }

    /// Feature 9 — horizontal distance indicator + confidence for the probe point.
    private var distanceProbe: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Distance probe", systemImage: "scope")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(probeMeters.map { String(format: "%.2f m", $0) } ?? "no reading")
                    .font(Theme.mono)
                    .foregroundStyle(probeMeters == nil ? Theme.bad : .white)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.panelStroke).frame(height: 8)
                    Capsule()
                        .fill(Theme.accent)
                        .frame(width: probeBarWidth(g.size.width), height: 8)
                }
            }
            .frame(height: 8)
            HStack {
                Text("Confidence: \(confidenceLabel)")
                    .font(.caption2).foregroundStyle(confidenceTint)
                Spacer()
                Text("Demo only — not certified obstacle detection.")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
    }

    private func probeBarWidth(_ full: CGFloat) -> CGFloat {
        guard let m = probeMeters else { return 0 }
        return full * CGFloat(min(1, max(0, m / rangeMax)))
    }

    private var confidenceLabel: String {
        switch probeConfidence {
        case 0: return "Low"
        case 1: return "Medium"
        case 2: return "High"
        default: return "—"
        }
    }

    private var confidenceTint: Color {
        switch probeConfidence {
        case 0: return Theme.bad
        case 1: return Theme.warn
        case 2: return Theme.good
        default: return .secondary
        }
    }

    private func statString(_ kp: KeyPath<DepthStats, Float>) -> String {
        guard let stats else { return "—" }
        return String(format: "%.2f m", stats[keyPath: kp])
    }

    // MARK: - Processing loop

    private func runProcessingLoop() async {
        while !Task.isCancelled {
            if ar.runState == .running,
               let frame = ar.session.currentFrame,
               let depth = selectedDepth(frame) {
                let depthMap = depth.depthMap
                let confMap = depth.confidenceMap
                let mode: HeatmapMode = showConfidence ? .confidence : .depth(range: 0...rangeMax)
                let minConf: ARConfidenceLevel? = filterLowConfidence ? .medium : nil

                let result = await Self.process(depth: depthMap, confidence: confMap,
                                                mode: mode, minConf: minConf)
                heatmap = result.image
                stats = result.stats

                if let p = probeMeters(depth: depthMap, at: probePoint) {
                    probeMeters = p
                } else {
                    probeMeters = nil
                }
                probeConfidence = confMap.flatMap {
                    DepthProcessing.sampleConfidence($0, normalizedPoint: probePoint)
                }
            }
            try? await Task.sleep(for: .milliseconds(80))
        }
    }

    private func probeMeters(depth: CVPixelBuffer, at p: CGPoint) -> Float? {
        DepthProcessing.sampleDistance(depth: depth, normalizedPoint: p)
    }

    private func selectedDepth(_ frame: ARFrame) -> ARDepthData? {
        switch ar.depthSource {
        case .smoothed: return frame.smoothedSceneDepth ?? frame.sceneDepth
        case .raw: return frame.sceneDepth ?? frame.smoothedSceneDepth
        }
    }

    nonisolated private static func process(depth: CVPixelBuffer,
                                            confidence: CVPixelBuffer?,
                                            mode: HeatmapMode,
                                            minConf: ARConfidenceLevel?)
    async -> (image: CGImage?, stats: DepthStats) {
        await Task.detached(priority: .userInitiated) {
            let image = DepthProcessing.makeHeatmap(depth: depth, confidence: confidence,
                                                    mode: mode, minConfidence: minConf)
            let stats = DepthProcessing.computeStats(depth: depth, confidence: confidence,
                                                     minConfidence: minConf)
            return (image, stats)
        }.value
    }

    private var unsupported: some View {
        ComingSoonView(title: "Depth needs a LiDAR device",
                       milestone: "sceneDepth isn't available here. Run on your iPhone 15 Pro Max to see the depth heatmap and measurements.",
                       systemImage: "exclamationmark.triangle.fill")
    }
}
