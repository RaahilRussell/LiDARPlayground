//
//  NavigationTests.swift
//  testTests
//
//  Wearer Mode core: portrait camera axes, the obstacle map, the path scan, and
//  the alert policy. Deterministic fixtures only. The user stands at the origin
//  facing world −Z with the phone in portrait at 1.35 m; the floor is y = 0.
//

import CoreGraphics
import simd
import Testing
@testable import test

@MainActor
@Suite("Navigation core")
struct NavigationTests {

    // MARK: Fixtures

    /// Portrait phone facing −Z. ARKit camera axes are fixed to the sensor:
    /// +x = long edge (down in portrait), +y = user's right, +z = out of the screen.
    static func portraitCamera(at p: SIMD3<Float> = SIMD3(0, 1.35, 0)) -> simd_float4x4 {
        simd_float4x4(columns: (SIMD4<Float>(0, -1, 0, 0),
                                SIMD4<Float>(1, 0, 0, 0),
                                SIMD4<Float>(0, 0, 1, 0),
                                SIMD4<Float>(p.x, p.y, p.z, 1)))
    }

    static let user = UserFrame(position: SIMD3(0, 1.35, 0), forward: SIMD2(0, -1))

    /// Vertical run of points inside the 10 cm cell whose centre is (x, z).
    static func column(x: Float, z: Float, bottom: Float, top: Float) -> [SIMD3<Float>] {
        var points: [SIMD3<Float>] = []
        var y = bottom
        while y <= top {
            for dx: Float in [-0.02, 0.02] { for dz: Float in [-0.02, 0.02] {
                points.append(SIMD3(x + dx, y, z + dz))
            }}
            y += 0.05
        }
        return points
    }

    /// Floor points every 10 cm across the rectangle, bounds included.
    static func floorPatch(x: ClosedRange<Float>, z: ClosedRange<Float>) -> [SIMD3<Float>] {
        let nx = Int(((x.upperBound - x.lowerBound) / 0.1).rounded())
        let nz = Int(((z.upperBound - z.lowerBound) / 0.1).rounded())
        var points: [SIMD3<Float>] = []
        for i in 0...nx {
            for j in 0...nz {
                points.append(SIMD3(x.lowerBound + Float(i) * 0.1, 0, z.lowerBound + Float(j) * 0.1))
            }
        }
        return points
    }

    static func map(_ points: [SIMD3<Float>], now: Double = 0) -> ObstacleMap {
        var m = ObstacleMap()
        m.updateFloor(y: 0)
        m.integrate(points: points, user: user.position, now: now, isVisible: { _ in false })
        return m
    }

    static func obstacle(_ kind: ObstacleKind, at distance: Float, bottom: Float = 0.1) -> PathObstacle {
        PathObstacle(distance: distance, lateral: 0, kind: kind, bottom: bottom, top: 1.9,
                     cellCenter: SIMD2(0, -distance))
    }

    static func input(_ t: Double, _ ahead: PathObstacle?, speed: Float = 0,
                      sensing: SensingStatus = .ok, openings: [Opening] = []) -> AlertInput {
        AlertInput(now: t, sensing: sensing, ahead: ahead, speed: speed, openings: openings, label: nil)
    }

    // MARK: Axes (the bug that made walls beside the user read as "dead ahead")

    @Test func userFrameUsesTheFloorPlaneNotCameraAxes() throws {
        let user = try #require(UserFrame(cameraTransform: Self.portraitCamera()))
        #expect(simd_distance(user.forward, SIMD2(0, -1)) < 1e-5)
        #expect(simd_distance(user.right, SIMD2(1, 0)) < 1e-5)
        let wallBeside = user.local(SIMD3(1.0, 1.35, -0.2))     // 1 m right, 0.2 m ahead
        #expect(abs(wallBeside.ahead - 0.2) < 1e-5)
        #expect(abs(wallBeside.lateral - 1.0) < 1e-5)
    }

