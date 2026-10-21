//
//  testApp.swift
//  test
//
//  Created by Raahil  on 10/19/26.
//
//  LiDARPlayground — an educational sensor laboratory for exploring the
//  iPhone's LiDAR scanner, camera, and ARKit tracking output.
//

import SwiftUI

@main
struct testApp: App {
    /// The single, app-wide owner of the one and only `ARSession`.
    /// Every tab reads from this shared instance — we never create a second session.
    @State private var ar: ARSessionManager
    @State private var mapping: MappingCoordinator

    /// AI Perception layer (CV, depth refinement, fusion, haptics, diagnostics).
    /// Shares the one ARSession via ARSensorProvider — no second capture session.
    @State private var perception = PerceptionSystem()

    @Environment(\.scenePhase) private var scenePhase

    init() {
        let manager = ARSessionManager()
        _ar = State(initialValue: manager)
        _mapping = State(initialValue: MappingCoordinator(manager: manager))
    }

    var body: some Scene {
        WindowGroup {
            AppRootView()
                .environment(ar)
                .environment(mapping)
                .environment(perception)
                .preferredColorScheme(.dark)
                .onAppear {
                    perception.configure(with: ar)
                    mapping.navigation.configureSpeech(perception.speech)
                    mapping.navigation.onRouteWillStart = { perception.beginNavigationSpeech() }
                    perception.guidance.onWillStart = {
                        mapping.navigation.cancelNavigation()
                        perception.endNavigationSpeech()
                    }
                    if scenePhase == .active { perception.handleEnteredForeground() }
                    else { perception.handleLeftForeground() }
                    Task {
                        await mapping.setForegroundActive(scenePhase == .active)
                    }
                }
                .onChange(of: mapping.navigation.routeActive) { _, active in
                    if !active { perception.endNavigationSpeech() }
                }
        }
        .onChange(of: scenePhase) { _, phase in
            // Cleanly handle backgrounding: ARKit interrupts the session when we
            // leave the foreground, so we mirror that and resume on return.
            switch phase {
            case .active:
                perception.handleEnteredForeground()
                Task { await mapping.setForegroundActive(true) }
            case .background, .inactive:
                perception.handleLeftForeground()
                Task { await mapping.setForegroundActive(false) }
            @unknown default:
                break
            }
        }
    }
}
