//
//  RootView.swift
//  test
//
//  Top-level UI: a persistent status strip above a five-tab developer console.
//

import SwiftUI

enum AppSection: String, CaseIterable, Identifiable {
    case sensors = "Sensors"
    case ai = "AI Perception"
    var id: String { rawValue }
}

struct RootView: View {
    @Environment(ARSessionManager.self) private var ar
    @State private var section: AppSection = .sensors

    var body: some View {
        VStack(spacing: 0) {
            StatusStripView()
            Picker("Section", selection: $section) {
                ForEach(AppSection.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Theme.panel.opacity(0.95))

            switch section {
            case .sensors: SensorsTabView()
            case .ai: AIPerceptionTabView()
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .tint(Theme.accent)
        .onAppear {
            // Auto-start once so the first screen is live; the user can pause/reset.
            if ar.runState == .idle { ar.start() }
        }
    }
}

/// The original five LiDAR sensor tabs — unchanged behavior.
struct SensorsTabView: View {
    var body: some View {
        TabView {
            CameraTabView()
                .tabItem { Label("Camera", systemImage: "camera.fill") }
            DepthTabView()
                .tabItem { Label("Depth", systemImage: "square.3.layers.3d") }
            PointCloudTabView()
                .tabItem { Label("Point Cloud", systemImage: "circle.grid.3x3.fill") }
            MeshTabView()
                .tabItem { Label("3D Mesh", systemImage: "cube.transparent") }
            DataInspectorTabView()
                .tabItem { Label("Data", systemImage: "tablecells") }
        }
        .tint(Theme.accent)
    }
}

/// The new AI Perception section (Phase 1–8).
struct AIPerceptionTabView: View {
    var body: some View {
        TabView {
            FusedPerceptionView()
                .tabItem { Label("Fused", systemImage: "camera.metering.multispot") }
            LiveAICameraView()
                .tabItem { Label("Live AI", systemImage: "camera.viewfinder") }
            DepthLabView()
                .tabItem { Label("Depth Lab", systemImage: "slider.horizontal.3") }
            SpatialFusionView()
                .tabItem { Label("Fusion", systemImage: "cube.transparent.fill") }
            HapticLabView()
                .tabItem { Label("Haptics", systemImage: "waveform") }
            BenchmarksView()
                .tabItem { Label("Bench", systemImage: "speedometer") }
            PerceptionInspectorView()
                .tabItem { Label("Inspector", systemImage: "scope") }
        }
        .tint(Theme.accent)
    }
}

/// Lightweight placeholder used by tabs still under construction.
struct ComingSoonView: View {
    let title: String
    let milestone: String
    let systemImage: String

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 40))
                    .foregroundStyle(Theme.accent)
                Text(title).font(.headline)
                Text(milestone)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding()
        }
    }
}
