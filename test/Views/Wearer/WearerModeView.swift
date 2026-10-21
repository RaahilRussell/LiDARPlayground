//
//  WearerModeView.swift
//  test
//
//  Wearer Mode — the accessibility-first interface. Large, high-contrast,
//  VoiceOver-friendly controls that work without visual attention. Haptic and
//  spoken guidance come from NavigationEngine.
//
//  Experimental supplementary aid — NOT a validated mobility device.
//

import SwiftUI

struct WearerModeView: View {
    @Environment(ARSessionManager.self) private var ar
    @Environment(PerceptionSystem.self) private var perception

    var onSwitchMode: () -> Void

    private var navigation: NavigationEngine { perception.navigation }
    private var haptics: HapticCoordinator { perception.haptics }

    var body: some View {
        ZStack {
            stateColor.opacity(0.18).ignoresSafeArea()
            ScrollView {
                VStack(spacing: 16) {
                    header
                    statusCard
                    startStopButton
                    describeButton
                    settings
                    readiness
                    disclaimer
                }
                .padding(18)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Navigation Assist")
                .font(.title2.bold())
            Spacer()
            Button(action: onSwitchMode) {
                Label("Developer", systemImage: "wrench.and.screwdriver")
                    .font(.footnote)
            }
            .accessibilityLabel("Switch to Developer Mode")
        }
    }

    // MARK: - Status

    private var statusTitle: String {
        guard navigation.running else { return "READY" }
        return navigation.sensing == .ok ? navigation.decision.level.title : "NOT SENSING"
    }

    private var statusDetail: String {
        guard navigation.running else { return "Stopped" }
        guard navigation.sensing == .ok else { return navigation.sensing.rawValue }
        guard let obstacle = navigation.decision.obstacle else { return "Path ahead clear" }
        let name = AlertPolicy.name(of: obstacle, label: navigation.aheadLabel)
        return "\(name), \(AlertPolicy.distancePhrase(obstacle.distance))"
    }

    private var statusCard: some View {
        VStack(spacing: 6) {
            Text(statusTitle)
                .font(.system(size: 40, weight: .heavy, design: .rounded))
                .foregroundStyle(stateColor)
            Text(statusDetail)
                .font(.headline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 18))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Status: \(statusTitle). \(statusDetail)")
    }

    // MARK: - Primary controls

    private var startStopButton: some View {
        Button {
            navigation.toggle()
        } label: {
            Label(navigation.running ? "Stop Guidance" : "Start Guidance",
                  systemImage: navigation.running ? "stop.fill" : "play.fill")
                .font(.title.bold())
                .frame(maxWidth: .infinity, minHeight: 90)
        }
        .buttonStyle(.borderedProminent)
        .tint(navigation.running ? Theme.bad : Theme.good)
        .accessibilityHint(navigation.running
            ? "Stops sensing and warnings."
            : "Starts sensing. Warnings come as vibration, and speech for obstacles your cane can miss.")
    }

    private var describeButton: some View {
        Button {
            navigation.describeSurroundings()
        } label: {
            Label("Describe Surroundings", systemImage: "speaker.wave.2.fill")
                .font(.title3.bold())
                .frame(maxWidth: .infinity, minHeight: 64)
        }
        .buttonStyle(.bordered)
        .tint(Theme.accent)
        .disabled(!navigation.running)
        .accessibilityHint("Speaks what is ahead and how far it is open to the left and right.")
    }

    // MARK: - Settings

    private var settings: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("I use a long cane", isOn: Binding(
                get: { navigation.profile.caneUser }, set: { navigation.profile.caneUser = $0 }))
            Text(navigation.profile.caneUser
                 ? "Ground-level obstacles get only a light tap, since your cane finds them. Waist-, chest- and head-height obstacles get full warnings."
                 : "All obstacles in your path get full warnings.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Spoken warnings", isOn: Binding(
                get: { navigation.profile.speech }, set: { navigation.profile.speech = $0 }))
            Toggle("Vibration warnings", isOn: Binding(
                get: { navigation.profile.haptics }, set: { navigation.profile.haptics = $0 }))
            Toggle("Name objects (uses more battery)", isOn: Binding(
                get: { navigation.identifyObjects }, set: { navigation.identifyObjects = $0 }))
                .disabled(navigation.running)
        }
        .padding(14)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14))
        .tint(Theme.accent)
    }

    // MARK: - Readiness + disclaimer

    private var readiness: some View {
        HStack(spacing: 14) {
            readinessItem("Tracking", ok: ar.trackingIsNormal, detail: ar.trackingShort)
            readinessItem("Depth", ok: ar.isDepthAvailable, detail: ar.isDepthAvailable ? "On" : "Off")
            readinessItem("Haptics", ok: haptics.supportsHaptics, detail: haptics.supportsHaptics ? "Yes" : "No")
        }
        .font(.footnote)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Sensors. Tracking \(ar.trackingShort). Depth \(ar.isDepthAvailable ? "on" : "off"). Haptics \(haptics.supportsHaptics ? "available" : "unavailable").")
    }

    private func readinessItem(_ title: String, ok: Bool, detail: String) -> some View {
        VStack(spacing: 2) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? Theme.good : Theme.warn)
            Text(title).foregroundStyle(.secondary)
            Text(detail).font(.caption2)
        }
        .frame(maxWidth: .infinity)
    }

    private var disclaimer: some View {
        Text("Experimental aid. Does not replace a cane, guide dog, or your own judgment. Does not detect steps, curbs or drop-offs.")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var stateColor: Color {
        guard navigation.running else { return Theme.accent }
        guard navigation.sensing == .ok else { return .gray }
        switch navigation.decision.level {
        case .clear: return Theme.good
        case .notice: return Theme.accent
        case .warning: return Theme.warn
        case .stop: return Theme.bad
        }
    }
}
