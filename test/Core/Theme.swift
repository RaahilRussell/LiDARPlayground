//
//  Theme.swift
//  test
//
//  Shared styling for the dark "developer-tool" look, plus small formatting
//  helpers used across the status strip and inspector panels.
//

import SwiftUI

enum Theme {
    static let background = Color(red: 0.06, green: 0.07, blue: 0.09)
    static let panel = Color(red: 0.11, green: 0.12, blue: 0.15)
    static let panelStroke = Color.white.opacity(0.08)
    static let accent = Color(red: 0.25, green: 0.78, blue: 0.95)
    static let good = Color(red: 0.30, green: 0.85, blue: 0.45)
    static let warn = Color(red: 0.98, green: 0.74, blue: 0.20)
    static let bad = Color(red: 0.96, green: 0.36, blue: 0.36)
    static let mono = Font.system(.footnote, design: .monospaced)
}

/// A rounded dark card used throughout the UI.
struct Panel<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(12)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Theme.panelStroke, lineWidth: 1)
            )
    }
}

extension ProcessInfo.ThermalState {
    var label: String {
        switch self {
        case .nominal: return "Nominal"
        case .fair: return "Fair"
        case .serious: return "Serious"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
        }
    }

    var color: Color {
        switch self {
        case .nominal: return Theme.good
        case .fair: return Theme.accent
        case .serious: return Theme.warn
        case .critical: return Theme.bad
        @unknown default: return .gray
        }
    }
}

/// Small labelled numeric readout used in stats panels.
struct Stat: View {
    let label: String
    let value: String
    var tint: Color = .white
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(Theme.mono)
                .foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
