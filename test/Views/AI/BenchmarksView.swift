//
//  BenchmarksView.swift
//  test
//
//  Phase 7 — real nano/small/medium comparison and a cancellable 60-second
//  profiler over live ARKit frames. Every number is a measurement from the
//  shared VisionInferenceEngine (see BenchmarkProfiler / BenchmarkStats); when
//  something wasn't measured it shows "—", never a placeholder value.
//

import SwiftUI

struct BenchmarksView: View {
    @Environment(ARSessionManager.self) private var ar
    @Environment(PerceptionSystem.self) private var perception
    private var profiler: BenchmarkProfiler { perception.profiler }
    private var vision: VisionInferenceEngine { perception.vision }

    @State private var profileVariant: ModelVariant = .nano

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                controlCard
                if profiler.isRunning || !profiler.graph.isEmpty { graphCard }
                if !profiler.results.isEmpty { resultsCard }
                definitionsCard
            }
            .padding(12)
        }
        .background(Theme.background)
        .onAppear { vision.refreshModelPresence() }
        // Other tabs start/stop the shared engine on appear/disappear, so a run
        // can't continue unobserved: leaving the tab cancels and restores config.
        .onDisappear { profiler.cancel(reason: "Left the Bench tab") }
    }

    // MARK: - Controls

    private var controlCard: some View {
        Panel {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("PROFILER").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                    Spacer()
                    phaseBadge
                }
                if profiler.isRunning {
                    ProgressView(value: profiler.progress).tint(Theme.accent)
                    HStack {
                        Stat(label: "Window", value: String(format: "%.1f s", profiler.currentWindowElapsed))
                        Stat(label: "Samples", value: "\(profiler.liveSampleCount)")
                        Stat(label: "Last E2E", value: profiler.liveLastEndToEndMs.map { String(format: "%.1f ms", $0) } ?? "—")
                        Stat(label: "Thermal", value: profiler.liveThermal.label, tint: profiler.liveThermal.color)
                    }
                    Button(role: .destructive) {
                        profiler.cancel(reason: "Cancelled by user")
                    } label: {
                        Label("Cancel", systemImage: "stop.circle.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).tint(Theme.bad)
                } else {
                    Button {
                        profiler.start(.compareAll)
                    } label: {
                        Label(BenchmarkPlan.compareAll.name, systemImage: "chart.bar.xaxis").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).tint(Theme.accent)
                    .disabled(!canRun)

                    HStack {
                        Picker("Variant", selection: $profileVariant) {
                            ForEach(ModelVariant.allCases) { Text($0.displayName).tag($0) }
                        }
                        .pickerStyle(.menu)
                        Button {
                            profiler.start(.profile(profileVariant))
                        } label: {
                            Label("Profile 60 s", systemImage: "stopwatch").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered).tint(Theme.accent)
                        .disabled(!canRun)
                    }
                }
                Text(statusLine).font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Compute: \(vision.computeOption.effectiveDescription) · rate request \(Int(BenchmarkPlan.compareAll.targetHz)) Hz · single in-flight · \(BenchmarkPlan.compareAll.warmupSamples) warm-up inferences excluded per model. Your Live AI settings are restored afterwards.")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var canRun: Bool { ar.supportsWorldTracking && vision.sdkAvailable }

    private var statusLine: String {
        if !ar.supportsWorldTracking { return "Needs a physical ARKit device — benchmarks run on live camera frames only." }
        if !vision.sdkAvailable { return "UltralyticsYOLO package unavailable — nothing real to measure." }
        let missing = ModelVariant.allCases.filter { vision.modelPresence[$0] != true }
        if !missing.isEmpty { return "Not bundled: " + missing.map(\.displayName).joined(separator: ", ") }
        switch profiler.phase {
        case .cancelled(let reason): return "Last run cancelled: \(reason). Partial results are labeled."
        case .failed(let reason): return reason
        case .finished: return "Run finished. Results reflect this scene, device and thermal state only."
        default: return "Point the camera at a typical scene and hold steady; results are scene-dependent."
        }
    }

    private var phaseBadge: some View {
        let (text, color): (String, Color) = {
            switch profiler.phase {
            case .idle: return ("IDLE", .gray)
            case .loading(let v): return ("LOADING \(v.displayName)", Theme.warn)
            case .warmingUp(let v): return ("WARM-UP \(v.displayName)", Theme.warn)
            case .measuring(let v): return ("MEASURING \(v.displayName)", Theme.accent)
            case .finished: return ("FINISHED", Theme.good)
            case .cancelled: return ("CANCELLED", Theme.bad)
            case .failed: return ("FAILED", Theme.bad)
            }
        }()
        return Text(text)
            .font(.system(size: 10, weight: .bold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.2), in: Capsule())
            .foregroundStyle(color)
    }

    // MARK: - Frame-time graph (bounded)

    private var graphCard: some View {
        Panel {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("FRAME TIME (end-to-end per inference, last \(BenchmarkProfiler.graphCapacity))")
                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                    Spacer()
                }
                FrameTimeGraph(points: profiler.graph.elements,
                               targetMs: 1000 / BenchmarkPlan.compareAll.targetHz)
                    .frame(height: 140)
                HStack(spacing: 10) {
                    ForEach(ModelVariant.allCases) { v in
                        HStack(spacing: 4) {
                            Circle().fill(FrameTimeGraph.color(for: v)).frame(width: 7, height: 7)
                            Text(v.displayName).font(.system(size: 9))
                        }
                    }
                    HStack(spacing: 4) {
                        Circle().fill(Color.gray).frame(width: 7, height: 7)
                        Text("warm-up").font(.system(size: 9))
                    }
                    Spacer()
                }
                .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Results

    private var resultsCard: some View {
        Panel {
            VStack(alignment: .leading, spacing: 10) {
                Text("RESULTS").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                ForEach(profiler.results) { r in resultRow(r) }
                Text("Models run sequentially on the live scene, so later models may see a warmer device — compare thermal start/end before drawing conclusions.")
                    .font(.system(size: 9)).foregroundStyle(Theme.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func resultRow(_ r: VariantBenchmarkResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(r.variant.displayName).font(.headline)
                Spacer()
                outcomeLabel(r.outcome)
            }
            HStack {
                Stat(label: "Inference p50", value: ms(r.inference?.p50), tint: Theme.accent)
                Stat(label: "p95", value: ms(r.inference?.p95))
                Stat(label: "Max", value: ms(r.inference?.max))
                Stat(label: "Mean±SD", value: r.inference.map { String(format: "%.1f±%.1f", $0.mean, $0.stdDev) } ?? "—")
            }
            HStack {
                Stat(label: "E2E p50", value: ms(r.endToEnd?.p50))
                Stat(label: "E2E p95", value: ms(r.endToEnd?.p95))
                Stat(label: "Capture→res p50", value: ms(r.captureToResult?.p50))
                Stat(label: "Rate", value: r.achievedHz.map { String(format: "%.1f Hz", $0) } ?? "—")
            }
            HStack {
                Stat(label: "Samples", value: "\(r.measuredSamples) (+\(r.warmupDiscarded) wu)")
                Stat(label: "Skipped slots", value: "\(r.skippedSlots)",
                     tint: r.skippedSlots > 0 ? Theme.warn : .white)
                Stat(label: "Missed cam frames", value: "\(r.cameraFramesMissed)/\(r.cameraFramesDelivered + r.cameraFramesMissed)",
                     tint: r.cameraFramesMissed > 0 ? Theme.warn : .white)
                Stat(label: "Longest gap", value: ms(r.longestFrameGapMs))
            }
            HStack {
                Stat(label: "Load", value: r.loadMs.map { String(format: "%.0f ms", $0) } ?? "cached/—")
                Stat(label: "Not-ready ticks", value: "\(r.notReadyTicks)")
                Stat(label: "Objects/frame", value: r.meanObjects.map { String(format: "%.1f", $0) } ?? "—")
                Stat(label: "Thermal", value: thermalText(r), tint: r.thermalWorst?.color ?? .white)
            }
            Text("\(r.computeDescription) · window \(String(format: "%.1f", r.windowSeconds)) s")
                .font(.system(size: 9)).foregroundStyle(.secondary)
            Divider().overlay(Theme.panelStroke)
        }
    }

    @ViewBuilder private func outcomeLabel(_ o: BenchmarkOutcome) -> some View {
        switch o {
        case .completed:
            Text("COMPLETE").font(.caption2.bold()).foregroundStyle(Theme.good)
        case .cancelled(let reason):
            Text("PARTIAL · \(reason)").font(.caption2.bold()).foregroundStyle(Theme.warn).lineLimit(1)
        case .failed(let reason):
            Text("FAILED · \(reason)").font(.caption2.bold()).foregroundStyle(Theme.bad).lineLimit(2)
        }
    }

    private func thermalText(_ r: VariantBenchmarkResult) -> String {
        guard let start = r.thermalStart, let end = r.thermalEnd else { return "—" }
        return start == end ? start.label : "\(start.label)→\(end.label)"
    }

    private func ms(_ v: Double?) -> String { v.map { String(format: "%.1f ms", $0) } ?? "—" }

    // MARK: - Definitions

    private var definitionsCard: some View {
        Panel {
            VStack(alignment: .leading, spacing: 4) {
                Text("HOW THESE ARE MEASURED").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                Group {
                    Text("• Inference: SDK-reported Core ML/Vision time (pre-processing is folded in on the Vision path).")
                    Text("• E2E: our wall clock from inference tick start to converted result (includes SDK annotation drawing and task hops).")
                    Text("• Capture→result: host clock at result minus ARFrame.timestamp.")
                    Text("• Skipped slots: target-rate slots with no inference start because the previous one was still running (single in-flight).")
                    Text("• Missed camera frames: inferred from ARFrame timestamp gaps > 1.5× the video format interval; ARKit does not report drops directly.")
                    Text("• Not-ready ticks: loop ticks with no inference (model loading, session not running, no frame) — never counted as latency.")
                    Text("• Thermal: ProcessInfo.thermalState sampled every 100 ms (start → end; color = worst).")
                }
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Lightweight Canvas plot of a bounded point array (no retained history).
struct FrameTimeGraph: View {
    let points: [FrameTimePoint]
    let targetMs: Double

    static func color(for v: ModelVariant) -> Color {
        switch v {
        case .nano: return Theme.good
        case .small: return Theme.accent
        case .medium: return Theme.warn
        }
    }

    var body: some View {
        Canvas { ctx, size in
            guard let first = points.first, let last = points.last else { return }
            let maxMs = max(targetMs * 1.5, points.map(\.endToEndMs).max() ?? targetMs)
            let t0 = first.t, span = max(0.001, last.t - t0)
            func pos(_ p: FrameTimePoint) -> CGPoint {
                CGPoint(x: CGFloat((p.t - t0) / span) * size.width,
                        y: size.height - CGFloat(p.endToEndMs / maxMs) * size.height)
            }
            // Target-interval reference line.
            let ty = size.height - CGFloat(targetMs / maxMs) * size.height
            var ref = Path(); ref.move(to: CGPoint(x: 0, y: ty)); ref.addLine(to: CGPoint(x: size.width, y: ty))
            ctx.stroke(ref, with: .color(.white.opacity(0.25)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            ctx.draw(Text(String(format: "%.0f ms target", targetMs)).font(.system(size: 8)).foregroundColor(.secondary),
                     at: CGPoint(x: 4, y: ty - 6), anchor: .leading)
            ctx.draw(Text(String(format: "%.0f ms", maxMs)).font(.system(size: 8)).foregroundColor(.secondary),
                     at: CGPoint(x: 4, y: 6), anchor: .leading)

            for p in points {
                let c = pos(p)
                let rect = CGRect(x: c.x - 1.5, y: c.y - 1.5, width: 3, height: 3)
                ctx.fill(Path(ellipseIn: rect), with: .color(p.isWarmup ? .gray : Self.color(for: p.variant)))
            }
        }
        .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
    }
}
