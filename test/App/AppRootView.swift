//
//  AppRootView.swift
//  test
//
//  Top-level switch between the two interfaces, both driven by the SAME shared
//  perception system / single ARSession:
//   • Wearer Mode — accessibility-first guidance (default).
//   • Developer Mode — the full perception inspector (existing tabs).
//

import SwiftUI

enum AppMode: String, CaseIterable, Identifiable {
    case mapping = "Maps"
    case wearer = "Assist"
    case developer = "Developer"
    var id: String { rawValue }
}

struct AppRootView: View {
    @Environment(PerceptionSystem.self) private var perception
    @Environment(MappingCoordinator.self) private var mapping
    // Start on the live perception console so the shared ARSession, LiDAR,
    // fusion, and model pipeline are actually visible on first launch.
    @State private var mode: AppMode = .developer

    var body: some View {
        VStack(spacing: 0) {
            Picker("App mode", selection: $mode) {
                ForEach(AppMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Theme.panel)

            if mapping.navigation.routeActive && mode != .mapping {
                HStack {
                    Text(mapping.navigation.instruction).font(.callout.bold())
                    Spacer()
                    Button("Show route") { mode = .mapping }
                    Button("Stop") { mapping.navigation.cancelNavigation() }
                }
                .padding(10).background(Theme.panel)
            }

            switch mode {
            case .mapping:
                MappingHomeView()
            case .wearer:
                WearerModeView(onSwitchMode: { mode = .developer })
            case .developer:
                DeveloperModeContainer(onSwitchMode: { mode = .wearer })
            }
        }
        .tint(Theme.accent)
        .onChange(of: mode) { _, newMode in
            if newMode != .wearer {
                // Stop audible/haptic feedback for the console/map UI, but do
                // not stop the shared AI pipelines that mapping is consuming.
                perception.feedback.stop()
            }
        }
    }
}

/// Wraps the existing developer UI with a quick return to Wearer Mode.
struct DeveloperModeContainer: View {
    var onSwitchMode: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: onSwitchMode) {
                    Label("Wearer Mode", systemImage: "figure.walk")
                        .font(.footnote.bold())
                }
                Spacer()
                Text("Developer").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Theme.panel)
            RootView()
        }
        .background(Theme.background.ignoresSafeArea())
    }
}
