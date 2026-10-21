import Foundation

nonisolated enum NavigationLimits {
    static let maxNodes = 20_000
    static let maxEdges = 40_000
    static let maxLabels = 100
    static let nodeSpacing: Float = 0.3
    static let maxEdgeLength: Float = 0.9
    static let maxHeightChange: Float = 0.35
    static let maxPoseAge: TimeInterval = 0.5
    static let maxSampleGap: TimeInterval = 0.75
}

nonisolated enum NavigationError: Error, LocalizedError, Sendable {
    case invalidGraph, invalidLabel, duplicateLabel, capacity, noPose, noRoute, notOnPath
    var errorDescription: String? {
        switch self {
        case .invalidGraph: "This place has an invalid recorded path."
        case .invalidLabel: "Use a destination name between 1 and 40 characters."
        case .duplicateLabel: "This destination name is already used. Choose a different name."
        case .capacity: "This recorded path is full. Existing directions remain available. Start a new place to record more paths."
        case .noPose: "Wait for the phone to locate itself before marking or navigating."
        case .noRoute: "No continuous walked path connects this location to that destination."
        case .notOnPath: "You are not on the recorded path. Directions are paused."
        }
    }
}

nonisolated struct NavigationNode: Codable, Sendable, Equatable, Identifiable {
    var id: UUID
    var position: MapPosition
    /// A new component starts after every tracking gap, jump, or height change.
    var segmentID: UUID
}

nonisolated struct NavigationEdge: Codable, Sendable, Equatable {
    var from: UUID
    var to: UUID
}

nonisolated struct NavigationLabel: Codable, Sendable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var nodeID: UUID

    static func normalizedName(_ name: String) throws -> String {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned.count <= 40,
              !cleaned.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw NavigationError.invalidLabel
        }
        return cleaned
    }
}

nonisolated struct SavedNavigationGraph: Codable, Sendable, Equatable {
    var coordinateSpaceID: UUID = UUID()
    var nodes: [NavigationNode] = []
    var edges: [NavigationEdge] = []
    var labels: [NavigationLabel] = []
    var startNodeID: UUID?

    func validate() throws {
        guard nodes.count <= NavigationLimits.maxNodes, edges.count <= NavigationLimits.maxEdges,
              labels.count <= NavigationLimits.maxLabels else { throw NavigationError.capacity }
        var byID: [UUID: NavigationNode] = [:]
        var floorReferences: [UUID: Float] = [:]
        for node in nodes {
            guard node.position.isValid, byID.updateValue(node, forKey: node.id) == nil else {
                throw NavigationError.invalidGraph
            }
            let floor = floorReferences[node.segmentID] ?? node.position.y
            guard abs(floor - node.position.y) <= NavigationLimits.maxHeightChange else {
                throw NavigationError.invalidGraph
            }
            floorReferences[node.segmentID] = floor
        }
        guard nodes.isEmpty ? startNodeID == nil : startNodeID.map({ byID[$0] != nil }) == true else {
            throw NavigationError.invalidGraph
        }
        var pairs = Set<String>()
        for edge in edges {
            guard edge.from != edge.to, let a = byID[edge.from], let b = byID[edge.to],
                  a.segmentID == b.segmentID,
                  NavigationMath.distance(a.position, b.position) <= NavigationLimits.maxEdgeLength,
                  abs(a.position.y - b.position.y) <= NavigationLimits.maxHeightChange else {
                throw NavigationError.invalidGraph
            }
            let key = [edge.from.uuidString, edge.to.uuidString].sorted().joined(separator: ":")
            guard pairs.insert(key).inserted else { throw NavigationError.invalidGraph }
        }
        var names = Set<String>(), ids = Set<UUID>()
        for label in labels {
            let clean = try NavigationLabel.normalizedName(label.name)
            guard byID[label.nodeID] != nil, clean == label.name,
                  names.insert(clean.lowercased()).inserted, ids.insert(label.id).inserted else {
                throw NavigationError.invalidGraph
            }
        }
    }
}

