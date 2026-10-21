//
//  ObstacleMap.swift
//  test
//
//  The navigation map: a world-anchored 2D grid on the floor plane. Each cell
//  remembers what LiDAR last saw in that 10 cm square: floor only (observed free)
//  or an obstacle with its bottom and top height above the floor.
//
//  Why a grid instead of the old list of hazard spheres: a wall is not a ball.
//  Summarising a 4 m wall as one sphere with a 2 m radius put it ~0.5 m from a user
//  walking 1.2 m away from it. Cells keep the true shape, so "nearest thing in my
//  path" is a lookup, and things that left the camera view are still remembered.
//
//  Honesty rules:
//   • A cell nobody has seen is absent (unknown), never free.
//   • A cell the camera can see right now but that got no LiDAR hits is forgotten
//     after `visibleForgetSeconds` (the thing moved, or was noise).
//   • A cell out of view is remembered for `memorySeconds`, then dropped.
//   • The whole map is reset when tracking degrades (poses can jump).
//

import simd

nonisolated struct GridCell: Hashable, Sendable {
    let x: Int
    let z: Int
}

nonisolated struct CellState: Equatable, Sendable {
    /// Lowest / highest obstacle point above the floor (metres). nil = floor only.
    var bottom: Float?
    var top: Float?
    var lastSeen: Double

    var isObstacle: Bool { bottom != nil }
}

nonisolated struct ObstacleMapConfig: Equatable, Sendable {
    var cellSize: Float = 0.1
    /// Points within this height of the floor count as floor. Below ~10 cm RANSAC
    /// floor noise and LiDAR noise make obstacles unreliable; those are cane territory.
    var floorBand: Float = 0.1
    /// Ignore points above this height (ceilings, lights).
    var maxObstacleHeight: Float = 2.3
    /// A cell needs this many points in one frame to count as an obstacle
    /// (suppresses isolated flying pixels at depth edges).
    var minObstacleHits: Int = 2
    var visibleForgetSeconds: Double = 0.8
    var memorySeconds: Double = 20
    /// Cells farther than this from the user are dropped.
    var keepRadius: Float = 7
}

nonisolated struct ObstacleMap: Sendable {
    let config: ObstacleMapConfig
    private(set) var cells: [GridCell: CellState] = [:]
    /// World y of the floor under the user, nil until first estimated.
    private(set) var floorY: Float?

    init(config: ObstacleMapConfig = ObstacleMapConfig()) {
        self.config = config
    }

    mutating func reset() {
        cells.removeAll()
        floorY = nil
    }

    /// Smooths floor estimates so a single RANSAC outlier cannot shift every cell.
    mutating func updateFloor(y: Float) {
        floorY = floorY.map { 0.8 * $0 + 0.2 * y } ?? y
    }

    func cell(containing world: SIMD2<Float>) -> GridCell {
        GridCell(x: Int((world.x / config.cellSize).rounded(.down)),
                 z: Int((world.y / config.cellSize).rounded(.down)))
    }

    /// Floor-plane centre (world x, world z) of a cell.
    func center(of cell: GridCell) -> SIMD2<Float> {
        SIMD2<Float>((Float(cell.x) + 0.5) * config.cellSize, (Float(cell.z) + 0.5) * config.cellSize)
    }

    func state(at cell: GridCell) -> CellState? { cells[cell] }

    /// Integrates one frame of world-space LiDAR points.
    ///
    /// `isVisible` answers "does the camera see this world point right now?" so
    /// that cells in view without fresh hits are cleared. Requires a floor height.
    mutating func integrate(points: [SIMD3<Float>], user: SIMD3<Float>, now: Double,
                            isVisible: (SIMD3<Float>) -> Bool) {
        guard let floorY else {
            preconditionFailure("ObstacleMap.integrate called before a floor height was set")
        }

        // 1. Bucket this frame's points.
        var obstacleHits: [GridCell: (bottom: Float, top: Float, count: Int)] = [:]
        var floorHits = Set<GridCell>()
        for p in points {
            let h = p.y - floorY
            guard h <= config.maxObstacleHeight else { continue }
            let key = cell(containing: SIMD2<Float>(p.x, p.z))
            if h < config.floorBand {
                if h > -config.floorBand { floorHits.insert(key) }   // below the band = hole / noise
                continue
            }
            if let e = obstacleHits[key] {
                obstacleHits[key] = (min(e.bottom, h), max(e.top, h), e.count + 1)
            } else {
                obstacleHits[key] = (h, h, 1)
            }
        }

        // 2. Obstacle extents grow while a cell lives: walking up to a pole pushes
        //    its base out of the bottom of the frame, and that must not turn it
        //    into a head-height obstacle. Floor hits never overwrite an obstacle
        //    (floor is visible under a table); step 3 clears obstacles that are gone.
        var refreshed = Set<GridCell>()
        for (key, hit) in obstacleHits where hit.count >= config.minObstacleHits {
            var bottom = hit.bottom, top = hit.top
            if let old = cells[key], let oldBottom = old.bottom, let oldTop = old.top {
                bottom = min(bottom, oldBottom)
                top = max(top, oldTop)
            }
            cells[key] = CellState(bottom: bottom, top: top, lastSeen: now)
            refreshed.insert(key)
        }
        for key in floorHits where !refreshed.contains(key) && cells[key]?.isObstacle != true {
            cells[key] = CellState(bottom: nil, top: nil, lastSeen: now)
            refreshed.insert(key)
        }

        // 3. Forget what is stale, far away, or visibly gone.
        let userXZ = SIMD2<Float>(user.x, user.z)
        let keepRadiusSquared = config.keepRadius * config.keepRadius
        for (key, state) in cells where !refreshed.contains(key) {
            let age = now - state.lastSeen
            let c = center(of: key)
            if age > config.memorySeconds || simd_distance_squared(c, userXZ) > keepRadiusSquared {
                cells.removeValue(forKey: key)
                continue
            }
            guard age > config.visibleForgetSeconds else { continue }
            let midHeight = ((state.bottom ?? 0) + (state.top ?? 0)) / 2
            if isVisible(SIMD3<Float>(c.x, floorY + midHeight, c.y)) {
                cells.removeValue(forKey: key)
            }
        }
    }
}
