//
//  PerceptionInspectorView.swift
//  test
//
//  Phase 8 — live sensor/frame metadata, raw-frame previews (RGB, depth,
//  confidence at depth resolution), model outputs, a bounded spatial/proximity
//  event history, and the measured latency breakdown. A deterministic DEMO
//  source is kept visibly separate from live inputs and from haptic output.
//

import CoreGraphics
import SwiftUI

struct PerceptionInspectorView: View {
    @Environment(ARSessionManager.self) private var ar
    @Environment(PerceptionSystem.self) private var perception
    @Environment(\.scenePhase) private var scenePhase
    private var inspector: PerceptionInspector { perception.inspector }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                sourcePicker
                switch inspector.source {
                case .live:
                    liveControls
                    metadataCard
                    previewCard
                    modelOutputCard
                    latencyCard
                case .demo:
                    demoCard
                }
                eventsCard
            }
            .padding(12)
        }
        .background(Theme.background)
        .onAppear {
            if ar.runState == .idle { ar.start() }
            inspector.start()
        }
        .onDisappear { inspector.stop() }
        // PerceptionSystem pauses the inspector when the app leaves the foreground;
        // resume live polling on return (demo stays paused until Play).
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { inspector.start() }
        }
    }

    // MARK: - Source

    private var sourcePicker: some View {
        Panel {
            VStack(alignment: .leading, spacing: 6) {
                Picker("Source", selection: Binding(get: { inspector.source },
                                                    set: { inspector.setSource($0) })) {
                    ForEach(PerceptionInspector.Source.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                if inspector.source == .demo {
                    Label("DEMO — synthetic, deterministic data. Live inputs are paused.",
                          systemImage: "theatermasks.fill")
                        .font(.caption).foregroundStyle(Theme.warn)
                }
            }
        }
    }

    private var liveControls: some View {
        Panel {
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Raw-frame previews (~4 Hz)", isOn: Binding(get: { inspector.previewsEnabled },
                                                                   set: { inspector.previewsEnabled = $0 }))
                Toggle("Run YOLO model", isOn: Binding(get: { inspector.runningModel },
                                                       set: { inspector.setModelRunning($0) }))
                Toggle("Run spatial + proximity pipeline", isOn: Binding(
                    get: { inspector.runningSpatialProximity },
                    set: { inspector.setSpatialProximityRunning($0) }))
                Text("The live proximity pipeline drives haptics when they are enabled in the Haptics tab (currently \(perception.haptics.enabled ? "ON" : "OFF")). Experimental prototype — not a navigation aid.")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.footnote)
            .tint(Theme.accent)
        }
    }

    // MARK: - Metadata

    @ViewBuilder private var metadataCard: some View {
        Panel {
            VStack(alignment: .leading, spacing: 6) {
                header("FRAME METADATA")
                if let m = inspector.metadata {
                    HStack {
                        Stat(label: "Timestamp", value: String(format: "%.3f s", m.timestamp))
                        Stat(label: "Frame age", value: String(format: "%.1f ms", m.frameAgeMs))
                        Stat(label: "Tracking", value: m.trackingNormal ? "Normal" : "Limited",
                             tint: m.trackingNormal ? Theme.good : Theme.warn)
                    }
                    HStack {
                        Stat(label: "RGB", value: "\(m.imageWidth)×\(m.imageHeight) \(m.imagePixelFormat)")
                        Stat(label: "Depth", value: m.depthWidth.map { "\($0)×\(m.depthHeight ?? 0)" } ?? "none",
                             tint: m.depthWidth == nil ? Theme.bad : .white)
                        Stat(label: "Smoothed/Conf", value: "\(m.hasSmoothedDepth ? "yes" : "no")/\(m.hasConfidence ? "yes" : "no")")
                    }
                    HStack {
                        Stat(label: "fx fy", value: String(format: "%.0f %.0f", m.fx, m.fy))
                        Stat(label: "cx cy", value: String(format: "%.0f %.0f", m.cx, m.cy))
                        Stat(label: "Pos (local m)", value: String(format: "%.2f %.2f %.2f", m.position.x, m.position.y, m.position.z))
                    }
                } else {
                    Text(ar.supportsWorldTracking ? "No frame yet — is the AR session running?"
                                                  : "No ARKit frames on this device/simulator.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Previews

    private var previewCard: some View {
        Panel {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    header("RAW FRAME PREVIEWS (depth resolution, sensor orientation)")
                    Spacer()
                    if let ms = inspector.previewProcessMs {
                        Text(String(format: "%.0f ms", ms)).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if let p = inspector.previews, inspector.previewsEnabled {
                    HStack(spacing: 6) {
                        preview(p.rgb, "RGB")
                        preview(p.depth, "Depth 0–5 m")
                        preview(p.confidence, "Confidence")
                    }
                    if let s = p.stats {
                        HStack {
                            Stat(label: "Valid", value: String(format: "%.0f%%", s.validFraction * 100))
                            Stat(label: "Min", value: meters(s.minMeters))
                            Stat(label: "Median", value: meters(s.medianMeters))
                            Stat(label: "Max", value: meters(s.maxMeters))
                        }
                        if let lo = s.confidenceLow, let mid = s.confidenceMedium, let hi = s.confidenceHigh {
                            Text(String(format: "Confidence low %.0f%% · medium %.0f%% · high %.0f%%", lo * 100, mid * 100, hi * 100))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Text("Magenta = no valid depth (never treated as free space).")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                } else {
                    Text(inspector.previewsEnabled ? "Waiting for a frame…" : "Previews off.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func preview(_ image: CGImage?, _ title: String) -> some View {
        VStack(spacing: 2) {
            Group {
                if let image {
                    Image(decorative: image, scale: 1, orientation: .right)
                        .resizable().interpolation(.none).scaledToFit()
                } else {
                    Rectangle().fill(Color.black.opacity(0.3))
                        .overlay(Text("n/a").font(.caption2).foregroundStyle(.secondary))
                }
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(3.0 / 4.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            Text(title).font(.system(size: 9)).foregroundStyle(.secondary)
        }
    }

    // MARK: - Model outputs

    private var modelOutputCard: some View {
        let vision = perception.vision
        return Panel {
            VStack(alignment: .leading, spacing: 6) {
                header("MODEL OUTPUTS")
                if let r = vision.latestResult {
                    HStack {
                        Stat(label: "Model", value: r.modelVariant.displayName)
                        Stat(label: "Objects", value: "\(r.objects.count)")
                        Stat(label: "Classes", value: "\(r.classNames.count)")
                        Stat(label: "Mask", value: r.maskDegenerate ? "EMPTY" : (r.combinedMask != nil ? "yes" : "none"),
                             tint: r.maskDegenerate ? Theme.warn : .white)
                    }
                    ForEach(r.objects.prefix(8)) { o in
                        HStack {
                            Text(o.label).font(.caption.bold())
                            Spacer()
                            Text(String(format: "%.0f%%", o.confidence * 100)).font(Theme.mono)
                            Text(String(format: "x%.2f y%.2f w%.2f h%.2f", o.boxNormalized.minX, o.boxNormalized.minY,
                                        o.boxNormalized.width, o.boxNormalized.height))
                                .font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                        }
                    }
                    if r.objects.count > 8 {
                        Text("+\(r.objects.count - 8) more").font(.caption2).foregroundStyle(.secondary)
                    }
                    Text("Compute: \(vision.computeOption.effectiveDescription) · frame \(String(format: "%.3f", r.frameTimestamp)) s")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                } else {
                    Text(vision.isEnabled ? "Model running — waiting for first result (\(String(describing: vision.loadState)))."
                                          : "Model not running. Toggle “Run YOLO model” above.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Latency

    private var latencyCard: some View {
        let p = perception
        let r = p.vision.latestResult
        let event = p.proximity.lastEvent
        let stages = LatencyBreakdown.stages(
            captureToResultMs: r?.captureToResultMs, endToEndMs: r?.endToEndMs, preMs: r?.preprocessMs,
            inferenceMs: r?.inferenceMs, postMs: r?.postprocessMs,
            fusionMs: positive(p.fusion.lastFusionMs), spatialMs: positive(p.spatial.lastMs),
            depthRefineMs: positive(p.depth.lastProcessMs),
            proximityDecisionMs: event?.processingLatencyMs,
            hapticEnqueueMs: event.flatMap { e in e.hapticEnqueuedAt.map { ($0 - e.decidedAt) * 1000 } })
        return Panel {
            VStack(alignment: .leading, spacing: 4) {
                header("LATENCY BREAKDOWN (last measured, ms)")
                ForEach(stages) { s in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(s.name).font(.caption)
                            Text(s.note).font(.system(size: 8)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(s.ms.map { String(format: "%.1f", $0) } ?? "—")
                            .font(Theme.mono)
                            .foregroundStyle(s.ms == nil ? Color.secondary : Theme.accent)
                    }
                }
                Text("“—” = stage not running or not yet measured. Fusion/spatial/depth values persist from their last pass.")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func positive(_ v: Double) -> Double? { v > 0 ? v : nil }

    // MARK: - Demo

    private var demoCard: some View {
        Panel {
            VStack(alignment: .leading, spacing: 8) {
                header("DEMO SCENARIO (synthetic · \(DemoScenario.length) steps × \(String(format: "%.2f", DemoScenario.tickSeconds)) s)")
                HStack {
                    Button(inspector.demoRunning ? "Pause" : "Play") {
                        inspector.demoRunning ? inspector.stopDemo() : inspector.startDemo()
                    }
                    .buttonStyle(.borderedProminent).tint(Theme.warn)
                    Button("Step") { inspector.stepDemo() }.buttonStyle(.bordered).disabled(inspector.demoRunning)
                    Button("Reset") { inspector.resetDemo() }.buttonStyle(.bordered)
                    Spacer()
                }
                if let out = inspector.demoOutput {
                    HStack(alignment: .top, spacing: 8) {
                        Group {
                            if let img = inspector.demoDepthImage {
                                Image(decorative: img, scale: 1).resizable().interpolation(.none).scaledToFit()
                            }
                        }
                        .frame(width: 120)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(alignment: .topLeading) {
                            Text("SYNTHETIC").font(.system(size: 8, weight: .bold))
                                .padding(2).background(Theme.warn).foregroundStyle(.black)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Step \(out.frame.step) · \(out.frame.segment.rawValue)").font(.caption.bold())
                            Text("Proximity: \(out.state.rawValue)").font(.caption)
                                .foregroundStyle(stateColor(out.state))
                            Text("Input: \(out.input.map { String(format: "%.2f m", $0) } ?? "none (no valid depth)")")
                                .font(.caption2).foregroundStyle(.secondary)
                            HStack(spacing: 4) {
                                ForEach(out.occupancy) { r in
                                    Text("\(r.id.rawValue.prefix(1).uppercased()):\(r.occupancy.rawValue)")
                                        .font(.system(size: 8, design: .monospaced))
                                }
                            }
                        }
                    }
                } else {
                    Text("Press Play or Step. Same steps always produce the same output.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Toggle("Play haptics for demo transitions (opt-in)", isOn: Binding(
                    get: { inspector.demoHapticsOptIn }, set: { inspector.demoHapticsOptIn = $0 }))
                    .font(.footnote).tint(Theme.warn)
                Text("Demo uses the real occupancy + proximity logic with its own state machine; it never feeds the live proximity evaluator, and it only vibrates with the opt-in above.")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Events

    private var eventsCard: some View {
        Panel {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    header("EVENT HISTORY (last \(EventLog.capacity))")
                    Spacer()
                    Button("Clear") { inspector.clearLog() }.font(.caption2)
                }
                let events = inspector.log.newestFirst
                if events.isEmpty {
                    Text("No events yet. Enable the spatial + proximity pipeline, or run the demo.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(events.prefix(40)) { e in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(e.origin.rawValue)
                            .font(.system(size: 8, weight: .bold))
                            .padding(.horizontal, 3).padding(.vertical, 1)
                            .background((e.origin == .demo ? Theme.warn : Theme.accent).opacity(0.25))
                            .foregroundStyle(e.origin == .demo ? Theme.warn : Theme.accent)
                        Text(e.kind.rawValue).font(.system(size: 9, weight: .semibold)).frame(width: 62, alignment: .leading)
                        Text(e.message).font(.system(size: 10)).lineLimit(2)
                        Spacer(minLength: 0)
                        if let ms = e.latencyMs {
                            Text(String(format: "%.1f ms", ms)).font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func header(_ text: String) -> some View {
        Text(text).font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
    }

    private func meters(_ v: Float?) -> String { v.map { String(format: "%.2f m", $0) } ?? "—" }

    private func stateColor(_ s: ProximityState) -> Color {
        switch s {
        case .clear: return Theme.good
        case .caution: return Theme.accent
        case .near: return Theme.warn
        case .critical: return Theme.bad
        case .uncertain: return .gray
        }
    }
}