nonisolated struct NavigationPose: Sendable, Equatable {
    var position: MapPosition
    /// Clockwise from world -Z, using the camera's horizontal forward vector.
    var headingRadians: Float
    var timestamp: TimeInterval
    var isTrackingNormal: Bool = true

    func isFresh(now: TimeInterval) -> Bool {
        position.isValid && headingRadians.isFinite && isTrackingNormal
            && timestamp.isFinite && now.isFinite && timestamp <= now
            && now - timestamp <= NavigationLimits.maxPoseAge
    }
}

/// No spatial nearest-neighbour merging: only consecutive, observed movement
/// adds edges. Walking beside a wall or revisiting a loop cannot create a shortcut.
nonisolated struct NavigationRecorder {
    private(set) var graph: SavedNavigationGraph
    private(set) var currentNodeID: UUID?
    private(set) var capacityReached = false
    private var lastPose: NavigationPose?
    private var segmentID: UUID?
    private var referenceHeight: Float?

    init(graph: SavedNavigationGraph = SavedNavigationGraph()) {
        self.graph = graph
        capacityReached = graph.nodes.count >= NavigationLimits.maxNodes - 2
    }

    mutating func breakContinuity() {
        lastPose = nil; currentNodeID = nil; segmentID = nil; referenceHeight = nil
    }

    @discardableResult
    mutating func record(_ pose: NavigationPose?, now: TimeInterval, forceNode: Bool = false) -> Bool {
        guard let pose, pose.isFresh(now: now), !capacityReached else { breakContinuity(); return false }
        if let previous = lastPose {
            if pose.timestamp == previous.timestamp && !forceNode { return false }
            let interval = pose.timestamp - previous.timestamp
            let moved = NavigationMath.distance(previous.position, pose.position)
            if interval < 0 || interval > NavigationLimits.maxSampleGap
                || moved > Float(max(0, interval)) * 2 + 0.1 {
                breakContinuity()
            }
        }
        if let height = referenceHeight, abs(pose.position.y - height) > NavigationLimits.maxHeightChange {
            breakContinuity()
        }
        if let current = graph.nodes.last, current.id == currentNodeID {
            let distance = NavigationMath.distance(current.position, pose.position)
            if distance > NavigationLimits.maxEdgeLength { breakContinuity() }
            else if distance < (forceNode ? 0.05 : NavigationLimits.nodeSpacing) {
                lastPose = pose
                return false
            }
        }
        guard graph.nodes.count < NavigationLimits.maxNodes,
              graph.edges.count < NavigationLimits.maxEdges else {
            capacityReached = true; breakContinuity(); return false
        }
        let component = segmentID ?? UUID()
        let node = NavigationNode(id: UUID(), position: pose.position, segmentID: component)
        if let previousID = currentNodeID { graph.edges.append(NavigationEdge(from: previousID, to: node.id)) }
        graph.nodes.append(node)
        if graph.startNodeID == nil { graph.startNodeID = node.id }
        segmentID = component; referenceHeight = referenceHeight ?? pose.position.y
        currentNodeID = node.id; lastPose = pose
        // Stop before the hard limit. Existing paths remain routable; only an
        // explicit new place resets the graph and its coordinate space.
        capacityReached = graph.nodes.count >= NavigationLimits.maxNodes - 2
        return true
    }

    mutating func addLabel(name: String, pose: NavigationPose, now: TimeInterval) throws {
        guard pose.isFresh(now: now) else { throw NavigationError.noPose }
        let cleaned = try NavigationLabel.normalizedName(name)
        guard !graph.labels.contains(where: { $0.name.caseInsensitiveCompare(cleaned) == .orderedSame }) else {
            throw NavigationError.duplicateLabel
        }
        guard graph.labels.count < NavigationLimits.maxLabels, !capacityReached else { throw NavigationError.capacity }
        record(pose, now: now, forceNode: true)
        guard let nodeID = currentNodeID else { throw NavigationError.noPose }
        graph.labels.append(NavigationLabel(id: UUID(), name: cleaned, nodeID: nodeID))
    }
}
