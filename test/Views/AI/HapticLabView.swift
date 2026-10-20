//
//  HapticLabView.swift
//  test
//
//  Phase 5 — manual haptic pattern testing (no camera needed), live parameter
//  controls, a simulated-distance proximity tester, and an honest note about the
//  single haptic actuator.
//

import QuartzCore
import SwiftUI

struct HapticLabView: View {
    @Environment(PerceptionSystem.self) private var perception
    private var haptics: HapticCoordinator { perception.haptics }
    private var proximity: ProximityEvaluator { perception.proximity }

    @State private var simDistance: Float = 1.5

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                engineCard
                patternLibrary
                parameters
                proximityTester
                actuatorNote
            }
            .padding(12)
        }
        .background(Theme.background)
    }

    private var engineCard: some View {
        Panel {
            HStack {
                Image(systemName: haptics.supportsHaptics ? "waveform.circle.fill" : "waveform.slash")
                    .foregroundStyle(haptics.supportsHaptics ? Theme.good : Theme.bad)
                VStack(alignment: .leading) {
                    Text("Core Haptics engine").font(.headline)
                    Text(haptics.engineState).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Restart") { haptics.restart() }.buttonStyle(.bordered).tint(Theme.accent)
            }
        }
    }

    private var patternLibrary: some View {
        Panel {
            VStack(alignment: .leading, spacing: 8) {
                Text("PATTERN LIBRARY").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(HapticPattern.allCases) { pattern in
                        Button { haptics.play(pattern, force: true) } label: {
                            Text(pattern.rawValue).font(.caption).frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered).tint(Theme.accent)
                    }
                }
                Toggle("Haptics enabled", isOn: Binding(get: { haptics.enabled },
                                                        set: { haptics.enabled = $0 }))
                    .font(.footnote).tint(Theme.accent)
            }
        }
    }

    private var parameters: some View {
        Panel {
            VStack(spacing: 8) {
                slider("Intensity", Binding(get: { Double(haptics.intensity) },
                                            set: { haptics.intensity = Float($0) }), 0...1,
                       String(format: "%.2f", haptics.intensity))
                slider("Sharpness", Binding(get: { Double(haptics.sharpness) },
                                            set: { haptics.sharpness = Float($0) }), 0...1,
                       String(format: "%.2f", haptics.sharpness))
                slider("Pulse (s)", Binding(get: { haptics.pulseDuration },
                                            set: { haptics.pulseDuration = $0 }), 0.02...0.4,
                       String(format: "%.2f", haptics.pulseDuration))
                slider("Interval (s)", Binding(get: { haptics.repetitionInterval },
                                               set: { haptics.repetitionInterval = $0 }), 0.05...0.6,
                       String(format: "%.2f", haptics.repetitionInterval))
                slider("Cooldown (s)", Binding(get: { haptics.cooldown },
                                               set: { haptics.cooldown = $0 }), 0.1...1.5,
                       String(format: "%.2f", haptics.cooldown))
            }
            .tint(Theme.accent)
        }
    }

    private var proximityTester: some View {
        Panel {
            VStack(alignment: .leading, spacing: 8) {
                Text("SIMULATED PROXIMITY (no camera)")
                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                HStack {
                    Text("Distance").font(.caption).foregroundStyle(.secondary)
                    Slider(value: $simDistance, in: 0.1...3)
                    Text(String(format: "%.2f m", simDistance)).font(Theme.mono).frame(width: 60)
                }
                HStack {
                    Button("Send simulated obstacle") {
                        proximity.evaluate(nearest: simDistance, confidence: 0.9, region: .center,
                                           label: nil, isSimulated: true,
                                           inputTimestamp: CACurrentMediaTime())
                    }
                    .buttonStyle(.borderedProminent).tint(Theme.accent)
                    Spacer()
                    stateBadge(proximity.currentState)
                }
                thresholdControls
                Text("⚠︎ Simulated input — clearly separate from real sensor data.")
                    .font(.system(size: 9)).foregroundStyle(Theme.warn)
            }
        }
    }

    private var thresholdControls: some View {
        VStack(spacing: 6) {
            slider("Caution ≤", Binding(get: { Double(proximity.cautionDistance) },
                                        set: { proximity.cautionDistance = Float($0) }), 1...4,
                   String(format: "%.1f", proximity.cautionDistance))
            slider("Near ≤", Binding(get: { Double(proximity.nearDistance) },
                                     set: { proximity.nearDistance = Float($0) }), 0.6...2.5,
                   String(format: "%.1f", proximity.nearDistance))
            slider("Critical ≤", Binding(get: { Double(proximity.criticalDistance) },
                                         set: { proximity.criticalDistance = Float($0) }), 0.2...1.5,
                   String(format: "%.1f", proximity.criticalDistance))
        }
        .tint(Theme.accent)
    }

    private var actuatorNote: some View {
        Panel {
            VStack(alignment: .leading, spacing: 4) {
                Label("One actuator", systemImage: "iphone.radiowaves.left.and.right")
                    .font(.subheadline).foregroundStyle(Theme.accent)
                Text("iPhone has a single Taptic Engine. It cannot physically output distinct left/right vibrations. Direction here is encoded only as deliberately different patterns, paired with on-screen text — this is NOT validated for navigation.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func stateBadge(_ s: ProximityState) -> some View {
        Text(s.rawValue)
            .font(.system(size: 12, weight: .bold))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(stateColor(s).opacity(0.25), in: Capsule())
            .foregroundStyle(stateColor(s))
    }

    private func stateColor(_ s: ProximityState) -> Color {
        switch s {
        case .clear: return Theme.good
        case .caution: return Theme.accent
        case .near: return Theme.warn
        case .critical: return Theme.bad
        case .uncertain: return .gray
        }
    }

    private func slider(_ label: String, _ value: Binding<Double>,
                        _ range: ClosedRange<Double>, _ display: String) -> some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
            Slider(value: value, in: range)
            Text(display).font(Theme.mono).frame(width: 52, alignment: .trailing)
        }
    }
}
