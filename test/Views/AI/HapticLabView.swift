//
//  HapticLabView.swift
//  test
//
//  Phase 5 — manual haptic pattern testing (no camera needed), live parameter
//  controls, a preview of the Wearer Mode vibration language, and an honest note
//  about the single haptic actuator.
//

import SwiftUI

struct HapticLabView: View {
    @Environment(PerceptionSystem.self) private var perception
    private var haptics: HapticCoordinator { perception.haptics }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                engineCard
                patternLibrary
                parameters
                wearerLanguage
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

    /// Plays exactly what Wearer Mode plays, from AlertPolicy's own cue table, so the
    /// language can be learned and judged with users before walking with it.
    private var wearerLanguage: some View {
        Panel {
            VStack(alignment: .leading, spacing: 8) {
                Text("WEARER MODE VIBRATION LANGUAGE")
                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                ForEach([ObstacleKind.ground, .overhead], id: \.self) { kind in
                    HStack {
                        Text(kind == .ground ? "Ground (tap)" : "Overhead (double tap)")
                            .font(.caption).frame(width: 130, alignment: .leading)
                        ForEach([AlertLevel.notice, .warning, .stop], id: \.self) { level in
                            Button(level.title) {
                                if let cue = HapticCue.obstacle(kind, level: level) { haptics.play(cue) }
                            }
                            .buttonStyle(.bordered).tint(Theme.accent).font(.caption2)
                        }
                    }
                }
                HStack {
                    Text("Cannot see (buzz)").font(.caption).frame(width: 130, alignment: .leading)
                    Button("Play") { haptics.play(HapticCue.sensingLost) }
                        .buttonStyle(.bordered).tint(Theme.accent).font(.caption2)
                }
                Text("While walking, pulses repeat every \(interval(.notice)) / \(interval(.warning)) / \(interval(.stop)) s. Standing still, only a rise in level pulses.")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func interval(_ level: AlertLevel) -> String {
        String(format: "%.2g", HapticCue.interval(for: level))
    }

    private var actuatorNote: some View {
        Panel {
            VStack(alignment: .leading, spacing: 4) {
                Label("One actuator", systemImage: "iphone.radiowaves.left.and.right")
                    .font(.subheadline).foregroundStyle(Theme.accent)
                Text("iPhone has a single Taptic Engine. It cannot physically output distinct left/right vibrations, so Wearer Mode speaks direction and uses vibration texture only for obstacle height. NOT validated for navigation.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
