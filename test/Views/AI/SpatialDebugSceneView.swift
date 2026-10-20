//
//  SpatialDebugSceneView.swift
//  test
//
//  Phase 4 — SceneKit 3D debug view: ground (green) vs elevated (red) points,
//  the estimated floor plane, cluster bounding boxes, tracked-object markers, and
//  the camera pose. Orbit/pan/zoom via the built-in camera controls.
//

import SceneKit
import SwiftUI
import simd

@MainActor
final class SpatialDebugHolder {
    let scnView = SCNView()
    private let groundNode = SCNNode()
    private let elevatedNode = SCNNode()
    private let clusterRoot = SCNNode()
    private let trackRoot = SCNNode()
    private let floorNode = SCNNode()
    private let cameraMarker: SCNNode

    init() {
        cameraMarker = SpatialDebugHolder.coneMarker(.systemYellow)
        let scene = SCNScene()
        scene.background.contents = UIColor(Theme.background)
        scene.rootNode.addChildNode(groundNode)
        scene.rootNode.addChildNode(elevatedNode)
        scene.rootNode.addChildNode(clusterRoot)
        scene.rootNode.addChildNode(trackRoot)
        scene.rootNode.addChildNode(floorNode)
        scene.rootNode.addChildNode(cameraMarker)
        scene.rootNode.addChildNode(PointCloudSceneHolder.makeAxes(length: 0.5))

        let cam = SCNCamera(); cam.zNear = 0.01; cam.zFar = 100
        let camNode = SCNNode(); camNode.camera = cam; camNode.position = SCNVector3(0, 1, 2.5)
        scene.rootNode.addChildNode(camNode)

        scnView.scene = scene
        scnView.pointOfView = camNode
        scnView.allowsCameraControl = true
        scnView.autoenablesDefaultLighting = true
        scnView.backgroundColor = UIColor(Theme.background)
    }

    func update(_ s: SpatialSnapshot) {
        groundNode.geometry = pointGeometry(s.groundPoints, color: SIMD4<Float>(0.3, 0.85, 0.45, 1))
        elevatedNode.geometry = pointGeometry(s.elevatedPoints, color: SIMD4<Float>(0.95, 0.4, 0.4, 1))

        clusterRoot.childNodes.forEach { $0.removeFromParentNode() }
        for c in s.clusters.prefix(12) {
            let size = c.maxBound - c.minBound
            let box = SCNBox(width: CGFloat(max(0.02, size.x)), height: CGFloat(max(0.02, size.y)),
                             length: CGFloat(max(0.02, size.z)), chamferRadius: 0)
            box.firstMaterial?.fillMode = .lines
            box.firstMaterial?.diffuse.contents = UIColor.systemTeal
            box.firstMaterial?.lightingModel = .constant
            let node = SCNNode(geometry: box)
            node.simdPosition = c.centroid
            clusterRoot.addChildNode(node)
        }

        trackRoot.childNodes.forEach { $0.removeFromParentNode() }
        for t in s.tracked {
            let sphere = SCNSphere(radius: 0.05)
            sphere.firstMaterial?.diffuse.contents = t.uncertain ? UIColor.systemOrange : UIColor.systemBlue
            sphere.firstMaterial?.lightingModel = .constant
            let node = SCNNode(geometry: sphere)
            node.simdPosition = t.position
            trackRoot.addChildNode(node)
        }

        // Floor plane visualization.
        floorNode.childNodes.forEach { $0.removeFromParentNode() }
        if let floor = s.floor {
            let plane = SCNPlane(width: 4, height: 4)
            plane.firstMaterial?.diffuse.contents = UIColor.systemGreen.withAlphaComponent(0.15)
            plane.firstMaterial?.isDoubleSided = true
            plane.firstMaterial?.lightingModel = .constant
            let node = SCNNode(geometry: plane)
            // Orient the plane to the floor normal; place at a point on the plane.
            let up = SIMD3<Float>(0, 0, 1) // SCNPlane faces +Z by default
            let n = simd_normalize(floor.normal)
            node.simdOrientation = simd_quatf(from: up, to: n)
            node.simdPosition = -floor.d * n
            floorNode.addChildNode(node)
        }

        cameraMarker.simdTransform = s.cameraTransform
    }

    private func pointGeometry(_ pts: [SIMD3<Float>], color: SIMD4<Float>) -> SCNGeometry? {
        guard !pts.isEmpty else { return nil }
        let cloud = PointCloud(positions: pts, colors: [SIMD4<Float>](repeating: color, count: pts.count))
        return PointCloudSceneHolder.makeGeometry(cloud)
    }

    private static func coneMarker(_ color: UIColor) -> SCNNode {
        let cone = SCNCone(topRadius: 0, bottomRadius: 0.03, height: 0.08)
        cone.firstMaterial?.diffuse.contents = color
        cone.firstMaterial?.lightingModel = .constant
        let node = SCNNode(geometry: cone)
        node.eulerAngles = SCNVector3(-Float.pi / 2, 0, 0)
        return node
    }
}

struct SpatialDebugSceneView: UIViewRepresentable {
    let holder: SpatialDebugHolder
    func makeUIView(context: Context) -> SCNView { holder.scnView }
    func updateUIView(_ uiView: SCNView, context: Context) {}
}
