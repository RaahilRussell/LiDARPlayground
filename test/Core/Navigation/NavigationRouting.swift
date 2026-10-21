import Foundation

nonisolated enum NavigationMath {
    static func distance(_ a: MapPosition, _ b: MapPosition) -> Float {
        sqrt(pow(a.x - b.x, 2) + pow(a.y - b.y, 2) + pow(a.z - b.z, 2))
    }
    static func horizontalDistance(_ a: MapPosition, _ b: MapPosition) -> Float {
        hypot(a.x - b.x, a.z - b.z)
    }
    static func turnDegrees(from pose: NavigationPose, toward target: MapPosition) -> Float {
        let bearing = atan2(target.x - pose.position.x, -(target.z - pose.position.z))
        let difference = bearing - pose.headingRadians
        return atan2(sin(difference), cos(difference)) * 180 / .pi
    }
    static func edgeDistance(_ point: MapPosition, _ a: MapPosition, _ b: MapPosition) -> Float {
        let dx = b.x - a.x, dz = b.z - a.z
        let lengthSquared = dx * dx + dz * dz
        guard lengthSquared > 0 else { return distance(point, a) }
        let fraction = min(1, max(0, ((point.x - a.x) * dx + (point.z - a.z) * dz) / lengthSquared))
        return distance(point, MapPosition(x: a.x + dx * fraction,
                                          y: a.y + (b.y - a.y) * fraction, z: a.z + dz * fraction))
    }
}

nonisolated struct NavigationRoute: Sendable, Equatable {
    var nodes: [NavigationNode]
    var destinationName: String
}

nonisolated enum NavigationRouter {
    /// Dijkstra runs only over persisted walked edges. No direct destination
    /// edges, proximity loop closures, or OCR-derived connections are inserted.
    static func route(graph: SavedNavigationGraph, from start: UUID,
                      to destination: UUID, name: String) throws -> NavigationRoute {
        try graph.validate()
        let nodes = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, $0) })
        guard nodes[start] != nil, nodes[destination] != nil else { throw NavigationError.noRoute }
        var adjacent: [UUID: [(UUID, Float)]] = [:]
        for edge in graph.edges {
            guard let a = nodes[edge.from], let b = nodes[edge.to] else { throw NavigationError.invalidGraph }
            let length = NavigationMath.distance(a.position, b.position)
            adjacent[a.id, default: []].append((b.id, length))
            adjacent[b.id, default: []].append((a.id, length))
        }
        var distances: [UUID: Float] = [start: 0], previous: [UUID: UUID] = [:]
        var heap = RouteHeap()
        heap.insert((start, 0))
        while let (id, distance) = heap.pop() {
            guard distance == distances[id] else { continue }
            if id == destination { break }
            for (next, length) in adjacent[id] ?? [] {
                let candidate = distance + length
                if candidate < distances[next, default: .infinity] {
                    distances[next] = candidate; previous[next] = id
                    heap.insert((next, candidate))
                }
            }
        }
        guard distances[destination] != nil else { throw NavigationError.noRoute }
        var ids = [destination], cursor = destination
        while cursor != start {
            guard let parent = previous[cursor], ids.count <= nodes.count else { throw NavigationError.noRoute }
            ids.append(parent); cursor = parent
        }
        return NavigationRoute(nodes: ids.reversed().compactMap { nodes[$0] }, destinationName: name)
    }

    /// Initial attachment has a small tolerance and rejects ambiguous parallel
    /// components. It does not persist an edge or join disconnected paths.
    static func startingNode(graph: SavedNavigationGraph, pose: NavigationPose,
                             preferredID: UUID? = nil) throws -> UUID {
        let candidates = graph.nodes.filter {
            NavigationMath.horizontalDistance($0.position, pose.position) <= 0.3
                && abs($0.position.y - pose.position.y) <= 0.25
        }
        if let preferredID, candidates.contains(where: { $0.id == preferredID }) { return preferredID }
        guard Set(candidates.map(\.segmentID)).count == 1,
              let nearest = candidates.min(by: {
                  NavigationMath.distance($0.position, pose.position) < NavigationMath.distance($1.position, pose.position)
              }) else { throw NavigationError.notOnPath }
        return nearest.id
    }
}

private nonisolated struct RouteHeap {
    var items: [(UUID, Float)] = []
    mutating func insert(_ item: (UUID, Float)) {
        items.append(item)
        var index = items.count - 1
        while index > 0 {
            let parent = (index - 1) / 2
            guard items[index].1 < items[parent].1 else { break }
            items.swapAt(index, parent); index = parent
        }
    }
    mutating func pop() -> (UUID, Float)? {
        guard !items.isEmpty else { return nil }
        if items.count == 1 { return items.removeLast() }
        let result = items[0]
        items[0] = items.removeLast()
        var index = 0
        while true {
            let left = index * 2 + 1, right = left + 1
            guard left < items.count else { break }
            let child = right < items.count && items[right].1 < items[left].1 ? right : left
            guard items[child].1 < items[index].1 else { break }
            items.swapAt(index, child); index = child
        }
        return result
    }
}

nonisolated enum NavigationObstruction: Sendable, Equatable {
    case unknown, blocked, observedBeyondStopDistance

    /// Confidence is ARKit's 0/1/2 value. Missing/invalid confidence and holes
    /// count against coverage; one trusted near sample is enough to halt.
    static func classify(depths: [Float], confidence: [UInt8]?) -> NavigationObstruction {
        guard let confidence, depths.count == confidence.count, depths.count >= 12 else { return .unknown }
        var observed = 0
        for (depth, quality) in zip(depths, confidence) {
            guard depth.isFinite, depth > 0, quality == 1 || quality == 2 else { continue }
            if depth < 0.9 { return .blocked }
            observed += 1
        }
        return Float(observed) / Float(depths.count) >= 0.7 ? .observedBeyondStopDistance : .unknown
    }
}

