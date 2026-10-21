import Foundation
import Testing
@testable import test

@Suite("Walked-path navigation")
struct NavigationTests {
    private func pose(_ x: Float = 0, _ z: Float = 0, y: Float = 1.5,
                      time: Double = 10, heading: Float = 0) -> NavigationPose {
        NavigationPose(position: MapPosition(x: x, y: y, z: z), headingRadians: heading, timestamp: time)
    }

    private func line() -> SavedNavigationGraph {
        let segment = UUID()
        let nodes = (0..<5).map { index in
            NavigationNode(id: UUID(), position: MapPosition(x: 0, y: 1.5, z: -Float(index) * 0.4), segmentID: segment)
        }
        return SavedNavigationGraph(nodes: nodes,
            edges: (1..<nodes.count).map { NavigationEdge(from: nodes[$0 - 1].id, to: nodes[$0].id) },
            labels: [NavigationLabel(id: UUID(), name: "Bathroom", nodeID: nodes.last!.id)], startNodeID: nodes[0].id)
    }

    @Test func recordsOnlyContinuousMovement() throws {
        var recorder = NavigationRecorder()
        recorder.record(pose(), now: 10)
        recorder.record(pose(0, -0.4, time: 10.3), now: 10.3)
        #expect(recorder.graph.nodes.count == 2)
        #expect(recorder.graph.edges.count == 1)
        try recorder.graph.validate()
    }

