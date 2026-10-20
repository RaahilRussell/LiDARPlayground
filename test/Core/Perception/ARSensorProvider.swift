//
//  ARSensorProvider.swift
//  test
//
//  A thin, read-only facade over the single ARSession owner (ARSessionManager).
//  It hands out an immutable SensorFrame snapshot of the latest ARFrame so the
//  perception engines never touch ARKit view code and never start a second
//  capture session. There is still exactly one ARSession in the whole app.
//

import ARKit
import simd

@MainActor
final class ARSensorProvider {
    private unowned let manager: ARSessionManager

    init(manager: ARSessionManager) {
        self.manager = manager
    }

    var isRunning: Bool { manager.runState == .running }
    var supportsSceneDepth: Bool { manager.supportsSceneDepth }

    /// Builds a snapshot of the current frame, or nil if none is available.
    /// Cheap: copies buffer references + a few scalars (no pixel work).
    func snapshot() -> SensorFrame? {
        guard let frame = manager.session.currentFrame else { return nil }
        let trackingNormal: Bool
        if case .normal = frame.camera.trackingState { trackingNormal = true } else { trackingNormal = false }
        return SensorFrame(
            capturedImage: frame.capturedImage,
            depthMap: frame.sceneDepth?.depthMap,
            confidenceMap: (frame.smoothedSceneDepth ?? frame.sceneDepth)?.confidenceMap,
            smoothedDepthMap: frame.smoothedSceneDepth?.depthMap,
            intrinsics: frame.camera.intrinsics,
            imageResolution: frame.camera.imageResolution,
            cameraTransform: frame.camera.transform,
            timestamp: frame.timestamp,
            trackingIsNormal: trackingNormal)
    }
}
