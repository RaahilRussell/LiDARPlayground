//
//  MeshARView.swift
//  test
//
//  Feature 5 — renders ARKit scene-reconstruction mesh anchors over the live
//  camera via ARSCNView, with world-origin axes and a tracked-camera marker.
//  Mesh nodes are managed manually (keyed by anchor id) and refreshed on the
//  main actor from the shared session, so we never fight ARSCNView for the
//  session delegate (the manager stays the sole ARSessionDelegate).
//

import ARKit
import SceneKit
import SwiftUI

@MainActor
final class MeshSceneHolder {
    let view = ARSCNView()
    private let meshRoot = SCNNode()
    private var nodes: [UUID: SCNNode] = [:]
    private let savedRoot = SCNNode()
    private var savedNodes: [UUID: SCNNode] = [:]
    private var savedVersion: Date?
    private let cameraMarker: SCNNode

    init(manager: ARSessionManager) {
        cameraMarker = Self.makeCameraMarker()

        view.session = manager.session
        view.automaticallyUpdatesLighting = true
        view.rendersContinuously = true

        let scene = SCNScene()
        scene.rootNode.addChildNode(meshRoot)
        scene.rootNode.addChildNode(savedRoot)
        scene.rootNode.addChildNode(PointCloudSceneHolder.makeAxes(length: 0.3))
        scene.rootNode.addChildNode(cameraMarker)
        view.scene = scene

        // Re-assert the manager as the one session delegate, in case assigning the
        // session to ARSCNView tried to take it over.
        manager.session.delegate = manager
    }

    /// Diffs the current mesh anchors against our nodes and rebuilds geometry.
    func refresh(anchors: [ARMeshAnchor], mode: MeshDisplayMode) {
        let ids = Set(anchors.map { $0.identifier })
        for (id, node) in nodes where !ids.contains(id) {
            node.removeFromParentNode()
            nodes.removeValue(forKey: id)
        }
        for anchor in anchors {
            let node: SCNNode
            if let existing = nodes[anchor.identifier] {
                node = existing
            } else {
                node = SCNNode()
                meshRoot.addChildNode(node)
                nodes[anchor.identifier] = node
            }
            node.simdTransform = anchor.transform
            node.geometry = MeshGeometryBuilder.build(anchor.geometry, mode: mode)
        }
    }

    func setCameraPose(_ transform: simd_float4x4) {
        cameraMarker.simdTransform = transform
    }

    /// Historical surfaces are only supplied after successful relocalization.
    /// Current ARKit anchors replace their saved counterpart by identifier.
    func showSavedGeometry(_ geometry: SavedMapGeometry?, excluding liveIDs: Set<UUID> = [],
                           version: Date? = nil) {
        guard let geometry else {
            for node in savedNodes.values { node.removeFromParentNode() }
            savedNodes.removeAll()
            savedVersion = nil
            return
        }
        if savedNodes.isEmpty || savedVersion != version {
            for node in savedNodes.values { node.removeFromParentNode() }
            savedNodes.removeAll()
            for mesh in geometry.meshes {
                let vertices = stride(from: 0, to: mesh.vertices.count, by: 3).map {
                    SCNVector3(mesh.vertices[$0], mesh.vertices[$0 + 1], mesh.vertices[$0 + 2])
                }
                let source = SCNGeometrySource(vertices: vertices)
                let indices = mesh.triangleIndices.withUnsafeBytes { Data($0) }
                let element = SCNGeometryElement(data: indices, primitiveType: .triangles,
                    primitiveCount: mesh.triangleIndices.count / 3, bytesPerIndex: MemoryLayout<UInt32>.size)
                let surface = SCNGeometry(sources: [source], elements: [element])
                let material = SCNMaterial()
                material.diffuse.contents = UIColor.systemCyan
                material.transparency = 0.25
                material.isDoubleSided = true
                material.lightingModel = .constant
                surface.firstMaterial = material
                let node = SCNNode(geometry: surface)
                savedRoot.addChildNode(node)
                savedNodes[mesh.id] = node
            }
            savedVersion = version
        }
        for (id, node) in savedNodes { node.isHidden = liveIDs.contains(id) }
    }

    private static func makeCameraMarker() -> SCNNode {
        let cone = SCNCone(topRadius: 0, bottomRadius: 0.03, height: 0.06)
        cone.firstMaterial?.diffuse.contents = UIColor.systemYellow
        cone.firstMaterial?.lightingModel = .constant
        let node = SCNNode(geometry: cone)
        // Point the cone along the camera's -Z (forward).
        node.eulerAngles = SCNVector3(-Float.pi / 2, 0, 0)
        return node
    }
}

struct MeshARView: UIViewRepresentable {
    let holder: MeshSceneHolder
    func makeUIView(context: Context) -> ARSCNView { holder.view }
    func updateUIView(_ uiView: ARSCNView, context: Context) {}
}
