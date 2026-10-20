//
//  PointCloudTabView.swift
//  test
//
//  Feature 4 — live 3D point cloud viewer with density, camera/world-space
//  toggle, point count, and XYZ axes. Generation runs off the main thread and
//  is throttled to keep memory and CPU in check.
//

import ARKit
import SwiftUI

struct PointCloudTabView: View {
    @Environment(ARSessionManager.self) private var ar

    @State private var holder = PointCloudSceneHolder()
    @State private var worldSpace = false
    @State private var density: Double = 2      // stride; higher = fewer points
    @State private var pointCount = 0
    @State private var highConfidenceOnly = true

    private let maxPoints = 60_000

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            if !ar.supportsSceneDepth {
                unsupported
            } else {
                VStack(spacing: 10) {
                    PointCloudSceneView(holder: holder)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    controls
                }
                .padding(10)
            }
        }
        .task(id: "\(worldSpace)-\(density)-\(highConfidenceOnly)") { await loop() }
    }

    private var controls: some View {
        Panel {
            VStack(spacing: 10) {
                HStack {
                    Stat(label: "Points", value: "\(pointCount)", tint: Theme.accent)
                    Stat(label: "Space", value: worldSpace ? "World" : "Camera")
                    Stat(label: "Max", value: "\(maxPoints)")
                }
                Picker("Space", selection: $worldSpace) {
                    Text("Camera-space").tag(false)
                    Text("World-space").tag(true)
                }
                .pickerStyle(.segmented)
                Toggle("High-confidence points only", isOn: $highConfidenceOnly)
                    .font(.footnote)
                HStack {
                    Text("Density").font(.caption).foregroundStyle(.secondary)
                    Slider(value: $density, in: 1...8, step: 1)
                    Text(density <= 1 ? "Full" : "1/\(Int(density))²")
                        .font(Theme.mono).frame(width: 60, alignment: .trailing)
                }
                Text("Drag to orbit · two fingers to pan · pinch to zoom")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
            .tint(Theme.accent)
        }
    }

    private func loop() async {
        while !Task.isCancelled {
            if ar.runState == .running,
               let frame = ar.session.currentFrame,
               let depth = frame.smoothedSceneDepth ?? frame.sceneDepth {
                let input = PointCloudInput(
                    depth: depth.depthMap,
                    confidence: depth.confidenceMap,
                    capturedImage: frame.capturedImage,
                    intrinsics: frame.camera.intrinsics,
                    imageResolution: frame.camera.imageResolution,
                    cameraTransform: frame.camera.transform,
                    worldSpace: worldSpace,
                    stride: Int(density),
                    maxPoints: maxPoints,
                    minConfidence: highConfidenceOnly ? ARConfidenceLevel.high.rawValue : -1)

                let cloud = await Task.detached(priority: .userInitiated) {
                    PointCloudGenerator.generate(input)
                }.value

                holder.update(cloud)
                pointCount = cloud.count
            }
            try? await Task.sleep(for: .milliseconds(150))
        }
    }

    private var unsupported: some View {
        ComingSoonView(title: "Point cloud needs LiDAR",
                       milestone: "Run on your iPhone 15 Pro Max to reconstruct a live 3D point cloud from depth.",
                       systemImage: "circle.grid.3x3")
    }
}
