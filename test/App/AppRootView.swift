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

enum AppMode { case wearer, developer }

struct AppRootView: View {
    @State private var mode: AppMode = .wearer

    var body: some View {
        switch mode {
        case .wearer:
            WearerModeView(onSwitchMode: { mode = .developer })
        case .developer:
            DeveloperModeContainer(onSwitchMode: { mode = .wearer })
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
