//
//  FusedPerceptionView.swift
//  test
//
//  The integrated panel: CV + LiDAR fused on one live view.
//   • Camera background (shared ARSession)
//   • YOLO instance-segmentation mask overlay
//   • Per-object boxes labeled with class + confidence + the object's REAL LiDAR
//     distance, colored by proximity (green far → red near)
//   • Live center-point distance probe from the depth buffer
//   • Fused stats: inference latency, rate, object count, center distance, valid depth %
//
//  Boxes/masks and depth come from the same ARFrame, so they stay aligned.
//

import ARKit
import SwiftUI

struct FusedPerceptionView: View {
    @Environment(ARSessionManager.self) private var ar
    @Environment(PerceptionSystem.self) private var perception

    private var vision: VisionInferenceEngine { perception.vision }
    private var fusion: SpatialFusionEngine { perception.fusion }
    private var spatial: SpatialAlgorithmsEngine { perception.spatial }
    private var driver: ProximityDriver { perception.proximityDriver }
    private var proximity: ProximityEvaluator { perception.proximity }
    private var hazardMap: WorldHazardMap { perception.hazardMap }

    @State private var maskOpacity: Double = 0.45
    @State private var showMask = true
    @State private var centerMeters: Float?
    @State private var pipelineConsumer = UUID()

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            if !ar.supportsSceneDepth {
                ComingSoonView(title: "Fused view needs LiDAR",
                               milestone: "Run on your iPhone 15 Pro Max to see CV + LiDAR fused live.",
                               systemImage: "camera.metering.multispot")
            } else {
                VStack(spacing: 8) {
                    fusedCamera.frame(height: 300)
                    ScrollView {
                        VStack(spacing: 8) {
                            alertHeader
                            sidesRow
                            statsBar
                            controls
                            filters
                            alertLog
                        }
                        .padding(.bottom, 12)
                    }
                }
                .padding(10)
            }
        }
        .onAppear {
            if !driver.running { driver.source = .fusedObjects }
            driver.demoMode = false
            perception.acquire(.guidance, for: pipelineConsumer)
        }
        .onDisappear { perception.release(pipelineConsumer) }
        .task { await trackCenterDistance() }
    }

    // MARK: - Fused camera overlay

    private var fusedCamera: some View {
        GeometryReader { geo in
            ZStack {
                ARSCNCameraView(manager: ar).ignoresSafeArea()

                if showMask, let mask = vision.latestResult?.combinedMask {
                    Image(decorative: mask, scale: 1, orientation: .up)
                        .resizable().scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .opacity(maskOpacity)
                        .allowsHitTesting(false)
                        .clipped()
                }

                // Fused object boxes (CV label + LiDAR distance).
                ForEach(fusion.observations) { obs in
                    fusedBox(obs, in: geo.size)
                }

                centerProbe(in: geo.size)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func fusedBox(_ obs: ObjectObservation, in size: CGSize) -> some View {
        let rect = mapFill(obs.boxNormalized, imageAspect: 3.0 / 4.0, in: size)
        let color = distanceColor(obs.nearestMeters, uncertain: obs.uncertain)
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 5)
                .stroke(color, lineWidth: 2.5)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
            Text(fusedLabel(obs))
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(color.opacity(0.9))
                .foregroundStyle(.black)
                .fixedSize()
                .position(x: rect.minX + 52, y: max(11, rect.minY - 10))
        }
    }

    private func fusedLabel(_ obs: ObjectObservation) -> String {
        let dist = obs.nearestMeters.isFinite ? String(format: "%.1fm", obs.nearestMeters) : "—"
        return "\(obs.label) · \(dist) · \(Int(obs.confidence * 100))%"
    }

    private func centerProbe(in size: CGSize) -> some View {
        VStack(spacing: 2) {
            Image(systemName: "plus")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.white).shadow(radius: 2)
            Text(centerMeters.map { String(format: "%.2f m", $0) } ?? "—")
                .font(.system(size: 12, weight: .heavy, design: .monospaced))
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(.black.opacity(0.55), in: Capsule())
                .foregroundStyle(centerMeters.map { distanceColor($0, uncertain: false) } ?? .white)
        }
        .position(x: size.width / 2, y: size.height / 2)
        .allowsHitTesting(false)
    }

    // MARK: - Controls + stats

    private var controls: some View {
        Panel {
            VStack(spacing: 8) {
                Picker("Model", selection: Binding(
                    get: { vision.selectedVariant }, set: { vision.switchModel(to: $0) })) {
                    ForEach(ModelVariant.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                HStack {
                    Toggle("Masks", isOn: $showMask).fixedSize()
                    Slider(value: $maskOpacity, in: 0...1).disabled(!showMask)
                    Text(String(format: "%.0f%%", maskOpacity * 100)).font(Theme.mono).frame(width: 42)
                }
            }
            .tint(Theme.accent)
        }
    }

    private var statsBar: some View {
        Panel {
            HStack {
                Stat(label: "Objects", value: "\(fusion.observations.count)", tint: Theme.accent)
                Stat(label: "Center", value: centerMeters.map { String(format: "%.2f m", $0) } ?? "—")
                Stat(label: "Infer", value: String(format: "%.0f ms", vision.measuredInferenceMs))
                Stat(label: "Rate", value: String(format: "%.0f Hz", vision.measuredRateHz))
                Stat(label: "Valid", value: ar.validDepthFraction.map { String(format: "%.0f%%", $0 * 100) } ?? "—")
            }
        }
    }

    // MARK: - Alerts (driven by the fused CV+LiDAR objects)

    private var alertHeader: some View {
        Panel {
            HStack(spacing: 12) {
                Text(proximity.currentState.rawValue)
                    .font(.system(size: 20, weight: .heavy, design: .rounded))
                    .foregroundStyle(stateColor(proximity.currentState))
                    .frame(minWidth: 96)
                VStack(alignment: .leading, spacing: 2) {
                    Text(primaryText).font(.subheadline.weight(.semibold))
                    Text("Source: \(driver.source.rawValue) · haptics on state change")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
    }

    private var primaryText: String {
        guard let d = driver.primaryDistance, d.isFinite else { return "No qualifying hazard" }
        let dir = directionName(driver.primaryRegion)
        let label = driver.primaryLabel ?? "obstacle"
        var text = String(format: "%@ %@ · %.1f m", label, dir, d)
        if let ttc = driver.primaryTTC, ttc.isFinite { text += String(format: " · TTC %.1fs", ttc) }
        return text
    }

    /// Persistent left/center/right hazards from the world map (stay after leaving FOV).
    private var sidesRow: some View {
        Panel {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("SIDES (persist out of view)")
                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(hazardMap.hazards.count) tracked")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    sideCell(.left); sideCell(.center); sideCell(.right)
                }
                if let c = hazardMap.corridorNearest {
                    Text("In your path: \(c.label ?? "obstacle") · \(String(format: "%.1f m", c.distance)) ahead")
                        .font(.caption).foregroundStyle(Theme.warn)
                }
            }
        }
    }

    private func sideCell(_ region: SpatialRegion) -> some View {
        let zone = hazardMap.zones.first { $0.region == region }
        let name = region == .left ? "LEFT" : (region == .right ? "RIGHT" : "AHEAD")
        return VStack(spacing: 2) {
            Text(name).font(.system(size: 9, weight: .bold))
            Text(zone.map { String(format: "%.1f m", $0.distance) } ?? "clear")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(zone.map { distanceColor($0.distance, uncertain: false) } ?? Theme.good)
            Text(zone?.label ?? "—")
                .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background((zone.map { distanceColor($0.distance, uncertain: false) } ?? Theme.good).opacity(0.15),
                    in: RoundedRectangle(cornerRadius: 8))
    }

    private var filters: some View {
        Panel {
            VStack(spacing: 8) {
                Text("ALERT FILTERS (reduce noise)")
                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                knob("Min confidence", Binding(get: { Double(driver.minObjectConfidence) },
                                               set: { driver.minObjectConfidence = Float($0) }), 0.2...0.9,
                     String(format: "%.2f", driver.minObjectConfidence))
                knob("Min coverage", Binding(get: { Double(driver.minCoverage) },
                                             set: { driver.minCoverage = Float($0) }), 0.05...0.6,
                     String(format: "%.0f%%", driver.minCoverage * 100))
                knob("Stability frames", Binding(get: { Double(driver.minStableFrames) },
                                                 set: { driver.minStableFrames = Int($0) }), 1...8, step: 1,
                     "\(driver.minStableFrames)")
                knob("Distance smoothing", Binding(get: { Double(driver.distanceSmoothing) },
                                                   set: { driver.distanceSmoothing = Float($0) }), 0...0.9,
                     String(format: "%.2f", driver.distanceSmoothing))
            }
            .tint(Theme.accent)
        }
    }

    private var alertLog: some View {
        Panel {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("ALERTS (state changes)")
                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(driver.recentAlerts.count)").font(.caption2).foregroundStyle(.secondary)
                }
                if driver.recentAlerts.isEmpty {
                    Text("No alerts yet — point at nearby objects.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(driver.recentAlerts.prefix(8)) { event in
                        alertRow(event)
                    }
                }
            }
        }
    }

    private func alertRow(_ event: ProximityEvent) -> some View {
        HStack(spacing: 8) {
            Text(event.state.rawValue)
                .font(.system(size: 10, weight: .bold))
                .frame(width: 70, alignment: .leading)
                .foregroundStyle(stateColor(event.state))
            Text(eventSummary(event))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
            Spacer()
        }
    }

    private func eventSummary(_ event: ProximityEvent) -> String {
        let label = event.triggeringLabel ?? "obstacle"
        let dir = directionName(event.region)
        if let d = event.distanceMeters, d.isFinite {
            return String(format: "%@ %@ · %.1f m", label, dir, d)
        }
        return "\(label) \(dir)"
    }

    private func knob(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>,
                      step: Double = 0.01, _ display: String) -> some View {
        HStack {
            Text(title).font(.caption).foregroundStyle(.secondary).frame(width: 130, alignment: .leading)
            Slider(value: value, in: range, step: step)
            Text(display).font(Theme.mono).frame(width: 48, alignment: .trailing)
        }
    }

    private func directionName(_ region: SpatialRegion?) -> String {
        switch region {
        case .left: return "left"
        case .right: return "right"
        case .center, .none: return "ahead"
        }
    }

    private func stateColor(_ s: ProximityState) -> Color {
        switch s {
        case .clear: return Theme.good
        case .caution: return Theme.accent
        case .near: return Theme.warn
        case .critical: return Theme.bad
        case .uncertain: return .gray
        }
    }

    // MARK: - Helpers

    private func trackCenterDistance() async {
        while !Task.isCancelled {
            if let frame = perception.provider?.cameraSnapshot(),
               let depth = frame.smoothedDepthMap ?? frame.depthMap {
                centerMeters = DepthProcessing.sampleDistance(depth: depth,
                                                              normalizedPoint: CGPoint(x: 0.5, y: 0.5))
            } else { centerMeters = nil }
            try? await Task.sleep(for: .milliseconds(120))
        }
    }

    private func distanceColor(_ meters: Float, uncertain: Bool) -> Color {
        if uncertain || !meters.isFinite { return .gray }
        switch meters {
        case ..<0.8: return Theme.bad
        case ..<1.5: return Theme.warn
        case ..<2.5: return Color(hue: 0.13, saturation: 0.8, brightness: 0.95) // amber-yellow
        default: return Theme.good
        }
    }

    private func mapFill(_ n: CGRect, imageAspect: CGFloat, in size: CGSize) -> CGRect {
        let viewAspect = size.width / size.height
        var dispW = size.width, dispH = size.height
        if viewAspect > imageAspect { dispH = dispW / imageAspect } else { dispW = dispH * imageAspect }
        let ox = (size.width - dispW) / 2, oy = (size.height - dispH) / 2
        return CGRect(x: ox + n.minX * dispW, y: oy + n.minY * dispH,
                      width: n.width * dispW, height: n.height * dispH)
    }
}
