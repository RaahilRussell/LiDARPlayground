//
//  StatusStripView.swift
//  test
//
//  Persistent status strip shown above every tab: AR tracking, FPS, depth
//  availability, valid-depth %, and device thermal state.
//

import SwiftUI

struct StatusStripView: View {
    @Environment(ARSessionManager.self) private var ar

    var body: some View {
        HStack(spacing: 0) {
            item("TRACK", ar.trackingShort, ar.trackingIsNormal ? Theme.good : Theme.warn)
            divider
            item("FPS", ar.fps > 0 ? String(format: "%.0f", ar.fps) : "—", fpsColor)
            divider
            item("DEPTH", ar.isDepthAvailable ? "On" : "Off",
                 ar.isDepthAvailable ? Theme.good : Theme.bad)
            divider
            item("VALID", validText, validColor)
            divider
            item("THERM", ar.thermalState.label, ar.thermalState.color)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Theme.panel.opacity(0.95))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.panelStroke).frame(height: 1)
        }
    }

    private var divider: some View {
        Rectangle().fill(Theme.panelStroke).frame(width: 1, height: 22)
    }

    private func item(_ label: String, _ value: String, _ tint: Color) -> some View {
        VStack(spacing: 1) {
            Text(label)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
    }

    private var fpsColor: Color {
        switch ar.fps {
        case 50...: return Theme.good
        case 25..<50: return Theme.warn
        case 0.1..<25: return Theme.bad
        default: return .secondary
        }
    }

    private var validText: String {
        guard let f = ar.validDepthFraction else { return "—" }
        return String(format: "%.0f%%", f * 100)
    }

    private var validColor: Color {
        guard let f = ar.validDepthFraction else { return .secondary }
        switch f {
        case 0.75...: return Theme.good
        case 0.4..<0.75: return Theme.warn
        default: return Theme.bad
        }
    }
}

extension ARSessionManager {
    /// Compact tracking label for the tight status strip.
    var trackingShort: String {
        switch runState {
        case .idle: return "Idle"
        case .paused: return "Paused"
        case .interrupted: return "Intrpt"
        case .unsupported: return "N/A"
        case .running: return trackingIsNormal ? "Normal" : trackingDescription
        }
    }
}
