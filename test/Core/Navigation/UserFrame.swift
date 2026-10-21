//
//  UserFrame.swift
//  test
//
//  The gravity-aligned walking frame: where the user is, which way is "ahead",
//  and which way is "right", all on the world floor plane.
//
//  ARKit camera space is fixed to the sensor: +x runs along the device's long
//  edge, so in PORTRAIT the camera x axis is vertical and the camera y axis is
//  the user's left/right. Reading left/right or distance from camera x (what the
//  old WorldHazardMap did) turns a wall beside the user into a "dead ahead, 5 cm"
//  hazard. Every "ahead / left / right" question goes through this type instead.
//
//  World space is gravity aligned (ARWorldTrackingConfiguration.worldAlignment =
//  .gravity): +y is up, so the floor plane is world XZ.
//

import simd

nonisolated struct UserFrame: Equatable, Sendable {
    /// Camera position in world metres.
    let position: SIMD3<Float>
    /// Unit walking direction on the floor plane, stored as (world x, world z).
    let forward: SIMD2<Float>
    /// Unit direction to the user's right on the floor plane, (world x, world z).
    let right: SIMD2<Float>

    /// Heading is the camera's viewing direction (−z) projected onto the floor.
    /// Returns nil when the phone points nearly straight up or down, because the
    /// heading is then undefined; callers report that instead of guessing.
    init?(cameraTransform t: simd_float4x4, minHorizontal: Float = 0.35) {
        let view = SIMD2<Float>(-t.columns.2.x, -t.columns.2.z)
        let length = simd_length(view)
        guard length >= minHorizontal else { return nil }
        let f = view / length
        forward = f
        right = SIMD2<Float>(-f.y, f.x)
        position = SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
    }

    init(position: SIMD3<Float>, forward: SIMD2<Float>) {
        let f = simd_normalize(forward)
        self.position = position
        self.forward = f
        self.right = SIMD2<Float>(-f.y, f.x)
    }

    /// Metres ahead of the user and to their right (+) or left (−), on the floor plane.
    func local(_ world: SIMD3<Float>) -> (ahead: Float, lateral: Float) {
        let d = SIMD2<Float>(world.x - position.x, world.z - position.z)
        return (simd_dot(d, forward), simd_dot(d, right))
    }

    /// World floor-plane point (x, z) at `ahead` / `lateral` metres from the user.
    func world(ahead: Float, lateral: Float) -> SIMD2<Float> {
        SIMD2<Float>(position.x, position.z) + forward * ahead + right * lateral
    }

    /// The same user turned by `degrees` (+ = clockwise, toward the right).
    func turned(by degrees: Float) -> UserFrame {
        let r = degrees * .pi / 180
        return UserFrame(position: position, forward: forward * cos(r) + right * sin(r))
    }
}
