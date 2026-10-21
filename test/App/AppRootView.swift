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
    @State private var mode: AppMode = .mapping

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
            if newMode == .mapping && !mapping.navigation.routeActive {
                perception.pauseForMapping()
            } else if newMode != .wearer {
                perception.guidance.stop()
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
