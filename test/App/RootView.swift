import SwiftUI

enum LiDARTool: String, CaseIterable, Identifiable {
    case depth = "Depth"
    case pointCloud = "Point Cloud"
    case mesh = "3D Mesh"
    case data = "Data"
    var id: String {
        switch self {
        case .depth: "depth"
        case .pointCloud: "pointCloud"
        case .mesh: "mesh"
        case .data: "data"
        }
    }
}

enum VisionTool: String, CaseIterable, Identifiable {
    case live = "Live AI"
    case fused = "Fused"
    case depthLab = "Depth Lab"
    case fusion = "Fusion"
    case haptics = "Haptics"
    case benchmarks = "Benchmarks"
    case inspector = "Inspector"
    var id: String {
        switch self {
        case .live: "live"
        case .fused: "fused"
        case .depthLab: "depthLab"
        case .fusion: "fusion"
        case .haptics: "haptics"
        case .benchmarks: "benchmarks"
        case .inspector: "inspector"
        }
    }
}

/// Selection lives in AppRootView so Maps and Assist do not reset the current tool.
struct RootView: View {
    let mode: AppMode
    @Binding var lidarTool: LiDARTool
    @Binding var visionTool: VisionTool

    var body: some View {
        VStack(spacing: 0) {
            StatusStripView()
            switch mode {
            case .camera:
                CameraTabView()
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("screen.camera")
            case .lidar:
                ToolSelector(items: LiDARTool.allCases, selection: $lidarTool,
                             prefix: "lidar", title: { $0.rawValue })
                lidarContent
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("screen.lidar.\(lidarTool.id)")
            case .vision:
                ToolSelector(items: VisionTool.allCases, selection: $visionTool,
                             prefix: "vision", title: { $0.rawValue })
                visionContent
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("screen.vision.\(visionTool.id)")
            case .mapping, .wearer:
                EmptyView()
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .tint(Theme.accent)
    }

    @ViewBuilder private var lidarContent: some View {
        switch lidarTool {
        case .depth: DepthTabView()
        case .pointCloud: PointCloudTabView()
        case .mesh: MeshTabView()
        case .data: DataInspectorTabView()
        }
    }

    @ViewBuilder private var visionContent: some View {
        switch visionTool {
        case .live: LiveAICameraView()
        case .fused: FusedPerceptionView()
        case .depthLab: DepthLabView()
        case .fusion: SpatialFusionView()
        case .haptics: HapticLabView()
        case .benchmarks: BenchmarksView()
        case .inspector: PerceptionInspectorView()
        }
    }
}

/// Every tool has a named button, including those previously hidden under More.
private struct ToolSelector<Item: Identifiable & Hashable>: View where Item.ID == String {
    @ScaledMetric(relativeTo: .subheadline) private var rowHeight: CGFloat = 52
    let items: [Item]
    @Binding var selection: Item
    let prefix: String
    let title: (Item) -> String

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(items) { item in
                    Button { selection = item } label: {
                        Text(title(item)).font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 13).frame(minHeight: 44)
                            .foregroundStyle(selection == item ? Theme.accent : .primary)
                            .background(selection == item ? Theme.accent.opacity(0.15) : .clear,
                                        in: RoundedRectangle(cornerRadius: 9))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selection == item ? .isSelected : [])
                    .accessibilityIdentifier("\(prefix).tool.\(item.id)")
                }
            }
            .padding(.horizontal, 10)
        }
        .scrollIndicators(.visible)
        .frame(height: rowHeight)
        .accessibilityIdentifier("\(prefix).tools")
        .background(Theme.panel.opacity(0.95))
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
