//
//  PointCloudSceneView.swift
//  test
//
//  SceneKit-backed 3D point-cloud viewer with built-in orbit/pan/zoom and a
//  metre-scaled XYZ axis gizmo. The geometry is rebuilt from a PointCloud a few
//  times per second; SceneKit renders it efficiently as GL points.
//

import SceneKit
import SwiftUI
import simd

@MainActor
final class PointCloudSceneHolder {
    let scnView = SCNView()
    private let pointNode = SCNNode()
    private(set) var count = 0

    init() {
        let scene = SCNScene()
        scene.background.contents = UIColor(Theme.background)
        scene.rootNode.addChildNode(pointNode)
        scene.rootNode.addChildNode(Self.makeAxes(length: 0.5))

        let camera = SCNCamera()
        camera.zNear = 0.01
        camera.zFar = 100
        let cameraNode = SCNNode()
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0, 0, 1.5)
        scene.rootNode.addChildNode(cameraNode)

        scnView.scene = scene
        scnView.pointOfView = cameraNode
        scnView.allowsCameraControl = true           // orbit / pan / zoom
        scnView.autoenablesDefaultLighting = true
        scnView.backgroundColor = UIColor(Theme.background)
        scnView.antialiasingMode = .multisampling2X
    }

    func update(_ cloud: PointCloud) {
        pointNode.geometry = Self.makeGeometry(cloud)
        count = cloud.count
    }

    // MARK: - Geometry

    static func makeGeometry(_ cloud: PointCloud) -> SCNGeometry? {
        guard cloud.count > 0 else { return nil }
        let positions = cloud.positions
        let colors = cloud.colors

        let vData = positions.withUnsafeBytes { Data($0) }
        let vSource = SCNGeometrySource(
            data: vData, semantic: .vertex, vectorCount: positions.count,
            usesFloatComponents: true, componentsPerVector: 3,
            bytesPerComponent: 4, dataOffset: 0,
            dataStride: MemoryLayout<SIMD3<Float>>.stride)

        let cData = colors.withUnsafeBytes { Data($0) }
        let cSource = SCNGeometrySource(
            data: cData, semantic: .color, vectorCount: colors.count,
            usesFloatComponents: true, componentsPerVector: 4,
            bytesPerComponent: 4, dataOffset: 0,
            dataStride: MemoryLayout<SIMD4<Float>>.stride)

        var indices = Array(0..<Int32(positions.count))
        let iData = Data(bytes: &indices, count: indices.count * MemoryLayout<Int32>.size)
        let element = SCNGeometryElement(
            data: iData, primitiveType: .point,
            primitiveCount: positions.count, bytesPerIndex: MemoryLayout<Int32>.size)
        element.pointSize = 6

        let geometry = SCNGeometry(sources: [vSource, cSource], elements: [element])
        geometry.firstMaterial?.lightingModel = .constant
        geometry.firstMaterial?.isDoubleSided = true
        return geometry
    }

    static func makeAxes(length: Float) -> SCNNode {
        let node = SCNNode()
        node.addChildNode(axis(length: length, color: .systemRed, axis: .x))
        node.addChildNode(axis(length: length, color: .systemGreen, axis: .y))
        node.addChildNode(axis(length: length, color: .systemBlue, axis: .z))
        return node
    }

    private enum Axis { case x, y, z }

    private static func axis(length: Float, color: UIColor, axis: Axis) -> SCNNode {
        let cylinder = SCNCylinder(radius: 0.0025, height: CGFloat(length))
        cylinder.firstMaterial?.diffuse.contents = color
        cylinder.firstMaterial?.lightingModel = .constant
        let node = SCNNode(geometry: cylinder)
        // Cylinder is along +Y by default; move so it starts at the origin.
        switch axis {
        case .y:
            node.position = SCNVector3(0, length / 2, 0)
        case .x:
            node.eulerAngles = SCNVector3(0, 0, -Float.pi / 2)
            node.position = SCNVector3(length / 2, 0, 0)
        case .z:
            node.eulerAngles = SCNVector3(Float.pi / 2, 0, 0)
            node.position = SCNVector3(0, 0, length / 2)
        }
        return node
    }
}

struct PointCloudSceneView: UIViewRepresentable {
    let holder: PointCloudSceneHolder
    func makeUIView(context: Context) -> SCNView { holder.scnView }
    func updateUIView(_ uiView: SCNView, context: Context) {}
}
