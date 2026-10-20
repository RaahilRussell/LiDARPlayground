# LiDARPlayground

An educational **sensor laboratory** for the iPhone's LiDAR scanner, camera, and
ARKit tracking. It's a developer tool for *seeing* the raw output of Apple's
depth sensing — a stepping stone before building a larger assistive-navigation
platform, not a production navigation app.

Built with SwiftUI + ARKit + SceneKit + CoreVideo/CoreImage + simd. No third-party
dependencies. Target device: **iPhone 15 Pro Max** (any LiDAR-equipped iPhone/iPad
Pro works).

---

## Run instructions

1. Open `test.xcodeproj` in Xcode 26+.
2. **Target `test` → General → Supported Destinations**: keep **iPhone** / **iPad**
   only (macOS & visionOS removed — ARKit world tracking is iOS-only). *(done)*
3. **Signing & Capabilities → Team**: select your Apple ID / team.
4. **Info**: `Privacy - Camera Usage Description` is set (`NSCameraUsageDescription`). *(done)*
5. Select your **iPhone 15 Pro Max** as the run destination and press **Run**.

> **Simulator note:** the app compiles and runs in the Simulator, but ARKit world
> tracking + LiDAR depth do **not** exist there — AR tabs show an "unsupported"
> state. All depth/mesh/point-cloud behavior must be verified **on-device**, and
> has not been physically tested yet (⚠️ *awaiting device verification*).

---

## What the app shows (5 tabs + a persistent status strip)

The status strip (above every tab) shows: **tracking · FPS · depth on/off ·
valid-depth % · thermal state**.

| Tab | Feature |
|-----|---------|
| **Camera** | Live rear feed, Start/Pause/Reset, FPS, tracking state, frame timestamp, session state. |
| **Depth** | Depth heatmap (Turbo colormap), raw/smoothed toggle, min/max/median + buffer resolution, center + tap-to-measure distance, adjustable 0–N m range, confidence heatmap, confidence filter, usable %, and an experimental center distance probe. Invalid pixels drawn in **magenta** — never shown as free space. |
| **Point Cloud** | Depth → 3D points via camera intrinsics + pose, RGB-colored, camera/world-space toggle, orbit/pan/zoom, density + point count, XYZ axes in metres (capped at 60k points). |
| **3D Mesh** | ARKit scene reconstruction: wireframe / solid / classification coloring, anchor + vertex/face counts, world axes, tracked-camera marker, Reset Map. |
| **Data** | Live pose (local X/Y/Z + orientation), displacement, top-down movement trail, intrinsics & transform matrices, RGB/depth dimensions, timestamps, example depth grid + 3D points (all with plain-English explanations), and **Record & Export**. |

### Record & Export (Data tab)
A **3-second**, memory-bounded capture (≤ 20k points), exported via the iOS share
sheet so you can AirDrop/save to your Mac:
- `depth_matrix.csv` — depth buffer in metres
- `metadata.json` — intrinsics, transform, dimensions, tracking quality, counts
- `camera_poses.csv` — pose samples (position + quaternion)
- `point_cloud.ply` — sampled RGB point cloud (opens in MeshLab, Blender, etc.)

Recording only happens on an explicit tap — never continuously.

---

## Understanding ARKit's sensor outputs

- **`ARFrame.capturedImage`** — the full-res camera image (YCbCr, ~1920×1440).
- **`sceneDepth` / `smoothedSceneDepth` (`ARDepthData`)** — a **256×192 float32**
  depth map in **metres**. `smoothed` is temporally stabilized (less flicker);
  `raw` is more responsive. The depth buffer is far lower resolution than the
  camera image but shares its aspect ratio.
- **`confidenceMap`** — one byte per depth pixel: `low (0)`, `medium (1)`,
  `high (2)`. Low-confidence or zero/NaN depth means *"no reliable measurement"* —
  this app renders those distinctly and never substitutes a fake value.
