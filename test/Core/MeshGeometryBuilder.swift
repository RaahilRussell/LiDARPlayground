//
//  MeshGeometryBuilder.swift
//  test
//
//  Feature 5 — converts an ARMeshGeometry (from scene reconstruction) into a
//  SceneKit geometry, with wireframe, solid-translucent, or classification
//  colouring. Vertices/faces are shared straight from ARKit's Metal buffers;
//  only the optional per-vertex classification colours are copied.
//

import ARKit
import SceneKit
import SwiftUI
import simd

enum MeshDisplayMode: String, CaseIterable, Identifiable {
    case wireframe = "Wireframe"
    case solid = "Solid"
    case classification = "Classified"
    var id: String { rawValue }
}

enum MeshGeometryBuilder {

    static func build(_ mesh: ARMeshGeometry, mode: MeshDisplayMode) -> SCNGeometry {
        let verts = mesh.vertices
        let faces = mesh.faces

        let vertexSource = SCNGeometrySource(
            buffer: verts.buffer,
            vertexFormat: verts.format,
            semantic: .vertex,
            vertexCount: verts.count,
            dataOffset: verts.offset,
            dataStride: verts.stride)

        let indexData = Data(bytes: faces.buffer.contents(), count: faces.buffer.length)
        let element = SCNGeometryElement(
            data: indexData,
            primitiveType: .triangles,
            primitiveCount: faces.count,
            bytesPerIndex: faces.bytesPerIndex)

        var sources = [vertexSource]
        if mode == .classification, let colors = classificationColors(mesh) {
            let colorData = colors.withUnsafeBytes { Data($0) }
            let colorSource = SCNGeometrySource(
                data: colorData, semantic: .color, vectorCount: colors.count,
                usesFloatComponents: true, componentsPerVector: 4,
                bytesPerComponent: 4, dataOffset: 0,
                dataStride: MemoryLayout<SIMD4<Float>>.stride)
            sources.append(colorSource)
        }

        let geometry = SCNGeometry(sources: sources, elements: [element])
        apply(mode: mode, to: geometry)
        return geometry
    }

    private static func apply(mode: MeshDisplayMode, to geometry: SCNGeometry) {
        let material = SCNMaterial()
        material.isDoubleSided = true
        switch mode {
        case .wireframe:
            material.fillMode = .lines
            material.diffuse.contents = UIColor(Theme.accent)
            material.lightingModel = .constant
        case .solid:
            material.fillMode = .fill
            material.diffuse.contents = UIColor(Theme.accent).withAlphaComponent(0.35)
            material.transparency = 0.55
            material.lightingModel = .blinn
        case .classification:
            material.fillMode = .fill
            material.lightingModel = .constant
        }
        geometry.firstMaterial = material
    }

    /// Builds a per-vertex colour array by assigning each triangle's vertices the
    /// colour of that triangle's classification.
    private static func classificationColors(_ mesh: ARMeshGeometry) -> [SIMD4<Float>]? {
        guard let classification = mesh.classification else { return nil }
        let faces = mesh.faces
        var colors = [SIMD4<Float>](repeating: SIMD4<Float>(0.6, 0.6, 0.6, 1),
                                    count: mesh.vertices.count)
        let classPtr = classification.buffer.contents()
        let indexPtr = faces.buffer.contents()
        let perPrimitive = faces.indexCountPerPrimitive

        for f in 0..<faces.count {
            let raw = classPtr
                .advanced(by: classification.offset + f * classification.stride)
                .assumingMemoryBound(to: UInt8.self).pointee
            let color = classificationColor(ARMeshClassification(rawValue: Int(raw)) ?? .none)
            for k in 0..<perPrimitive {
                let idx = readIndex(indexPtr, at: f * perPrimitive + k,
                                    bytesPerIndex: faces.bytesPerIndex)
                if idx < colors.count { colors[idx] = color }
            }
        }
        return colors
    }

    private static func readIndex(_ ptr: UnsafeRawPointer, at position: Int, bytesPerIndex: Int) -> Int {
        let offset = position * bytesPerIndex
        if bytesPerIndex == 2 {
            return Int(ptr.advanced(by: offset).assumingMemoryBound(to: UInt16.self).pointee)
        } else {
            return Int(ptr.advanced(by: offset).assumingMemoryBound(to: UInt32.self).pointee)
        }
    }

    static func classificationColor(_ c: ARMeshClassification) -> SIMD4<Float> {
        switch c {
        case .wall: return SIMD4<Float>(0.45, 0.55, 0.75, 1)
        case .floor: return SIMD4<Float>(0.30, 0.80, 0.45, 1)
        case .ceiling: return SIMD4<Float>(0.65, 0.45, 0.85, 1)
        case .table: return SIMD4<Float>(0.95, 0.60, 0.25, 1)
        case .seat: return SIMD4<Float>(0.95, 0.85, 0.30, 1)
        case .window: return SIMD4<Float>(0.30, 0.80, 0.90, 1)
        case .door: return SIMD4<Float>(0.90, 0.35, 0.35, 1)
        case .none: return SIMD4<Float>(0.55, 0.55, 0.60, 1)
        @unknown default: return SIMD4<Float>(0.55, 0.55, 0.60, 1)
        }
    }

    static func classificationName(_ c: ARMeshClassification) -> String {
        switch c {
        case .wall: return "Wall"
        case .floor: return "Floor"
        case .ceiling: return "Ceiling"
        case .table: return "Table"
        case .seat: return "Seat"
        case .window: return "Window"
        case .door: return "Door"
        case .none: return "None"
        @unknown default: return "Unknown"
        }
    }
}
