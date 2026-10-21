# LiDARPlayground

An educational **mapping and sensor laboratory** for the iPhone's LiDAR scanner,
camera, and motion tracking. Scan and save places, revisit their reconstructed
surfaces in 3D, or return in person to relocalize and continue a scan. The app
also contains developer diagnostics and experimental assistive feedback; it is
not a production navigation app.

Built with SwiftUI + ARKit + SceneKit + CoreVideo/CoreImage + simd. The optional
AI perception features use the UltralyticsYOLO Swift package and bundled Core ML
models. Package resolution is recorded in `Package.resolved`. Target device:
**iPhone 15 Pro Max**, running **iOS 26.5 or later**; other compatible LiDAR-equipped
iPhones and iPad Pro models support the same mapping APIs.

---

## Run instructions

1. Open `test.xcodeproj` in **Xcode 26.5 or later** and resolve Swift packages.
2. **Target `test` → General → Supported Destinations**: keep **iPhone** / **iPad**
   only (macOS & visionOS removed — ARKit world tracking is iOS-only). *(done)*
3. **Signing & Capabilities → Team**: select your Apple ID / team.
4. **Info**: `Privacy - Camera Usage Description` is set (`NSCameraUsageDescription`). *(done)*
5. Select your **iPhone 15 Pro Max** as the run destination and press **Run**.

> **Simulator note:** ARKit world tracking and LiDAR depth do **not** exist in the
> Simulator. Live mapping shows an unsupported state; storage and algorithm tests
> can run there. Physical scanning and relocalization still require on-device
> verification. See [device validation](docs/DEVICE_VALIDATION.md).

## Mapping and saved places

The app opens in **Maps**. Use the top selector to reach **Assist** or the
existing **Developer** tools.

1. In **Live Map**, allow camera access and move slowly around nearby textured
   surfaces. The camera/IMU world tracker and LiDAR scene reconstruction share
   one AR session. Tracking and map quality must be ready before saving.
2. Tap **Save Place**, name the scan, and wait for confirmation. **Save Changes**
   updates that place; **New Map** starts a separate scan after confirming that
   unsaved work can be discarded.
3. Open **Saved Places** to pause the camera and browse local scans. Drag to orbit,
   pinch to zoom, use two fingers to pan, toggle wireframe, or tap **Fit map**.
   Each row also offers rename and delete. Viewing works away from the location.
4. At the original location, open a saved place and choose **Revisit & Continue
   Mapping**. Match its reference photo. Stored surfaces appear in the camera
   view only after relocalization succeeds; then extend the scan and save again.
   If recognition takes too long, follow the guidance or cancel to start fresh.

Each saved place contains a securely archived `ARWorldMap`, independent copied
triangle geometry, a camera trail, a reference photo, and versioned metadata.
Files stay in local Application Support. Writes commit a complete revision
before replacing the manifest, so a failed save preserves the previous version.
Scans are bounded to 750,000 vertices and 1,500,000 triangles; split larger areas
into separate places. Missing surfaces are unknown, not evidence of free space.

See the [implementation plan](docs/MAPPING_PLAN.md),
[architecture review](docs/MAPPING_ARCHITECTURE.md), and
[device checklist](docs/DEVICE_VALIDATION.md). The shared `test` scheme and
`.github/workflows/ios.yml` run an unsigned iPhone build plus simulator regression
tests on macOS; this does not replace iPhone testing.

---

## Developer sensor tools (5 tabs + a persistent status strip)

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
