//
//  WearerModeView.swift
//  test
//
//  Wearer Mode — the accessibility-first interface. Large, high-contrast,
//  VoiceOver-friendly controls that work without visual attention. Spoken +
//  haptic proximity guidance come from the shared perception pipeline.
//
//  Experimental supplementary aid — NOT a validated mobility device.
//

import SwiftUI

struct WearerModeView: View {
    @Environment(ARSessionManager.self) private var ar
    @Environment(PerceptionSystem.self) private var perception

    var onSwitchMode: () -> Void

    private var guidance: GuidanceEngine { perception.guidance }
    private var speech: SpeechCoordinator { perception.speech }
    private var haptics: HapticCoordinator { perception.haptics }
    private var proximity: ProximityEvaluator { perception.proximity }

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
                Label("AI Vision", systemImage: "camera.viewfinder")
                    .font(.footnote)
            }
            .accessibilityLabel("Show AI Vision tools")
            .accessibilityIdentifier("assist.showVision")
        }
    }

    // MARK: - Status

    private var statusCard: some View {
        VStack(spacing: 6) {
            Text(guidance.running ? proximity.currentState.rawValue : "READY")
                .font(.system(size: 40, weight: .heavy, design: .rounded))
                .foregroundStyle(stateColor)
            Text(guidance.statusText)
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 18))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Status: \(guidance.running ? proximity.currentState.rawValue : "Ready"). \(guidance.statusText)")
    }

    // MARK: - Primary controls

    private var startStopButton: some View {
        Button {
            guidance.toggle()
        } label: {
            Label(guidance.running ? "Stop Guidance" : "Start Guidance",
                  systemImage: guidance.running ? "stop.fill" : "play.fill")
                .font(.title.bold())
                .frame(maxWidth: .infinity, minHeight: 90)
        }
        .buttonStyle(.borderedProminent)
        .tint(guidance.running ? Theme.bad : Theme.good)
        .accessibilityHint(guidance.running
            ? "Stops guidance warnings. The camera remains available for mapping."
            : "Starts camera sensing, spoken and haptic proximity warnings.")
    }

    private var describeButton: some View {
        Button {
            guidance.describeSurroundings()
        } label: {
            Label("Describe Surroundings", systemImage: "speaker.wave.2.fill")
                .font(.title3.bold())
                .frame(maxWidth: .infinity, minHeight: 64)
        }
        .buttonStyle(.bordered)
        .tint(Theme.accent)
        .disabled(!guidance.running)
        .accessibilityHint("Speaks the nearest obstacles and open directions around you.")
    }

    // MARK: - Settings

    private var settings: some View {
        VStack(spacing: 10) {
            Picker("Verbosity", selection: Binding(
                get: { guidance.verbosity }, set: { guidance.verbosity = $0 })) {
                ForEach(GuidanceEngine.Verbosity.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Speech verbosity")

            Toggle("Spoken warnings", isOn: Binding(
                get: { speech.enabled }, set: { speech.enabled = $0 }))
            Toggle("Haptic warnings", isOn: Binding(
                get: { haptics.enabled }, set: { haptics.enabled = $0 }))
            Toggle("Directional audio (use earbuds)", isOn: Binding(
                get: { guidance.spatialCue.enabled }, set: { guidance.spatialCue.enabled = $0 }))
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
        Text("Experimental aid. Does not replace a cane, guide dog, or your own judgment.")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var stateColor: Color {
        guard guidance.running else { return Theme.accent }
        switch proximity.currentState {
        case .clear: return Theme.good
        case .caution: return Theme.accent
        case .near: return Theme.warn
        case .critical: return Theme.bad
        case .uncertain: return .gray
        }
    }
}
