//
//  CameraTabView.swift
//  test
//
//  Feature 1 — Live camera feed with Start / Pause / Reset, live FPS, ARKit
//  tracking status, frame timestamp, and current session state.
//

import ARKit
import SwiftUI

struct CameraTabView: View {
    @Environment(ARSessionManager.self) private var ar

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            if ar.supportsWorldTracking {
                ARSCNCameraView(manager: ar)
                    .ignoresSafeArea(edges: .bottom)
            } else {
                unsupportedView
            }

            VStack {
                Spacer()
                statsPanel
                controls
            }
            .padding()
        }
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 12) {
            controlButton(title: ar.runState == .running ? "Pause" : "Start",
                          systemImage: ar.runState == .running ? "pause.fill" : "play.fill",
                          tint: ar.runState == .running ? Theme.warn : Theme.good) {
                if ar.runState == .running { ar.pause() } else { ar.start() }
            }
            controlButton(title: "Reset", systemImage: "arrow.counterclockwise",
                          tint: Theme.accent) {
                ar.reset()
            }
        }
    }

    private func controlButton(title: String, systemImage: String, tint: Color,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(tint.opacity(0.22), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(tint, lineWidth: 1))
                .foregroundStyle(tint)
        }
        .disabled(!ar.supportsWorldTracking)
    }

    // MARK: - Stats

    private var statsPanel: some View {
        Panel {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Stat(label: "Session", value: ar.runState.rawValue,
                         tint: ar.runState == .running ? Theme.good : .white)
                    Stat(label: "FPS", value: ar.fps > 0 ? String(format: "%.1f", ar.fps) : "—")
                }
                HStack {
                    Stat(label: "Tracking", value: ar.trackingDescription,
                         tint: ar.trackingIsNormal ? Theme.good : Theme.warn)
                    Stat(label: "Frame time", value: String(format: "%.3f s", ar.lastFrameTimestamp))
                }
                if let error = ar.errorMessage {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(Theme.bad)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var unsupportedView: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("ARKit world tracking isn't available here.")
                .font(.headline)
            Text("Run on a physical iPhone 15 Pro Max to see the live camera, depth, and LiDAR features.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }
}
