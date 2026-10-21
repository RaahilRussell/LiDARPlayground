//
//  SensorRecorder.swift
//  test
//
//  Feature 8 — records a short, bounded sensor sample (a few seconds of camera
//  poses plus one captured depth frame and a sampled point cloud) and exports it.
//  Recording only ever happens on an explicit user action and is capped in both
//  duration and point count to keep memory use small.
//

import ARKit
import Observation
import QuartzCore
import UIKit
import simd

@MainActor
@Observable
final class SensorRecorder {
    var isRecording = false
    var hasRecording = false
    var progress: Double = 0
    var statusText = "No recording yet"

    private let duration: TimeInterval = 3.0
    private let maxExportPoints = 20_000

    private(set) var poseSamples: [(t: TimeInterval, transform: simd_float4x4)] = []
    private(set) var depthMatrix: [[Float]] = []
    private(set) var pointCloud = PointCloud()
    private(set) var metadata: RecordingMetadata?

    /// Records for a fixed short window, then captures a final frame. Bounded.
    func record(manager: ARSessionManager) async {
        guard !isRecording else { return }
        guard manager.runState == .running, manager.trackingIsNormal, !manager.isRelocalizing else {
            statusText = "Wait for normal tracking before recording."
            return
        }
        isRecording = true
        defer { isRecording = false }
        clearCapture()
        statusText = "Recording…"

        let generation = manager.sessionGeneration
        let start = CACurrentMediaTime()
        var lastSampleTimestamp: TimeInterval = -.infinity
        while CACurrentMediaTime() - start < duration {
            guard !Task.isCancelled else {
                abortRecording("Recording cancelled.")
                return
            }
            guard recordingSessionIsValid(manager: manager, generation: generation) else {
                abortRecording("Recording stopped because tracking or the map changed. Try again.")
                return
            }
            // Polling can see the same frame twice. Each exported sample must
            // correspond to a new capture, rather than repeating a paused pose.
            if let frame = currentRecordingFrame(manager: manager, generation: generation),
               frame.timestamp > lastSampleTimestamp {
                poseSamples.append((frame.timestamp, frame.camera.transform))
                lastSampleTimestamp = frame.timestamp
            }
            progress = min(1, (CACurrentMediaTime() - start) / duration)
            do {
                try await Task.sleep(for: .milliseconds(33))
            } catch {
                abortRecording("Recording cancelled.")
                return
            }
        }

        // currentFrame can advance just before its main-queue delegate callback.
        // Briefly wait for an accepted frame instead of capturing that transient
        // unaccepted frame or treating it as a session failure.
        for attempt in 0..<6 {
            guard !Task.isCancelled else {
                abortRecording("Recording cancelled.")
                return
            }
            guard recordingSessionIsValid(manager: manager, generation: generation) else {
                abortRecording("Recording stopped because tracking or the map changed. Try again.")
                return
            }
            if let frame = currentRecordingFrame(manager: manager, generation: generation) {
                capture(frame: frame)
                hasRecording = !poseSamples.isEmpty && metadata != nil
                progress = hasRecording ? 1 : 0
                statusText = hasRecording
                    ? "Captured \(poseSamples.count) poses · \(pointCloud.count) points"
                    : "Recording failed"
                return
            }
            if attempt < 5 {
                do { try await Task.sleep(for: .milliseconds(16)) }
                catch { abortRecording("Recording cancelled."); return }
            }
        }
        abortRecording("No fresh frame was available to finish the recording. Try again.")
    }

    private func recordingSessionIsValid(manager: ARSessionManager, generation: Int) -> Bool {
        guard manager.sessionGeneration == generation, manager.runState == .running,
              manager.trackingIsNormal, !manager.isRelocalizing else { return false }
        let age = CACurrentMediaTime() - manager.lastFrameTimestamp
        return age.isFinite && age >= 0 && age < 0.5
    }

    private func currentRecordingFrame(manager: ARSessionManager, generation: Int) -> ARFrame? {
        guard recordingSessionIsValid(manager: manager, generation: generation),
              let frame = manager.session.currentFrame,
              frame.timestamp == manager.lastFrameTimestamp,
              case .normal = frame.camera.trackingState else { return nil }
        let age = CACurrentMediaTime() - frame.timestamp
        guard age.isFinite, age >= 0, age < 0.5 else { return nil }
        return frame
    }

    private func clearCapture() {
        hasRecording = false
        progress = 0
        poseSamples.removeAll()
        depthMatrix.removeAll()
        pointCloud = PointCloud()
        metadata = nil
    }

    private func abortRecording(_ message: String) {
        clearCapture()
        statusText = message
    }

    private func capture(frame: ARFrame) {
        let depthData = frame.smoothedSceneDepth ?? frame.sceneDepth
        if let depthMap = depthData?.depthMap {
            depthMatrix = DepthProcessing.matrix(from: depthMap)
            let input = PointCloudInput(
                depth: depthMap,
                confidence: depthData?.confidenceMap,
                capturedImage: frame.capturedImage,
                intrinsics: frame.camera.intrinsics,
                imageResolution: frame.camera.imageResolution,
                cameraTransform: frame.camera.transform,
                worldSpace: true,
                stride: 4,
                maxPoints: maxExportPoints,
                minConfidence: ARConfidenceLevel.medium.rawValue)
            pointCloud = PointCloudGenerator.generate(input)
        }

        let dw = depthData.map { CVPixelBufferGetWidth($0.depthMap) } ?? 0
        let dh = depthData.map { CVPixelBufferGetHeight($0.depthMap) } ?? 0
        let formatter = ISO8601DateFormatter()
        metadata = RecordingMetadata(
            capturedAt: formatter.string(from: Date()),
            deviceModel: UIDevice.current.model,
            frameTimestamp: frame.timestamp,
            trackingQuality: ARSessionManager.describe(frame.camera.trackingState),
            imageWidth: Int(frame.camera.imageResolution.width),
            imageHeight: Int(frame.camera.imageResolution.height),
            depthWidth: dw, depthHeight: dh,
            depthSource: frame.smoothedSceneDepth != nil ? "smoothedSceneDepth"
                : (frame.sceneDepth != nil ? "sceneDepth" : "Unavailable"),
            intrinsics: Exporters.rows(frame.camera.intrinsics),
            cameraTransform: Exporters.rows(frame.camera.transform),
            poseSampleCount: poseSamples.count,
            pointCount: pointCloud.count,
            note: "ARKit LOCAL coordinates (metres). Origin = session start, not GPS.")
    }

    // MARK: - Exports (return temp file URLs for the share sheet)

    func exportDepthCSV() -> URL? {
        guard !depthMatrix.isEmpty else { return nil }
        return Exporters.writeTemp("depth_matrix.csv", contents: Exporters.depthCSV(matrix: depthMatrix))
    }

    func exportPoseCSV() -> URL? {
        guard !poseSamples.isEmpty else { return nil }
        return Exporters.writeTemp("camera_poses.csv", contents: Exporters.poseCSV(samples: poseSamples))
    }

    func exportMetadataJSON() -> URL? {
        guard let metadata else { return nil }
        return Exporters.writeTemp("metadata.json", data: Exporters.metadataJSON(metadata))
    }

    func exportPLY() -> URL? {
        guard pointCloud.count > 0 else { return nil }
        return Exporters.writeTemp("point_cloud.ply", contents: Exporters.plyData(cloud: pointCloud))
    }

    func exportAll() -> [URL] {
        [exportDepthCSV(), exportPoseCSV(), exportMetadataJSON(), exportPLY()].compactMap { $0 }
    }
}