nonisolated enum NavigationState: String, Sendable {
    case idle, following, turnLeft, turnRight, trackingLost, offRoute, obstacle, depthUnknown, arrived, paused
}

nonisolated struct NavigationInstruction: Sendable {
    var state: NavigationState
    var text: String
    var remainingMeters: Float
}

nonisolated struct NavigationFollower {
    let route: NavigationRoute
    private(set) var nextIndex: Int = 1
    private var previousPose: NavigationPose?

    init(route: NavigationRoute) { self.route = route }

    mutating func update(pose: NavigationPose?, now: TimeInterval,
                         obstruction: NavigationObstruction) -> NavigationInstruction {
        guard let pose, pose.isFresh(now: now) else {
            previousPose = nil
            return result(.trackingLost, "Stop. Tracking is unavailable. Wait for the phone to locate itself.")
        }
        defer { previousPose = pose }
        guard let destination = route.nodes.last else { return result(.offRoute, "Stop. No recorded route is available.") }
        if route.nodes.count == 1 || nextIndex >= route.nodes.count {
            if NavigationMath.distance(pose.position, destination.position) <= 0.3 {
                return result(.arrived, "You have reached \(route.destinationName).")
            }
            return result(.offRoute, "Stop. You have left the recorded path.")
        }
        // A normal 200ms sample can pass a waypoint. Accept a crossing only
        // when two fresh observations prove movement along collinear edges.
        // Corners and hairpins still require reaching the actual waypoint.
        while nextIndex < route.nodes.count {
            let target = route.nodes[nextIndex].position
            guard NavigationMath.distance(pose.position, target) <= 0.2
                    || crossedStraightWaypoint(pose) else { break }
            nextIndex += 1
            if nextIndex >= route.nodes.count { return result(.arrived, "You have reached \(route.destinationName).") }
        }
        let previous = route.nodes[nextIndex - 1].position
        let target = route.nodes[nextIndex].position
        guard NavigationMath.edgeDistance(pose.position, previous, target) <= 0.6 else {
            return result(.offRoute, "Stop. You have left the recorded path. Return to it before continuing.")
        }
        switch obstruction {
        case .blocked: return result(.obstacle, "Stop. An obstacle is close ahead.")
        case .unknown: return result(.depthUnknown, "Stop. The phone cannot check the space ahead. Point the camera along the path.")
        case .observedBeyondStopDistance: break
        }
        let next = route.nodes[nextIndex].position
        let degrees = NavigationMath.turnDegrees(from: pose, toward: next)
        let remaining = remainingDistance(from: pose.position)
        if degrees < -25 {
            return NavigationInstruction(state: .turnLeft,
                text: "Face left, about \(Int(abs(degrees).rounded())) degrees, to follow the recorded path.", remainingMeters: remaining)
        }
        if degrees > 25 {
            return NavigationInstruction(state: .turnRight,
                text: "Face right, about \(Int(degrees.rounded())) degrees, to follow the recorded path.", remainingMeters: remaining)
        }
        return NavigationInstruction(state: .following,
            text: "Follow the recorded path. \(Int(ceil(remaining))) metres to \(route.destinationName).", remainingMeters: remaining)
    }

    private func remainingDistance(from position: MapPosition) -> Float {
        guard nextIndex < route.nodes.count else { return 0 }
        var length = NavigationMath.distance(position, route.nodes[nextIndex].position)
        for index in (nextIndex + 1)..<route.nodes.count {
            length += NavigationMath.distance(route.nodes[index - 1].position, route.nodes[index].position)
        }
        return length
    }
    private func crossedStraightWaypoint(_ pose: NavigationPose) -> Bool {
        guard let old = previousPose, nextIndex + 1 < route.nodes.count else { return false }
        let interval = pose.timestamp - old.timestamp
        guard interval > 0, interval <= NavigationLimits.maxSampleGap,
              NavigationMath.distance(old.position, pose.position) <= Float(interval) * 2 + 0.1 else { return false }
        let a = route.nodes[nextIndex - 1].position
        let b = route.nodes[nextIndex].position
        let c = route.nodes[nextIndex + 1].position
        let ux = b.x - a.x, uz = b.z - a.z, vx = c.x - b.x, vz = c.z - b.z
        let firstLength = hypot(ux, uz), secondLength = hypot(vx, vz)
        guard firstLength > 0.01, secondLength > 0.01,
              (ux * vx + uz * vz) / (firstLength * secondLength) >= 0.985,
              abs(pose.position.y - b.y) <= 0.25, abs(old.position.y - b.y) <= 0.25 else { return false }
        func projection(_ p: MapPosition) -> Float {
            ((p.x - a.x) * ux + (p.z - a.z) * uz) / (firstLength * firstLength)
        }
        func lateral(_ p: MapPosition) -> Float {
            abs((p.x - a.x) * uz - (p.z - a.z) * ux) / firstLength
        }
        return projection(old.position) <= 1 && projection(pose.position) >= 1
            && lateral(old.position) <= 0.12 && lateral(pose.position) <= 0.12
    }
    private func result(_ state: NavigationState, _ text: String) -> NavigationInstruction {
        NavigationInstruction(state: state, text: text, remainingMeters: 0)
    }
}
