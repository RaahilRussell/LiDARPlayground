//
//  MeshTabView.swift
//  test
//
//  Feature 5 — 3D environmental mesh: wireframe / solid / classification,
//  anchor + vertex/face statistics, and Reset Map. Walk around a room and watch
//  the reconstruction accumulate.
//

import ARKit
import SwiftUI

struct MeshTabView: View {
    @Environment(ARSessionManager.self) private var ar

    @State private var holder: MeshSceneHolder?
    @State private var mode: MeshDisplayMode = .solid

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            if !ar.supportsMesh {
                unsupported
            } else {
                content
            }
        }
    }

    private var content: some View {
        VStack(spacing: 10) {
            ZStack {
                if let holder {
                    MeshARView(holder: holder)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                } else {
                    Color.black.clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
            controls
        }
        .padding(10)
        .onAppear { if holder == nil { holder = MeshSceneHolder(manager: ar) } }
        .task(id: mode) { await refreshLoop() }
    }

    private var controls: some View {
        Panel {
            VStack(spacing: 10) {
                HStack {
                    Stat(label: "Anchors", value: "\(ar.meshAnchorCount)", tint: Theme.accent)
                    Stat(label: "Vertices", value: format(ar.meshVertexCount))
                    Stat(label: "Faces", value: format(ar.meshFaceCount))
                }
                Picker("Mode", selection: $mode) {
                    ForEach(MeshDisplayMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                if mode == .classification {
                    classificationLegend
                }
                Button(role: .destructive) {
                    ar.resetMeshMap()
                } label: {
                    Label("Reset Map", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(Theme.bad)
                Text("Walk slowly around the room — mesh builds up as new surfaces are seen.")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
            .tint(Theme.accent)
        }
    }

    private var classificationLegend: some View {
        let items: [ARMeshClassification] = [.wall, .floor, .ceiling, .table, .seat, .window, .door]
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3),
                         spacing: 4) {
            ForEach(items, id: \.rawValue) { c in
                HStack(spacing: 4) {
                    let rgb = MeshGeometryBuilder.classificationColor(c)
                    Circle()
                        .fill(Color(red: Double(rgb.x), green: Double(rgb.y), blue: Double(rgb.z)))
                        .frame(width: 8, height: 8)
                    Text(MeshGeometryBuilder.classificationName(c))
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func refreshLoop() async {
        while !Task.isCancelled {
            if ar.runState == .running, let frame = ar.session.currentFrame {
                let meshAnchors = frame.anchors.compactMap { $0 as? ARMeshAnchor }
                holder?.refresh(anchors: meshAnchors, mode: mode)
                holder?.setCameraPose(frame.camera.transform)
            }
            try? await Task.sleep(for: .milliseconds(400)) // throttle expensive rebuilds
        }
    }

    private func format(_ n: Int) -> String {
        if n >= 1000 { return String(format: "%.1fk", Double(n) / 1000) }
        return "\(n)"
    }

    private var unsupported: some View {
        ComingSoonView(title: "Mesh needs a LiDAR device",
                       milestone: "Scene reconstruction requires the LiDAR scanner. Run on your iPhone 15 Pro Max.",
                       systemImage: "cube.transparent")
    }
}