    @Test func userFrameIsUndefinedWhenThePhoneFacesTheFloor() {
        let down = simd_float4x4(columns: (SIMD4<Float>(1, 0, 0, 0), SIMD4<Float>(0, 0, -1, 0),
                                           SIMD4<Float>(0, 1, 0, 0), SIMD4<Float>(0, 1.35, 0, 1)))
        #expect(UserFrame(cameraTransform: down) == nil)
    }

    @Test func portraitDepthPixelsLandOnTheCorrectSide() {
        let k = simd_float3x3(columns: (SIMD3(1450, 0, 0), SIMD3(0, 1450, 0), SIMD3(960, 720, 1)))
        let projection = CameraProjection(intrinsics: k, imageResolution: CGSize(width: 1920, height: 1440),
                                          depthWidth: 256, depthHeight: 192,
                                          cameraTransform: Self.portraitCamera())
        // Depth rows above the centre row are the right-hand side of a portrait view.
        let right = projection.unproject(x: 128, y: 20, depth: 2)
        #expect(right.x > 0.5)
        #expect(abs(right.y - 1.35) < 0.01)
        #expect(abs(right.z + 2) < 0.01)
        // Depth columns past the centre column are the lower part of a portrait view.
        #expect(projection.unproject(x: 250, y: 96, depth: 2).y < 1.0)
        #expect(projection.isVisible(right))
        #expect(!projection.isVisible(SIMD3(0, 1.35, 2)), "behind the camera")
    }

    // MARK: Floor

    @Test func floorIsTheLowestLevelPlaneNotTheBiggest() throws {
        var points = Self.floorPatch(x: -1 ... 1, z: -3 ... -1)                  // 21 × 21 floor points
        for i in 0..<900 {                                                       // a larger table top
            points.append(SIMD3(Float(i % 30) * 0.06 - 0.9, 0.75, -0.8 - Float(i / 30) * 0.05))
        }
        var rng = SeededGenerator(seed: 11)
        let floorY = try #require(FloorEstimator.floorY(points: points, camera: SIMD3(0, 1.35, 0), using: &rng))
        #expect(abs(floorY) < 0.02)
    }

    @Test func floorEstimateTerminatesOnARamp() throws {
        // 5° downhill ahead: refitting by "below the height at the camera" looped forever here.
        let ramp = Self.floorPatch(x: -1 ... 1, z: -4.5 ... -0.5).map { SIMD3($0.x, 0.0875 * $0.z, $0.z) }
        var rng = SeededGenerator(seed: 5)
        let floorY = try #require(FloorEstimator.floorY(points: ramp, camera: SIMD3(0, 1.35, 0), using: &rng))
        #expect(abs(floorY) < 0.05)
    }

    // MARK: Map + path

    @Test func hallwayWallsAreNotInThePath() {
        var walls: [SIMD3<Float>] = []
        var z: Float = -0.55
        while z >= -4.05 {
            walls += Self.column(x: 1.05, z: z, bottom: 0.15, top: 2.2)
            walls += Self.column(x: -1.05, z: z, bottom: 0.15, top: 2.2)
            z -= 0.1
        }
        #expect(PathScanner.nearestObstacle(map: Self.map(walls), user: Self.user) == nil)
    }

    @Test func poleAheadIsAGroundObstacle() throws {
        let m = Self.map(Self.column(x: 0.05, z: -2.05, bottom: 0.15, top: 1.9))
        let o = try #require(PathScanner.nearestObstacle(map: m, user: Self.user))
        #expect(o.kind == .ground)
        #expect(abs(o.distance - 2.0) < 0.01)
    }

    @Test func signAboveCaneSweepIsOverhead() throws {
        let m = Self.map(Self.column(x: 0.05, z: -1.55, bottom: 1.5, top: 1.9))
        let o = try #require(PathScanner.nearestObstacle(map: m, user: Self.user))
        #expect(o.kind == .overhead)
        #expect(AlertPolicy.name(of: o, label: nil) == "Head height obstacle")
    }

    @Test func approachingAPoleKeepsItsBase() throws {
        var m = Self.map(Self.column(x: 0.05, z: -2.05, bottom: 0.15, top: 1.9))
        // Up close only the top of the pole is in frame.
        m.integrate(points: Self.column(x: 0.05, z: -2.05, bottom: 1.1, top: 1.9),
                    user: Self.user.position, now: 0.1, isVisible: { _ in true })
        let o = try #require(PathScanner.nearestObstacle(map: m, user: Self.user))
        #expect(o.kind == .ground, "a pole must not turn into a head-height obstacle")
    }

