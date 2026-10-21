//
//  PathScanner.swift
//  test
//
//  Reads the ObstacleMap from the user's point of view:
//   • the nearest obstacle in the walking corridor straight ahead, and
//   • how far the user could walk in a few directions before hitting something
//     or running out of map (used to say where it is clearer).
//
//  Heights follow the ADA protruding-objects rule (2010 ADA Standards 307): a long
//  cane sweeps up to 27 in (0.686 m); anything whose bottom edge is higher is
//  invisible to the cane. 80 in (2.03 m) is minimum headroom.
//

import simd

nonisolated enum ObstacleKind: String, Sendable {
    /// Reaches down to cane height: a long cane will find it.
    case ground
    /// Free space under it: the cane passes beneath. Chest or head height.
    case overhead
}

nonisolated struct PathObstacle: Equatable, Sendable {
    /// Metres from the user to the obstacle's near edge, along the walking direction.
    var distance: Float
    /// Metres to the right (+) or left (−) of the walking line.
    var lateral: Float
    var kind: ObstacleKind
    var bottom: Float
    var top: Float
    /// Floor-plane centre of the cell (world x, world z), for label lookup and identity.
    var cellCenter: SIMD2<Float>
}

nonisolated enum OpeningEnd: String, Sendable {
    /// An obstacle in the corridor width ends the free stretch.
    case obstacle
    /// The floor beyond has never been observed: unknown, not free.
    case unexplored
    /// Free for the whole scan range.
    case clear
}

nonisolated struct Opening: Equatable, Sendable {
    /// + = right of the current heading.
    var bearingDegrees: Float
    /// Metres of observed floor without obstacles, up to the scan range.
    var freeMeters: Float
    var end: OpeningEnd
}

nonisolated struct PathAssessment: Equatable, Sendable {
    var ahead: PathObstacle?
    var openings: [Opening]
}

nonisolated struct PathScannerConfig: Equatable, Sendable {
    /// Half the body width plus margin. Shoulders are ~0.45 m wide.
    var corridorHalfWidth: Float = 0.35
    var lookahead: Float = 4
    var caneSweepHeight: Float = 0.686
    var headroom: Float = 2.03
    var openingBearings: [Float] = [-60, -40, -20, 0, 20, 40, 60]
}

nonisolated enum PathScanner {

    static func assess(map: ObstacleMap, user: UserFrame,
                       config: PathScannerConfig = PathScannerConfig()) -> PathAssessment {
        PathAssessment(
            ahead: nearestObstacle(map: map, user: user, config: config),
            openings: config.openingBearings.map { bearing in
                let run = freeRun(map: map, user: user.turned(by: bearing), config: config)
                return Opening(bearingDegrees: bearing, freeMeters: run.meters, end: run.end)
            })
    }

    /// Nearest obstacle cell whose square overlaps the corridor ahead. Unknown cells
    /// are skipped: an unseen floor patch must not hide a seen obstacle behind it.
    static func nearestObstacle(map: ObstacleMap, user: UserFrame,
                                config: PathScannerConfig = PathScannerConfig()) -> PathObstacle? {
        let half = map.config.cellSize / 2
        var best: PathObstacle?
        for (key, state) in map.cells {
            guard let bottom = state.bottom, let top = state.top, bottom < config.headroom else { continue }
            let c = map.center(of: key)
            let (ahead, lateral) = user.local(SIMD3<Float>(c.x, 0, c.y))
            guard ahead + half > 0, ahead - half <= config.lookahead,
                  abs(lateral) - half <= config.corridorHalfWidth else { continue }
            let candidate = PathObstacle(
                distance: max(0, ahead - half), lateral: lateral,
                kind: bottom >= config.caneSweepHeight ? .overhead : .ground,
                bottom: bottom, top: top, cellCenter: c)
            if isNearer(candidate, than: best) { best = candidate }
        }
        return best
    }

    /// Walks the corridor in `user`'s heading one cell at a time and returns how far
    /// it stays on observed, obstacle-free floor. Stops at the first obstacle in
    /// the corridor width or the first never-observed cell on the centre line.
    static func freeRun(map: ObstacleMap, user: UserFrame,
                        config: PathScannerConfig = PathScannerConfig()) -> (meters: Float, end: OpeningEnd) {
        let step = map.config.cellSize
        let lateralSteps = Int((config.corridorHalfWidth / step).rounded(.up))
        var ahead = step
        while ahead <= config.lookahead {
            for i in -lateralSteps...lateralSteps {
                let key = map.cell(containing: user.world(ahead: ahead, lateral: Float(i) * step))
                if let s = map.state(at: key), let bottom = s.bottom, bottom < config.headroom {
                    return (ahead - step, .obstacle)
                }
            }
            if map.state(at: map.cell(containing: user.world(ahead: ahead, lateral: 0))) == nil {
                return (ahead - step, .unexplored)
            }
            ahead += step
        }
        return (config.lookahead, .clear)
    }

    /// Closer wins; at equal distance an overhead obstacle wins (the cane misses it).
    private static func isNearer(_ a: PathObstacle, than b: PathObstacle?) -> Bool {
        guard let b else { return true }
        if a.distance != b.distance { return a.distance < b.distance }
        return a.kind == .overhead && b.kind == .ground
    }
}
