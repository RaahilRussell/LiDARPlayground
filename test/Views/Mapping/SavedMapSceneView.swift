import Foundation
import Observation
import SceneKit
import SwiftUI
import UIKit
import simd

/// An ordinary SceneKit view: saved places remain browsable with no camera
/// permission, no live sensing, and no ARSession allocation.
struct SavedMapSceneView: View {
    let geometry: SavedMapGeometry
    @State private var holder = SavedMapSceneHolder()
    @State private var wireframe = false

    var body: some View {
        ZStack(alignment: .bottom) {
            SavedMapSceneSurface(holder: holder)
                .accessibilityLabel("Saved three-dimensional map")
                .accessibilityHint("Drag to orbit, pinch to zoom, and drag with two fingers to pan.")
            if holder.isLoading {
                ProgressView("Preparing saved surface…")
                    .padding().background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .frame(maxHeight: .infinity)
            }
            if let error = holder.errorMessage {
                ContentUnavailableView("Unable to display map", systemImage: "cube.transparent",
                                       description: Text(error))
                    .frame(maxHeight: .infinity)
            }
            VStack(spacing: 8) {
                Text("Drag to orbit · Pinch to zoom · Two fingers to pan")
                    .font(.caption2).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                HStack {
                    Toggle("Wireframe", isOn: $wireframe)
                        .toggleStyle(.button)
                    Spacer()
                    Button { holder.fitCamera() } label: {
                        Label("Fit map", systemImage: "arrow.up.left.and.arrow.down.right")
                    }
                }
                .font(.footnote)
                Text("Yellow line: captured camera trail. Surfaces are a saved snapshot.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .padding(10)
        }
        .onAppear { holder.load(geometry) }
        .onChange(of: geometry) { _, value in holder.load(value) }
        .onChange(of: wireframe) { _, value in holder.setWireframe(value) }
        .onDisappear { holder.cancel() }
    }
}

private struct SavedMapSceneSurface: UIViewRepresentable {
    let holder: SavedMapSceneHolder
    func makeUIView(context: Context) -> SCNView { holder.view }
    func updateUIView(_ uiView: SCNView, context: Context) {}
}

@MainActor
@Observable
private final class SavedMapSceneHolder {
    let view = SCNView()
    private let meshRoot = SCNNode()
    private let trailNode = SCNNode()
    private let cameraNode = SCNNode()
    private var center = SIMD3<Float>.zero
    private var radius: Float = 2
    private var wireframe = false
    private var loadTask: Task<Void, Never>?
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    init() {
        let scene = SCNScene()
        scene.background.contents = UIColor(Theme.background)
        scene.rootNode.addChildNode(meshRoot)
        scene.rootNode.addChildNode(trailNode)
        scene.rootNode.addChildNode(PointCloudSceneHolder.makeAxes(length: 0.5))
        cameraNode.camera = SCNCamera()
        cameraNode.camera?.fieldOfView = 55
        cameraNode.camera?.zNear = 0.01
        scene.rootNode.addChildNode(cameraNode)

        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 550
        scene.rootNode.addChildNode(ambient)
        let light = SCNNode()
        light.light = SCNLight()
        light.light?.type = .directional
        light.light?.intensity = 900
        light.eulerAngles = SCNVector3(-0.7, 0.5, 0)
        scene.rootNode.addChildNode(light)

        view.scene = scene
        view.pointOfView = cameraNode
        view.allowsCameraControl = true
        view.defaultCameraController.automaticTarget = false
        view.antialiasingMode = .multisampling2X
        view.preferredFramesPerSecond = 30
        view.backgroundColor = UIColor(Theme.background)
    }

    func load(_ geometry: SavedMapGeometry) {
        cancel()
        isLoading = true
        errorMessage = nil
        let preparation = Task.detached(priority: .userInitiated) {
            try SavedMapScenePreparation.prepare(geometry)
        }
        loadTask = Task { [weak self] in
            do {
                let result = try await withTaskCancellationHandler {
                    try await preparation.value
                } onCancel: { preparation.cancel() }
                try Task.checkCancellation()
                self?.install(result)
                self?.isLoading = false
            } catch is CancellationError {
                // A newer map or a dismissed viewer owns the next UI update.
            } catch {
                guard !Task.isCancelled else { return }
                self?.errorMessage = error.localizedDescription
                self?.isLoading = false
            }
        }
    }

    func cancel() { loadTask?.cancel(); loadTask = nil }

    func setWireframe(_ enabled: Bool) {
        wireframe = enabled
        for node in meshRoot.childNodes {
            node.geometry?.firstMaterial?.fillMode = enabled ? .lines : .fill
        }
    }

    func fitCamera() {
        let target = SCNVector3(center.x, center.y, center.z)
        // Fit the bounding sphere in the narrowest dimension, including a
        // portrait iPhone viewport. Reset controller inertia before repositioning.
        view.defaultCameraController.stopInertia()
        cameraNode.camera?.fieldOfView = 55
        cameraNode.camera?.projectionDirection = .vertical
        let aspect = Float(max(view.bounds.width, 1) / max(view.bounds.height, 1))
        let verticalHalfAngle: Float = 55 * .pi / 360
        let halfAngle = atan(tan(verticalHalfAngle) * min(aspect, 1))
        let distance = max(1, radius / sin(max(halfAngle, 0.1))) * 1.15
        let direction = simd_normalize(SIMD3<Float>(0.8, 0.65, 1))
        cameraNode.simdPosition = center + direction * distance
        cameraNode.look(at: target)
        cameraNode.camera?.zFar = Double(max(100, distance + radius * 4))
        view.pointOfView = cameraNode
        view.defaultCameraController.pointOfView = cameraNode
        view.defaultCameraController.target = target
    }

    private func install(_ prepared: SavedMapScenePreparation) {
        meshRoot.childNodes.forEach { $0.removeFromParentNode() }
        for mesh in prepared.meshes {
            let vertexSource = SCNGeometrySource(data: mesh.vertices, semantic: .vertex,
                                                vectorCount: mesh.vertexCount,
                                                usesFloatComponents: true, componentsPerVector: 3,
                                                bytesPerComponent: 4, dataOffset: 0, dataStride: 12)
            let normalSource = SCNGeometrySource(data: mesh.normals, semantic: .normal,
                                                vectorCount: mesh.vertexCount,
                                                usesFloatComponents: true, componentsPerVector: 3,
                                                bytesPerComponent: 4, dataOffset: 0, dataStride: 12)
            let element = SCNGeometryElement(data: mesh.indices, primitiveType: .triangles,
                                             primitiveCount: mesh.faceCount, bytesPerIndex: 4)
            let geometry = SCNGeometry(sources: [vertexSource, normalSource], elements: [element])
            let material = SCNMaterial()
            material.diffuse.contents = UIColor(Theme.accent)
            material.isDoubleSided = true
            material.lightingModel = .lambert
            material.fillMode = wireframe ? .lines : .fill
            geometry.materials = [material]
            meshRoot.addChildNode(SCNNode(geometry: geometry))
        }
        if prepared.trailCount > 1 {
            let source = SCNGeometrySource(data: prepared.trailVertices, semantic: .vertex,
                                          vectorCount: prepared.trailCount,
                                          usesFloatComponents: true, componentsPerVector: 3,
                                          bytesPerComponent: 4, dataOffset: 0, dataStride: 12)
            let element = SCNGeometryElement(data: prepared.trailIndices, primitiveType: .line,
                                             primitiveCount: prepared.trailCount - 1, bytesPerIndex: 4)
            let trail = SCNGeometry(sources: [source], elements: [element])
            let material = SCNMaterial()
            material.diffuse.contents = UIColor.systemYellow
            material.lightingModel = .constant
            trail.materials = [material]
            trailNode.geometry = trail
        } else {
            trailNode.geometry = nil
        }
        center = prepared.center
        radius = prepared.radius
        fitCamera()
    }
}

/// Heavy normal generation and bounds work runs off the main actor. Only native
/// SceneKit objects are constructed on the UI actor.
private nonisolated struct SavedMapScenePreparation: Sendable {
    nonisolated struct Mesh: Sendable {
        var vertices: Data
        var normals: Data
        var indices: Data
        var vertexCount: Int
        var faceCount: Int
    }
    var meshes: [Mesh]
    var center: SIMD3<Float>
    var radius: Float
    var trailVertices: Data
    var trailIndices: Data
    var trailCount: Int

    static func prepare(_ geometry: SavedMapGeometry) throws -> Self {
        try geometry.validate()
        var minimum = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var maximum = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        var meshes: [Mesh] = []
        for mesh in geometry.meshes {
            try Task.checkCancellation()
            var normals = [Float](repeating: 0, count: mesh.vertices.count)
            func position(_ index: Int) -> SIMD3<Float> {
                SIMD3(mesh.vertices[index * 3], mesh.vertices[index * 3 + 1], mesh.vertices[index * 3 + 2])
            }
            for index in 0..<mesh.vertexCount {
                let p = position(index)
                minimum = simd_min(minimum, p)
                maximum = simd_max(maximum, p)
            }
            for face in 0..<mesh.faceCount {
                if face.isMultiple(of: 4_096) { try Task.checkCancellation() }
                let ia = Int(mesh.triangleIndices[face * 3])
                let ib = Int(mesh.triangleIndices[face * 3 + 1])
                let ic = Int(mesh.triangleIndices[face * 3 + 2])
                let a = position(ia), b = position(ib), c = position(ic)
                let normal = simd_cross(b - a, c - a)
                normals[ia * 3] += normal.x
                normals[ia * 3 + 1] += normal.y
                normals[ia * 3 + 2] += normal.z
                normals[ib * 3] += normal.x
                normals[ib * 3 + 1] += normal.y
                normals[ib * 3 + 2] += normal.z
                normals[ic * 3] += normal.x
                normals[ic * 3 + 1] += normal.y
                normals[ic * 3 + 2] += normal.z
            }
            for index in 0..<mesh.vertexCount {
                let normal = SIMD3(normals[index * 3], normals[index * 3 + 1], normals[index * 3 + 2])
                let length = simd_length(normal)
                let unit = length > 0.000_001 ? normal / length : SIMD3<Float>(0, 1, 0)
                normals[index * 3] = unit.x
                normals[index * 3 + 1] = unit.y
                normals[index * 3 + 2] = unit.z
            }
            meshes.append(Mesh(vertices: mesh.vertices.withUnsafeBytes { Data($0) },
                               normals: normals.withUnsafeBytes { Data($0) },
                               indices: mesh.triangleIndices.withUnsafeBytes { Data($0) },
                               vertexCount: mesh.vertexCount, faceCount: mesh.faceCount))
        }
        let center = geometry.vertexCount == 0 ? SIMD3<Float>.zero : (minimum + maximum) / 2
        let radius = geometry.vertexCount == 0 ? 2 : max(0.5, simd_distance(minimum, maximum) / 2)
        let trailVertices = geometry.trail.flatMap { [$0.x, $0.y, $0.z] }
        let trailIndices: [UInt32] = geometry.trail.count > 1
            ? (1..<geometry.trail.count).flatMap { [UInt32($0 - 1), UInt32($0)] } : []
        return Self(meshes: meshes, center: center, radius: radius,
                    trailVertices: trailVertices.withUnsafeBytes { Data($0) },
                    trailIndices: trailIndices.withUnsafeBytes { Data($0) },
                    trailCount: geometry.trail.count)
    }
}
