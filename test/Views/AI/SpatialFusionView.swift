//
//  SpatialFusionView.swift
//  test
//
//  Phase 3 + 4 — fused 3D object observations over the live camera (distances,
//  region, coverage, uncertainty), a SceneKit 3D debug scene (points, floor,
//  clusters, tracked objects, camera pose), and an honest L/C/R occupancy summary.
//

import SwiftUI

struct SpatialFusionView: View {
    @Environment(ARSessionManager.self) private var ar
    @Environment(PerceptionSystem.self) private var perception
    private var vision: VisionInferenceEngine { perception.vision }
    private var fusion: SpatialFusionEngine { perception.fusion }
    private var spatial: SpatialAlgorithmsEngine { perception.spatial }

    enum Mode: String, CaseIterable, Identifiable { case camera = "Camera", debug3D = "3D Debug"; var id: String { rawValue } }
    @State private var mode: Mode = .camera
    @State private var debugHolder = SpatialDebugHolder()
    @State private var pipelineConsumer = UUID()

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            if !ar.supportsSceneDepth {
                ComingSoonView(title: "Fusion needs LiDAR",
                               milestone: "Run on your iPhone 15 Pro Max for RGB + LiDAR fusion.",
                               systemImage: "cube.transparent.fill")
            } else {
                VStack(spacing: 8) {
                    Picker("Mode", selection: $mode) {
                        ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented).padding(.horizontal, 10)

                    Group {
                        if mode == .camera {
                            camera.frame(maxHeight: 300)
                        } else {
                            SpatialDebugSceneView(holder: debugHolder)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .frame(maxHeight: 300)
                        }
                    }
                    occupancyBar
                    list
                }
                .padding(10)
            }
        }
        .onAppear {
            perception.acquire(.fused, for: pipelineConsumer)
        }
        .onDisappear { perception.release(pipelineConsumer) }
        .task(id: mode) { await pumpDebug() }
    }

    /// Pushes the latest spatial snapshot into the SceneKit scene while in 3D mode.
    private func pumpDebug() async {
        while !Task.isCancelled {
            if mode == .debug3D { debugHolder.update(spatial.snapshot) }
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    // MARK: - Camera overlay

    private var camera: some View {
        GeometryReader { geo in
            ZStack {
                ARSCNCameraView(manager: ar).ignoresSafeArea()
                ForEach(fusion.observations) { obs in annotation(obs, in: geo.size) }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func annotation(_ obs: ObjectObservation, in size: CGSize) -> some View {
        let n = obs.boxNormalized
        let imageAspect: CGFloat = 3.0 / 4.0
        let viewAspect = size.width / size.height
        var dispW = size.width, dispH = size.height
        if viewAspect > imageAspect { dispH = dispW / imageAspect } else { dispW = dispH * imageAspect }
        let ox = (size.width - dispW) / 2, oy = (size.height - dispH) / 2
        let rect = CGRect(x: ox + n.minX * dispW, y: oy + n.minY * dispH,
                          width: n.width * dispW, height: n.height * dispH)
        let color = obs.uncertain ? Theme.warn : Theme.good
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 4).stroke(color, lineWidth: 2)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
            Text(label(obs))
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .padding(.horizontal, 4).padding(.vertical, 2)
                .background(color.opacity(0.85)).foregroundStyle(.black)
                .position(x: rect.minX + 46, y: max(8, rect.minY - 8))
        }
    }

    private func label(_ obs: ObjectObservation) -> String {
        let d = obs.nearestMeters.isFinite ? String(format: "%.2fm", obs.nearestMeters) : "—"
        return "\(obs.label) \(d)\(obs.uncertain ? " ?" : "")"
    }

    // MARK: - Occupancy

    private var occupancyBar: some View {
        Panel {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("OCCUPANCY (camera-relative)")
                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                    Spacer()
                    if let f = spatial.floor {
                        Text("Floor: \(f.inliers) pts").font(.caption2).foregroundStyle(Theme.good)
                    } else {
                        Text("Floor: none").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 6) {
                    ForEach(spatial.occupancy) { region in
                        occupancyCell(region)
                    }
                }
                Text("Unobserved space is shown as UNKNOWN — never assumed free.")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
    }

    private func occupancyCell(_ r: RegionOccupancy) -> some View {
        VStack(spacing: 2) {
            Text(r.id.rawValue.uppercased()).font(.system(size: 9, weight: .bold))
            Text(occLabel(r.occupancy)).font(.system(size: 10, weight: .semibold))
                .foregroundStyle(occColor(r.occupancy))
            Text(r.nearestMeters.map { String(format: "%.2fm", $0) } ?? "—")
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(occColor(r.occupancy).opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
    }

    private func occLabel(_ c: OccupancyClass) -> String {
        switch c {
        case .observedFree: return "FREE"
        case .occupied: return "OCCUPIED"
        case .unknown: return "UNKNOWN"
        case .lowConfidence: return "LOW-CONF"
        }
    }
    private func occColor(_ c: OccupancyClass) -> Color {
        switch c {
        case .observedFree: return Theme.good
        case .occupied: return Theme.bad
        case .unknown: return .gray
        case .lowConfidence: return Theme.warn
        }
    }

    // MARK: - Observation list

    private var list: some View {
        ScrollView {
            VStack(spacing: 8) {
                if fusion.observations.isEmpty {
                    Text("No fused objects. Point at people/furniture with the model running.")
                        .font(.footnote).foregroundStyle(.secondary).padding()
                }
                ForEach(fusion.observations) { obs in observationCard(obs) }
            }
        }
    }

    private func observationCard(_ obs: ObjectObservation) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(obs.label).font(.headline)
                        .foregroundStyle(obs.uncertain ? Theme.warn : .white)
                    Spacer()
                    Text(obs.region.rawValue.uppercased()).font(.caption2).foregroundStyle(Theme.accent)
                    if obs.uncertain { Text("UNCERTAIN").font(.caption2).foregroundStyle(Theme.warn) }
                }
                HStack {
                    Stat(label: "Near", value: fmt(obs.nearestMeters))
                    Stat(label: "Median", value: fmt(obs.medianMeters))
                    Stat(label: "Azimuth", value: String(format: "%.0f°", obs.azimuthDegrees))
                }
                HStack {
                    Stat(label: "Coverage", value: String(format: "%.0f%%", obs.validDepthCoverage * 100),
                         tint: obs.validDepthCoverage < 0.15 ? Theme.bad : Theme.good)
                    Stat(label: "Depth conf", value: String(format: "%.0f%%", obs.depthConfidence * 100))
                    Stat(label: "Conf", value: String(format: "%.0f%%", obs.confidence * 100))
                }
            }
        }
    }

    private func fmt(_ v: Float) -> String { v.isFinite ? String(format: "%.2f m", v) : "—" }
}
