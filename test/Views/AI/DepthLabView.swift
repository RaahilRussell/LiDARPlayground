//
//  DepthLabView.swift
//  test
//
//  Phase 2 — four-up comparison (RGB · raw depth · refined depth · edges) with a
//  live filter picker and adjustable parameters, plus valid-pixel statistics.
//

import SwiftUI

struct DepthLabView: View {
    @Environment(ARSessionManager.self) private var ar
    @Environment(PerceptionSystem.self) private var perception
    private var engine: DepthRefinementEngine { perception.depth }
    @State private var pipelineConsumer = UUID()

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            if !ar.supportsSceneDepth {
                ComingSoonView(title: "Depth Lab needs LiDAR",
                               milestone: "Run on your iPhone 15 Pro Max to refine real depth.",
                               systemImage: "slider.horizontal.3")
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        grid
                        controls
                        stats
                    }
                    .padding(10)
                }
            }
        }
        .onAppear { perception.acquire(.depth, for: pipelineConsumer) }
        .onDisappear { perception.release(pipelineConsumer) }
    }

    private var grid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            pane("RGB", engine.rgbImage)
            pane("Raw depth", engine.rawImage)
            pane("Refined", engine.refinedImage)
            pane("Edges", engine.edgeImage)
        }
    }

    private func pane(_ title: String, _ image: CGImage?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            ZStack {
                Color.black
                if let image {
                    // Depth buffer is landscape; .right orients it upright for portrait.
                    Image(decorative: image, scale: 1, orientation: .right)
                        .resizable().scaledToFit()
                } else {
                    ProgressView()
                }
            }
            .aspectRatio(3.0 / 4.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private var controls: some View {
        Panel {
            VStack(spacing: 10) {
                Picker("Mode", selection: Binding(get: { engine.mode }, set: { engine.mode = $0 })) {
                    ForEach(DepthFilterMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .font(.caption)

                paramSlider("Kernel radius", value: Binding(
                    get: { Double(engine.params.kernelRadius) },
                    set: { engine.params.kernelRadius = Int($0) }), range: 1...4, step: 1,
                    display: "\(engine.params.kernelRadius)")
                paramSlider("Spatial σ", value: Binding(
                    get: { Double(engine.params.spatialSigma) },
                    set: { engine.params.spatialSigma = Float($0) }), range: 0.5...6,
                    display: String(format: "%.1f", engine.params.spatialSigma))
                paramSlider("Color σ", value: Binding(
                    get: { Double(engine.params.colorSigma) },
                    set: { engine.params.colorSigma = Float($0) }), range: 0.02...0.5,
                    display: String(format: "%.2f", engine.params.colorSigma))
                paramSlider("Discontinuity (m)", value: Binding(
                    get: { Double(engine.params.discontinuityThreshold) },
                    set: { engine.params.discontinuityThreshold = Float($0) }), range: 0.02...0.6,
                    display: String(format: "%.2f", engine.params.discontinuityThreshold))
                paramSlider("Temporal", value: Binding(
                    get: { Double(engine.params.temporalStrength) },
                    set: { engine.params.temporalStrength = Float($0) }), range: 0...1,
                    display: String(format: "%.2f", engine.params.temporalStrength))
                paramSlider("Min confidence", value: Binding(
                    get: { Double(engine.params.minConfidence) },
                    set: { engine.params.minConfidence = Int($0) }), range: 0...2, step: 1,
                    display: confLabel(engine.params.minConfidence))
                paramSlider("Range max (m)", value: Binding(
                    get: { Double(engine.rangeMax) },
                    set: { engine.rangeMax = Float($0) }), range: 1...10, step: 0.5,
                    display: String(format: "%.1f", engine.rangeMax))
            }
            .tint(Theme.accent)
        }
    }

    private func paramSlider(_ label: String, value: Binding<Double>,
                             range: ClosedRange<Double>, step: Double = 0.01,
                             display: String) -> some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 120, alignment: .leading)
            Slider(value: value, in: range, step: step)
            Text(display).font(Theme.mono).frame(width: 46, alignment: .trailing)
        }
    }

    private func confLabel(_ v: Int) -> String {
        switch v { case 0: return "Low"; case 1: return "Med"; default: return "High" }
    }

    private var stats: some View {
        Panel {
            HStack {
                Stat(label: "Valid before", value: String(format: "%.0f%%", engine.validBefore * 100))
                Stat(label: "Valid after", value: String(format: "%.0f%%", engine.validAfter * 100),
                     tint: Theme.accent)
                Stat(label: "Filter time", value: String(format: "%.1f ms", engine.lastProcessMs))
            }
        }
    }
}