- **`camera.intrinsics`** — 3×3 matrix with focal lengths (fx, fy) and optical
  center (cx, cy), expressed for the captured-image resolution. To unproject a
  depth pixel we scale these to the 256×192 buffer.
- **`camera.transform`** — 4×4 camera pose in ARKit **world space** (metres).
  Coordinates are **LOCAL** to the session origin — **not GPS**. x = right,
  y = up, z = toward the viewer (forward is −z).
- **Scene reconstruction (`ARMeshAnchor`)** — LiDAR-built triangle mesh of the
  room, delivered as add/update/remove anchor events with optional per-face
  **classification** (wall, floor, ceiling, table, seat, window, door).

**Unprojection** (pixel + depth → 3D), used by the point cloud, inspector, and export:
```
x_cam = (u - cx) * d / fx
y_cam = (v - cy) * d / fy
point_cam   = (x_cam, -y_cam, -d)          // ARKit camera space
point_world = camera.transform * point_cam  // world space
```

---

## Engineering notes

- **One `ARSession`**, owned solely by `ARSessionManager` (`@Observable`,
  `@MainActor`), injected through the SwiftUI environment. No tab ever creates a
  second session; AR views attach to the shared one and the manager stays the
  single `ARSessionDelegate`.
- Per-frame delegate work is lightweight (runs on the main queue, as ARKit
  delivers it). Heavy pixel work (heatmaps, point clouds, confidence %) runs on
  **detached background tasks** and is **throttled** (depth ~12 Hz, point cloud
  ~7 Hz, mesh rebuild ~2.5 Hz).
- Feature-support checks gate every capability (`supportsSceneDepth`,
  `supportsSceneReconstruction`, …).
- Handles session interruptions, backgrounding/foregrounding, nil frames, and
  missing confidence buffers.

---

## On-device test checklist (iPhone 15 Pro Max)

> AI Perception Phases 7–9 (Benchmarks, Inspector, unit tests) have their own
> checklist in [`docs/DEVICE_VALIDATION.md`](docs/DEVICE_VALIDATION.md).

- [ ] App launches; camera permission prompt appears; feed is live.
- [ ] Status strip updates: FPS ~60, tracking → Normal, depth On, valid % > 0, thermal nominal.
- [ ] Camera: Pause stops the feed; Start resumes; Reset re-initializes tracking.
- [ ] Depth: heatmap matches scene; near = one end of the colormap, far = the other.
- [ ] Depth: raw vs smoothed differ; range slider rescales colors; invalid areas are magenta.
- [ ] Depth: tap moves the crosshair and updates the distance + confidence.
- [ ] Depth: center probe ≈ a tape-measured distance to a wall (sanity check).
- [ ] Confidence heatmap + "hide low-confidence" behave; usable % drops on shiny/dark surfaces.
- [ ] Point cloud: recognizable 3D shape; orbit/pan/zoom work; density changes point count; world vs camera space differ as you move.
- [ ] Mesh: walking around a room accumulates mesh; wireframe/solid/classification render; counts climb; Reset Map clears it.
- [ ] Data: pose numbers change as you move; trail draws; displacement grows; matrices populate; example depths look sane.
- [ ] Export: record → share sheet → files save to Mac; PLY opens in a 3D viewer.
- [ ] Background the app and return — session resumes cleanly.

---

## What's reusable for the larger navigation system

- **`ARSessionManager`** — the single-session-owner pattern, capability gating,
  interruption/thermal handling: a drop-in sensing core.
- **`PointCloudGenerator` / `DepthProcessing` / `SensorSnapshot.unprojectToWorld`** —
  correct, thread-safe depth→metric-3D math (intrinsics scaling, camera→world).
- **Confidence handling** — treating low/invalid depth as *unknown*, never as
  free space: the exact safety primitive navigation needs.
- **`MeshGeometryBuilder`** — ARKit mesh → geometry + semantic classification,
  a basis for traversability / obstacle reasoning.
- **Exporters** — logging real sensor data (CSV/JSON/PLY) for offline analysis
  and algorithm development.
