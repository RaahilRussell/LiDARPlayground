import Foundation
import Testing
@testable import test

@Suite("Persisted obstacle height")
struct ObstacleHeightTests {
    @Test func classificationRequiresFiniteOrderedFloorRelativeBounds() {
        #expect(ObstacleHeight.classify(minHeight: nil, maxHeight: 2) == .unknown)
        #expect(ObstacleHeight.classify(minHeight: 0, maxHeight: nil) == .unknown)
        #expect(ObstacleHeight.classify(minHeight: .nan, maxHeight: 2) == .unknown)
        #expect(ObstacleHeight.classify(minHeight: 0, maxHeight: .infinity) == .unknown)
        #expect(ObstacleHeight.classify(minHeight: 2, maxHeight: 1) == .unknown)
        #expect(ObstacleHeight.classify(minHeight: 0, maxHeight: 0.35) == .ground)
        #expect(ObstacleHeight.classify(minHeight: 0.1, maxHeight: 0.75) == .knee)
        #expect(ObstacleHeight.classify(minHeight: 0.1, maxHeight: 2) == .torso)
        #expect(ObstacleHeight.classify(minHeight: 1.6, maxHeight: 2) == .overhead)
    }

    @Test func oldGeometryDecodesWithoutInventingHazards() throws {
        let oldFields: [String: Any] = ["meshes": [Any](), "trail": [Any]()]
        let data = try PropertyListSerialization.data(fromPropertyList: oldFields,
            format: .binary, options: 0)
        let geometry = try PropertyListDecoder().decode(SavedMapGeometry.self, from: data)
        #expect(geometry.perceptionHazards.isEmpty)
    }

    @Test func persistedHeightRoundTripsWithWorldPosition() throws {
        let hazard = SavedPerceptionHazard(position: MapPosition(x: 1, y: 2, z: 3),
            radius: 0.4, label: "sign", confidence: 0.8,
            minHeight: 1.8, maxHeight: 2.2, height: .overhead)
        let geometry = SavedMapGeometry(meshes: [], trail: [], perceptionHazards: [hazard])
        try geometry.validate()
        let data = try PropertyListEncoder().encode(geometry)
        let restored = try PropertyListDecoder().decode(SavedMapGeometry.self, from: data)
        #expect(restored.perceptionHazards == [hazard])
    }
}
