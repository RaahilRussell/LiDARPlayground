// All tools share the app-owned ARSession and perception system.
import SwiftUI

enum AppMode: String, CaseIterable, Identifiable {
    case camera = "Camera"
    case lidar = "LiDAR"
    case vision = "AI Vision"
    case mapping = "Maps"
    case wearer = "Assist"

    var id: String {
        switch self {
        case .camera: "camera"
        case .lidar: "lidar"
        case .vision: "vision"
        case .mapping: "maps"
        case .wearer: "assist"
        }
    }

    var symbol: String {
        switch self {
        case .camera: "camera.fill"
        case .lidar: "square.3.layers.3d"
        case .vision: "camera.viewfinder"
        case .mapping: "map.fill"
        case .wearer: "figure.walk"
        }
    }
}

struct AppRootView: View {
    @Environment(ARSessionManager.self) private var ar
    @Environment(MappingCoordinator.self) private var mapping
    @State private var mode: AppMode = .camera
    @State private var lidarTool: LiDARTool = .depth
    @State private var visionTool: VisionTool = .live

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(AppMode.allCases) { destination in
                    Button {
                        mode = destination
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: destination.symbol).font(.body)
                            Text(destination.rawValue).font(.caption.weight(.semibold))
                                .lineLimit(1).minimumScaleFactor(0.75)
                        }
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .foregroundStyle(mode == destination ? Theme.accent : .secondary)
                        .background(mode == destination ? Theme.accent.opacity(0.12) : .clear,
                                    in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(destination.rawValue)
                    .accessibilityAddTraits(mode == destination ? .isSelected : [])
                    .accessibilityIdentifier("destination.\(destination.id)")
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(Theme.panel)

            if let status = ar.sensorStatusMessage {
                HStack(alignment: .top, spacing: 10) {
                    Label(status, systemImage: ar.isRecoveringSensors ? "arrow.clockwise" : "info.circle")
                        .font(.footnote)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("sensors.status")
                    if ar.canRetrySensorRecovery {
                        Button("Retry Sensing") { ar.retrySensorRecovery() }
                            .font(.footnote.bold())
                            .fixedSize()
                            .accessibilityIdentifier("sensors.retry")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10).background(Theme.panel)
            }

            if mapping.automaticSaveNeedsAttention && mode != .mapping {
                HStack {
                    Label("Map saving needs attention", systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                    Spacer()
                    Button("Open Maps") { mode = .mapping }
                        .accessibilityIdentifier("mapping.showSaveError")
                }
                .padding(10).background(Theme.panel)
            }

            if mapping.navigation.routeActive && mode != .mapping {
                HStack {
                    Text(mapping.navigation.instruction).font(.callout.bold())
                    Spacer()
                    Button("Show route") { mode = .mapping }
                        .accessibilityIdentifier("navigation.showRoute")
                    Button("Stop") { mapping.navigation.cancelNavigation() }
                }
                .padding(10).background(Theme.panel)
            }

            switch mode {
            case .camera, .lidar, .vision:
                RootView(mode: mode, lidarTool: $lidarTool, visionTool: $visionTool)
            case .mapping:
                MappingHomeView()
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("screen.maps")
            case .wearer:
                WearerModeView(onSwitchMode: { mode = .vision })
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("screen.assist")
            }
        }
        .tint(Theme.accent)
        // Changing screens never stops the shared camera, perception, or route.
        // Each explicit Start/Stop control owns its corresponding operation.
    }
}