    @Test func trackingGapDisconnectsEvenNearbyPositions() throws {
        var recorder = NavigationRecorder()
        recorder.record(pose(), now: 10)
        recorder.record(nil, now: 10.1)
        recorder.record(pose(0, -0.1, time: 10.2), now: 10.2)
        #expect(recorder.graph.nodes.count == 2)
        #expect(recorder.graph.edges.isEmpty)
        #expect(throws: NavigationError.self) {
            try NavigationRouter.route(graph: recorder.graph, from: recorder.graph.nodes[0].id,
                to: recorder.graph.nodes[1].id, name: "Elsewhere")
        }
    }

    @Test func timestampGapAndJumpCannotFormAnEdge() {
        var recorder = NavigationRecorder()
        recorder.record(pose(), now: 10)
        recorder.record(pose(0, -0.2, time: 12), now: 12)
        recorder.record(pose(0, -2, time: 12.1), now: 12.1)
        #expect(recorder.graph.edges.isEmpty)
        #expect(recorder.graph.nodes.count == 3)
    }

    @Test func rejectsStaleFutureInvalidAndLimitedPoses() {
        var stale = pose()
        #expect(!stale.isFresh(now: 11))
        #expect(!stale.isFresh(now: 9))
        stale.isTrackingNormal = false
        #expect(!stale.isFresh(now: 10))
        stale = pose(); stale.headingRadians = .nan
        #expect(!stale.isFresh(now: 10))
        stale = pose(); stale.position.x = .infinity
        #expect(!stale.isFresh(now: 10))
    }

    @Test func gradualHeightChangeStartsDisconnectedComponent() throws {
        var recorder = NavigationRecorder()
        recorder.record(pose(), now: 10)
        recorder.record(pose(0, -0.3, y: 1.7, time: 10.3), now: 10.3)
        recorder.record(pose(0, -0.6, y: 1.9, time: 10.6), now: 10.6)
        #expect(recorder.graph.edges.count == 1)
        #expect(recorder.graph.nodes[0].segmentID != recorder.graph.nodes[2].segmentID)
        try recorder.graph.validate()
    }

    @Test func revisitingPositionDoesNotJoinLoop() {
        var recorder = NavigationRecorder()
        recorder.record(pose(), now: 10)
        recorder.record(pose(0, -0.4, time: 10.3), now: 10.3)
        recorder.record(pose(0, 0, time: 10.6), now: 10.6)
        #expect(recorder.graph.nodes.count == 3)
        #expect(recorder.graph.edges.count == 2)
        #expect(recorder.graph.nodes.first?.id != recorder.graph.nodes.last?.id)
    }

    @Test func labelsUseFreshActualLocationAndUniqueNames() throws {
        var recorder = NavigationRecorder()
        try recorder.addLabel(name: " Bathroom ", pose: pose(), now: 10)
        #expect(recorder.graph.labels.first?.name == "Bathroom")
        #expect(recorder.graph.labels.first?.nodeID == recorder.graph.nodes.first?.id)
        #expect(throws: NavigationError.self) { try recorder.addLabel(name: "bathroom", pose: pose(), now: 10) }
        #expect(throws: NavigationError.self) { try recorder.addLabel(name: "Kitchen", pose: pose(), now: 11) }
        #expect(throws: NavigationError.self) { try NavigationLabel.normalizedName("  ") }
        #expect(throws: NavigationError.self) { try NavigationLabel.normalizedName("Bad\nName") }
        #expect(throws: NavigationError.self) { try NavigationLabel.normalizedName(String(repeating: "a", count: 41)) }
    }

    @Test func reverseRouteUsesEveryRecordedEdge() throws {
        let graph = line()
        let route = try NavigationRouter.route(graph: graph, from: graph.nodes.last!.id,
                                               to: graph.nodes[0].id, name: "Start")
        #expect(route.nodes.map(\.id) == graph.nodes.reversed().map(\.id))
    }

    @Test func disconnectedParallelPathDoesNotShortcut() {
        var graph = line()
        let other = NavigationNode(id: UUID(), position: MapPosition(x: 0.1, y: 1.5, z: 0), segmentID: UUID())
        graph.nodes.append(other)
        #expect(throws: NavigationError.self) {
            try NavigationRouter.route(graph: graph, from: other.id, to: graph.nodes[4].id, name: "Bathroom")
        }
        #expect(throws: NavigationError.self) { try NavigationRouter.startingNode(graph: graph, pose: pose(0.05)) }
    }

    @Test func routeRejectsCrossFloorEdgesAndDuplicateIDs() {
        var graph = line()
        graph.nodes[1].position.y = 4.5
        #expect(throws: NavigationError.self) { try graph.validate() }
        graph = line(); graph.nodes.append(graph.nodes[0])
        #expect(throws: NavigationError.self) { try graph.validate() }
        graph = line(); graph.edges.append(graph.edges[0])
        #expect(throws: NavigationError.self) { try graph.validate() }
    }

    @Test func graphRoundTripsWithIndependentCoordinateIdentity() throws {
        let graph = line()
        let decoded = try JSONDecoder().decode(SavedNavigationGraph.self, from: JSONEncoder().encode(graph))
        #expect(decoded == graph)
        try decoded.validate()
    }

    @Test func phoneHeadingDeterminesLeftAndRight() {
        let origin = pose()
        #expect(abs(NavigationMath.turnDegrees(from: origin, toward: MapPosition(x: 1, y: 1.5, z: 0)) - 90) < 0.01)
        #expect(abs(NavigationMath.turnDegrees(from: origin, toward: MapPosition(x: -1, y: 1.5, z: 0)) + 90) < 0.01)
        #expect(abs(NavigationMath.turnDegrees(from: pose(heading: .pi / 2),
            toward: MapPosition(x: 1, y: 1.5, z: 0))) < 0.01)
    }

    @Test func unknownConfidenceAndDepthHolesHalt() {
        let observed = [Float](repeating: 2, count: 20)
        #expect(NavigationObstruction.classify(depths: observed, confidence: nil) == .unknown)
        #expect(NavigationObstruction.classify(depths: observed, confidence: [UInt8](repeating: 0, count: 20)) == .unknown)
        #expect(NavigationObstruction.classify(depths: [.nan, 0, -.infinity], confidence: [2, 2, 2]) == .unknown)
        #expect(NavigationObstruction.classify(depths: observed, confidence: [UInt8](repeating: 2, count: 20)) == .observedBeyondStopDistance)
    }

    @Test func singleNearTrustedSampleHaltsEvenWithPoorCoverage() {
        var depths = [Float](repeating: .nan, count: 20)
        depths[0] = 0.8
        #expect(NavigationObstruction.classify(depths: depths, confidence: [UInt8](repeating: 2, count: 20)) == .blocked)
    }

    @Test func followerStopsForTrackingObstaclesUnknownAndOffRoute() throws {
        let graph = line()
        let route = try NavigationRouter.route(graph: graph, from: graph.nodes[0].id,
                                               to: graph.nodes.last!.id, name: "Bathroom")
        var follower = NavigationFollower(route: route)
        #expect(follower.update(pose: nil, now: 10, obstruction: .observedBeyondStopDistance).state == .trackingLost)
        #expect(follower.update(pose: pose(), now: 10, obstruction: .blocked).state == .obstacle)
        #expect(follower.update(pose: pose(), now: 10, obstruction: .unknown).state == .depthUnknown)
        #expect(follower.update(pose: pose(2), now: 10, obstruction: .observedBeyondStopDistance).state == .offRoute)
        #expect(follower.update(pose: pose(), now: 10, obstruction: .observedBeyondStopDistance).state == .following)
    }

    @Test func followerRequiresOrderedPathBeforeArrival() throws {
        let graph = line()
        let route = try NavigationRouter.route(graph: graph, from: graph.nodes[0].id,
                                               to: graph.nodes.last!.id, name: "Bathroom")
        var follower = NavigationFollower(route: route)
        #expect(follower.update(pose: pose(0, -1.6), now: 10, obstruction: .observedBeyondStopDistance).state == .offRoute)
        for index in 1..<graph.nodes.count {
            let update = follower.update(pose: pose(0, -Float(index) * 0.4), now: 10,
                                         obstruction: .observedBeyondStopDistance)
            #expect(update.state == (index == graph.nodes.count - 1 ? .arrived : .following))
        }
    }

    @Test func normalSampleCanPassACollinearWaypoint() throws {
        let graph = line()
        let route = try NavigationRouter.route(graph: graph, from: graph.nodes[0].id,
                                               to: graph.nodes.last!.id, name: "Bathroom")
        var follower = NavigationFollower(route: route)
        _ = follower.update(pose: pose(), now: 10, obstruction: .observedBeyondStopDistance)
        let update = follower.update(pose: pose(0, -0.65, time: 10.4), now: 10.4,
                                     obstruction: .observedBeyondStopDistance)
        #expect(update.state == .following)
        #expect(follower.nextIndex >= 2)
    }

    @Test func sampleCannotSkipHairpinWaypoints() {
        let segment = UUID()
        let nodes = [(Float(0), Float(0)), (0, -0.6), (0.2, -0.6), (0.2, 0)].map {
            NavigationNode(id: UUID(), position: MapPosition(x: $0.0, y: 1.5, z: $0.1), segmentID: segment)
        }
        var follower = NavigationFollower(route: NavigationRoute(nodes: nodes, destinationName: "Other side"))
        _ = follower.update(pose: pose(), now: 10, obstruction: .observedBeyondStopDistance)
        let update = follower.update(pose: pose(0.2, 0, time: 10.3), now: 10.3,
                                     obstruction: .observedBeyondStopDistance)
        #expect(follower.nextIndex == 1)
        #expect(update.state != .arrived)
    }

    @Test func trackingGapCannotSupplyWaypointCrossingEvidence() throws {
        let graph = line()
        let route = try NavigationRouter.route(graph: graph, from: graph.nodes[0].id,
                                               to: graph.nodes.last!.id, name: "Bathroom")
        var follower = NavigationFollower(route: route)
        _ = follower.update(pose: pose(), now: 10, obstruction: .observedBeyondStopDistance)
        _ = follower.update(pose: nil, now: 10.1, obstruction: .unknown)
        _ = follower.update(pose: pose(0, -0.65, time: 10.4), now: 10.4,
                            obstruction: .observedBeyondStopDistance)
        #expect(follower.nextIndex == 1)
    }

    @Test func fullRestoredGraphStopsRecordingWithoutLosingRoutes() throws {
        let segment = UUID()
        let nodes = (0..<(NavigationLimits.maxNodes - 2)).map { _ in
            NavigationNode(id: UUID(), position: MapPosition(x: 0, y: 1.5, z: 0), segmentID: segment)
        }
        let graph = SavedNavigationGraph(nodes: nodes,
            edges: [NavigationEdge(from: nodes[0].id, to: nodes[1].id)], startNodeID: nodes[0].id)
        var recorder = NavigationRecorder(graph: graph)
        #expect(recorder.capacityReached)
        let recorded = recorder.record(pose(), now: 10)
        #expect(!recorded)
        #expect(recorder.graph == graph)
        let route = try NavigationRouter.route(graph: recorder.graph, from: nodes[0].id,
                                               to: nodes[1].id, name: "Existing destination")
        #expect(route.nodes.count == 2)
    }
}
