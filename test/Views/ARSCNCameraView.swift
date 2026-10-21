//
//  ARSCNCameraView.swift
//  test
//
//  A thin SwiftUI wrapper around ARSCNView that displays the shared session's
//  live camera feed. It attaches to the manager's existing session — it never
//  creates or runs a session of its own.
//

import ARKit
import SceneKit
import SwiftUI

struct ARSCNCameraView: UIViewRepresentable {
    let manager: ARSessionManager

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        // Reuse the one shared session rather than the session ARSCNView makes itself.
        view.session = manager.session
        manager.session.delegate = manager
        view.automaticallyUpdatesLighting = true
        view.rendersContinuously = true
        view.backgroundColor = .black
        view.scene = SCNScene()
        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {
        // Keep the view bound to the shared session (defensive; usually a no-op).
        if uiView.session !== manager.session {
            uiView.session = manager.session
            manager.session.delegate = manager
        }
    }

    static func dismantleUIView(_ uiView: ARSCNView, coordinator: ()) {
        // Do NOT pause the shared session here — other tabs may still need it.
        // We only detach this view's reference.
    }
}
