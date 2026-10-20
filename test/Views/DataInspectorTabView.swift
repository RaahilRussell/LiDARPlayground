//
//  DataInspectorTabView.swift
//  test
//
//  Feature 6 — live camera pose & motion (with a top-down movement trail).
//  Feature 7 — raw numeric sensor data with plain-English explanations.
//  Feature 8 — record a short sample and export CSV / JSON / PLY via the share sheet.
//

import ARKit
import SwiftUI
import simd

struct DataInspectorTabView: View {
    @Environment(ARSessionManager.self) private var ar
    @State private var snapshot: SensorSnapshot?
    @State private var recorder = SensorRecorder()
    @State private var shareURLs: [URL] = []
    @State private var showShare = false

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                poseSection
                rawDataSection
                exportSection
            }
            .padding(12)
        }
        .background(Theme.background)
        .task { await snapshotLoop() }
        .sheet(isPresented: $showShare) {
            if !shareURLs.isEmpty { ShareSheet(items: shareURLs) }
        }
    }

    // MARK: - Pose & motion (Feature 6)

    private var poseSection: some View {
        Panel {
            VStack(alignment: .leading, spacing: 10) {
                sectionTitle("Position & Motion", systemImage: "location.fill")
                HStack {
                    Stat(label: "X (m)", value: fmt(ar.cameraPosition.x))
                    Stat(label: "Y (m)", value: fmt(ar.cameraPosition.y))
                    Stat(label: "Z (m)", value: fmt(ar.cameraPosition.z))
                }
                HStack {
                    Stat(label: "Pitch°", value: fmt(ar.cameraEulerDegrees.x))
                    Stat(label: "Yaw°", value: fmt(ar.cameraEulerDegrees.y))
                    Stat(label: "Roll°", value: fmt(ar.cameraEulerDegrees.z))
                }
                HStack {
                    Stat(label: "Tracking", value: ar.trackingDescription,
                         tint: ar.trackingIsNormal ? Theme.good : Theme.warn)
                    Stat(label: "Displacement", value: fmt(ar.displacementMeters) + " m",
                         tint: Theme.accent)
                }
                trailPlot
                explanation("These coordinates are LOCAL to ARKit — metres measured from wherever the session started, not GPS. X is right, Y is up, Z is toward you; forward is −Z. Restarting tracking resets the origin.")
            }
        }
    }

    private var trailPlot: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("MOVEMENT TRAIL (top-down X/Z)")
                .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            Canvas { context, size in
                let trail = ar.trail
                guard trail.count > 1 else { return }
                let xs = trail.map { $0.x }, zs = trail.map { $0.z }
                let minX = xs.min()!, maxX = xs.max()!
                let minZ = zs.min()!, maxZ = zs.max()!
                let spanX = max(0.5, maxX - minX), spanZ = max(0.5, maxZ - minZ)
                let pad: CGFloat = 8
                func pt(_ p: SIMD3<Float>) -> CGPoint {
                    let nx = CGFloat((p.x - minX) / spanX)
                    let nz = CGFloat((p.z - minZ) / spanZ)
                    return CGPoint(x: pad + nx * (size.width - 2 * pad),
                                   y: pad + nz * (size.height - 2 * pad))
                }
                var path = Path()
                path.move(to: pt(trail[0]))
                for p in trail.dropFirst() { path.addLine(to: pt(p)) }
                context.stroke(path, with: .color(Theme.accent), lineWidth: 2)
                context.fill(Path(ellipseIn: CGRect(x: pt(trail.last!).x - 3,
                                                    y: pt(trail.last!).y - 3,
                                                    width: 6, height: 6)),
                             with: .color(Theme.good))
            }
            .frame(height: 120)
            .background(Color.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: - Raw data (Feature 7)

    private var rawDataSection: some View {
        Panel {
            VStack(alignment: .leading, spacing: 10) {
                sectionTitle("Raw Sensor Data", systemImage: "tablecells")
                if let s = snapshot {
                    HStack {
                        Stat(label: "Frame time", value: String(format: "%.3f s", s.timestamp))
                        Stat(label: "Tracking", value: s.trackingQuality)
                    }
                    HStack {
                        Stat(label: "RGB image", value: "\(Int(s.imageResolution.width))×\(Int(s.imageResolution.height))")
                        Stat(label: "Depth buffer", value: "\(s.depthWidth)×\(s.depthHeight)")
                    }
                    matrixView("Camera intrinsics (pixels)", rows: Exporters.rows(s.intrinsics))
                    explanation("The intrinsics matrix holds focal lengths (fx, fy) and the optical centre (cx, cy). They convert between pixels and real-world angles — essential for turning a depth pixel into a 3D point.")
                    matrixView("Camera transform (world)", rows: Exporters.rows(s.transform))
                    explanation("The transform is the camera's position + orientation in ARKit world space. The last column is the camera's X/Y/Z location in metres.")
                    depthGridView(s.sampleDepthGrid)
                    explanation("A coarse 8×8 grid of actual depth readings (metres) sampled across the frame. Blank cells had no valid measurement — we never invent a value.")
                    samplePointsView(s.samplePoints)
                } else {
                    Text("Waiting for a frame…").foregroundStyle(.secondary).font(.footnote)
                }
            }
        }
    }

    private func matrixView(_ title: String, rows: [[Float]]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                Text(row.map { String(format: "%8.2f", $0) }.joined(separator: " "))
                    .font(.system(size: 11, design: .monospaced))
            }
        }
    }

    private func depthGridView(_ grid: [[Float]]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("EXAMPLE DEPTH VALUES (m)")
                .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            ForEach(Array(grid.enumerated()), id: \.offset) { _, row in
                Text(row.map { $0 < 0 ? "  ·  " : String(format: "%5.2f", $0) }.joined(separator: " "))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
    }

    private func samplePointsView(_ points: [SIMD3<Float>]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("EXAMPLE 3D POINTS (world x,y,z m)")
                .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            ForEach(Array(points.prefix(5).enumerated()), id: \.offset) { _, p in
                Text(String(format: "(%.3f, %.3f, %.3f)", p.x, p.y, p.z))
                    .font(.system(size: 11, design: .monospaced))
            }
        }
    }

    // MARK: - Record & export (Feature 8)

    private var exportSection: some View {
        Panel {
            VStack(alignment: .leading, spacing: 10) {
                sectionTitle("Record & Export", systemImage: "square.and.arrow.up")
                Text(recorder.statusText).font(.footnote).foregroundStyle(.secondary)
                if recorder.isRecording {
                    ProgressView(value: recorder.progress).tint(Theme.accent)
                }
                Button {
                    Task { await recorder.record(manager: ar) }
                } label: {
                    Label(recorder.isRecording ? "Recording…" : "Record 3-second sample",
                          systemImage: "record.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .disabled(recorder.isRecording || ar.runState != .running)

                if recorder.hasRecording {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                        exportButton("Depth CSV", icon: "tablecells") { recorder.exportDepthCSV() }
                        exportButton("Metadata JSON", icon: "doc.text") { recorder.exportMetadataJSON() }
                        exportButton("Poses CSV", icon: "point.topleft.down.curvedto.point.bottomright.up") { recorder.exportPoseCSV() }
                        exportButton("Point cloud PLY", icon: "circle.grid.3x3") { recorder.exportPLY() }
                    }
                    Button {
                        shareURLs = recorder.exportAll()
                        showShare = !shareURLs.isEmpty
                    } label: {
                        Label("Share all files", systemImage: "square.and.arrow.up.on.square")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                explanation("Recording only runs when you tap the button, is capped at 3 seconds and \(20_000) points, and writes plain-text files you can AirDrop or save to your Mac.")
            }
        }
    }

    private func exportButton(_ title: String, icon: String, url: @escaping () -> URL?) -> some View {
        Button {
            if let u = url() { shareURLs = [u]; showShare = true }
        } label: {
            Label(title, systemImage: icon)
                .font(.caption)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(Theme.accent)
    }

    // MARK: - Helpers

    private func snapshotLoop() async {
        while !Task.isCancelled {
            if ar.runState == .running { snapshot = ar.liveSnapshot() }
            try? await Task.sleep(for: .milliseconds(700))
        }
    }

    private func sectionTitle(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.headline).foregroundStyle(.white)
    }

    private func explanation(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func fmt(_ v: Float) -> String { String(format: "%.3f", v) }
}