    @Test func floorUnderAnObstacleDoesNotEraseIt() {
        var m = Self.map(Self.column(x: 0.05, z: -2.05, bottom: 0.72, top: 0.76))     // table edge
        m.integrate(points: [SIMD3(0.05, 0, -2.05)], user: Self.user.position, now: 0.1, isVisible: { _ in false })
        #expect(m.state(at: GridCell(x: 0, z: -21))?.isObstacle == true)
    }

    @Test func visibleButEmptyCellsAreForgottenAndHiddenOnesRemembered() {
        let pole = Self.column(x: 0.05, z: -2.05, bottom: 0.15, top: 1.9)
        var seen = Self.map(pole)
        seen.integrate(points: [], user: Self.user.position, now: 0.5, isVisible: { _ in true })
        #expect(seen.cells.count == 1, "within the forget window")
        seen.integrate(points: [], user: Self.user.position, now: 1.0, isVisible: { _ in true })
        #expect(seen.cells.isEmpty, "in view with no hits: gone")

        var hidden = Self.map(pole)
        hidden.integrate(points: [], user: Self.user.position, now: 10, isVisible: { _ in false })
        #expect(hidden.cells.count == 1, "out of view: remembered")
        hidden.integrate(points: [], user: Self.user.position, now: 21, isVisible: { _ in false })
        #expect(hidden.cells.isEmpty, "past memorySeconds: dropped")
    }

    @Test func freeRunSeparatesObstaclesFromUnmappedFloor() {
        #expect(PathScanner.freeRun(map: Self.map([]), user: Self.user).end == .unexplored)

        let floor = Self.floorPatch(x: -0.55 ... 0.55, z: -4.45 ... -0.05)
        let clear = PathScanner.freeRun(map: Self.map(floor), user: Self.user)
        #expect(clear.end == .clear && clear.meters == 4)

        let blocked = PathScanner.freeRun(map: Self.map(floor + Self.column(x: 0.05, z: -2.05, bottom: 0.15, top: 1.9)),
                                          user: Self.user)
        #expect(blocked.end == .obstacle)
        #expect(blocked.meters > 1.8 && blocked.meters < 2.1)
    }

    // MARK: Alert policy

    @Test func caneUsersGetOnlyANoticeForGroundObstacles() {
        var p = AlertPolicy()
        let d = p.decide(Self.input(0, Self.obstacle(.ground, at: 0.5), speed: 1.2))
        #expect(d.level == .notice)
        #expect(d.speech == nil)
        #expect(d.haptic?.texture == .tap)
    }

    @Test func withoutACaneGroundObstaclesStop() {
        var p = AlertPolicy(profile: NavigationProfile(caneUser: false))
        let d = p.decide(Self.input(0, Self.obstacle(.ground, at: 0.5)))
        #expect(d.level == .stop)
        #expect(d.speech == Utterance(text: "Stop. Obstacle, less than 1 meter.", interrupt: true))
    }

    @Test func overheadObstaclesEscalateWithSpeechAndADoubleTap() {
        var p = AlertPolicy()
        let d = p.decide(Self.input(0, Self.obstacle(.overhead, at: 1.5, bottom: 1.5)))
        #expect(d.level == .warning)
        #expect(d.haptic?.texture == .doubleTap)
        #expect(d.speech?.text == "Head height obstacle ahead, 2 meters.")
    }

    @Test func standingStillPulsesOnlyWhenTheLevelRises() {
        var p = AlertPolicy()
        let o = Self.obstacle(.overhead, at: 1.5, bottom: 1.5)
        let first = p.decide(Self.input(0, o))
        #expect(first.haptic != nil)
        for t in [0.5, 1.0, 2.0] { let d = p.decide(Self.input(t, o)); #expect(d.haptic == nil) }
        let closer = p.decide(Self.input(2.1, Self.obstacle(.overhead, at: 0.8, bottom: 1.5)))
        #expect(closer.haptic != nil, "rise to STOP")
    }

    @Test func walkingRepeatsPulsesAtTheLevelCadence() {
        var p = AlertPolicy()
        let o = Self.obstacle(.overhead, at: 2.0, bottom: 1.5)                  // TTC 2 s → WARNING
        let first = p.decide(Self.input(0, o, speed: 1))
        #expect(first.level == .warning)
        let early = p.decide(Self.input(0.3, o, speed: 1))
        #expect(early.haptic == nil)
        let due = p.decide(Self.input(0.5, o, speed: 1))
        #expect(due.haptic != nil)
    }

    @Test func timeToContactRaisesTheLevelOnlyWhileWalking() {
        let p = AlertPolicy(profile: NavigationProfile(caneUser: false))
        let o = Self.obstacle(.ground, at: 2.5)
        #expect(p.targetLevel(Self.input(0, o, speed: 0)) == .notice)
        #expect(p.targetLevel(Self.input(0, o, speed: 1.25)) == .warning)
    }

    @Test func levelStepsDownOnlyAfterTheReleaseHold() {
        var p = AlertPolicy()
        let first = p.decide(Self.input(0, Self.obstacle(.overhead, at: 1.5, bottom: 1.5)))
        #expect(first.level == .warning)
        let held = p.decide(Self.input(0.1, nil))
        #expect(held.level == .warning)
        let stillHeld = p.decide(Self.input(0.5, nil))
        #expect(stillHeld.level == .warning)
        let released = p.decide(Self.input(0.8, nil))
        #expect(released.level == .clear)
    }

    @Test func theSameObstacleIsNotAnnouncedTwiceAtTheSameLevel() {
        var p = AlertPolicy()
        let o = Self.obstacle(.overhead, at: 1.5, bottom: 1.5)
        let first = p.decide(Self.input(0, o))
        #expect(first.speech != nil)
        let later = p.decide(Self.input(7, o))
        #expect(later.speech == nil)
        let closer = p.decide(Self.input(7.1, Self.obstacle(.overhead, at: 0.9, bottom: 1.5)))
        #expect(closer.speech?.interrupt == true)
    }

    @Test func losingTheSensorIsAnnouncedOnceAfterAGraceAndRecoveryIsSpoken() {
        var p = AlertPolicy()
        let withinGrace = p.decide(Self.input(0, nil, sensing: .noDepth))
        #expect(withinGrace.speech == nil)
        let lost = p.decide(Self.input(1.0, nil, sensing: .noDepth))
        #expect(lost.speech?.text == SensingStatus.noDepth.spokenWarning)
        #expect(lost.haptic == HapticCue.sensingLost)
        let again = p.decide(Self.input(2.0, nil, sensing: .noDepth))
        #expect(again.speech == nil)
        let recovered = p.decide(Self.input(3.0, nil))
        #expect(recovered.speech?.text == "Sensing again.")
    }

    @Test func clearerSideNeedsTwoMetresOfObservedFloor() {
        let openings = [Opening(bearingDegrees: -40, freeMeters: 0.5, end: .unexplored),
                        Opening(bearingDegrees: 0, freeMeters: 0.4, end: .obstacle),
                        Opening(bearingDegrees: 40, freeMeters: 3.0, end: .clear)]
        #expect(AlertPolicy.clearerSide(openings) == "right")
        #expect(AlertPolicy.clearerSide(Array(openings.prefix(2))) == nil)
    }

    @Test func describerSaysUnmappedInsteadOfOpen() {
        let a = PathAssessment(ahead: nil, openings: [
            Opening(bearingDegrees: -40, freeMeters: 0.8, end: .obstacle),
            Opening(bearingDegrees: 0, freeMeters: 4, end: .clear),
            Opening(bearingDegrees: 40, freeMeters: 0, end: .unexplored)])
        #expect(SurroundingsDescriber.describe(sensing: .ok, assessment: a, aheadLabel: nil)
                == "Ahead: open for at least 4 meters. Left: blocked after less than 1 meter. Right: not mapped yet.")
    }
}
