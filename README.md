# LiDARPlayground

An educational **mapping and sensor laboratory** for the iPhone's LiDAR scanner,
camera, and motion tracking. Map and save places automatically, revisit their
camera-coloured surfaces in 3D and captured photos in a gallery, or return in
person to relocalize and follow a previously walked path. Local text recognition
retains signs and text observations alongside each map. The app
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
   only (this app uses the iOS/iPadOS ARKit configuration). *(done)*
3. **Signing & Capabilities → Team**: select your Apple ID / team.
4. **Info**: `Privacy - Camera Usage Description` is set (`NSCameraUsageDescription`). *(done)*
5. Select your **iPhone 15 Pro Max** as the run destination and press **Run**.

> **Simulator note:** ARKit world tracking and LiDAR depth do **not** exist in the
> Simulator. Live mapping shows an unsupported state; navigation through the app,
> storage, and algorithm tests can run there. Physical scanning and relocalization still require on-device
> verification. See [device validation](docs/DEVICE_VALIDATION.md).

## Mapping and saved places

The app opens in **Camera**. Five visible destinations provide direct access to
**Camera**, **LiDAR**, **AI Vision**, **Maps**, and **Assist**. Open **Maps** for
the live map, saved places, routes, and text observations. Automatic mapping
continues while using other tools; switching screens does not pause the shared
camera or cancel an active route. A map-saving error also appears outside Maps
with an **Open Maps** action for reviewing the error and retrying the save.

1. In **Live Map**, allow camera access and move slowly around nearby textured
   surfaces. Camera/IMU world tracking and LiDAR scene reconstruction share one
   AR session. A usable map saves automatically, then checkpoints about every
   20 seconds while tracking and map quality allow it. **Name & Save Now** or
   **Save Now** makes an immediate checkpoint. Rename a place in the library.
2. Mapping continues across the app's screens while the app is active. Use
   **Pause Mapping** to stop sensing and **Resume Mapping** to continue. Moving
   to the background suspends camera work; this does not record with the phone
   locked or another app open. Work since the last successful checkpoint can be
   lost if the process is terminated. **New Map** explicitly starts fresh.
3. **Saved Places** opens local scans. In the 3D viewer, drag to orbit, pinch to
   zoom, use two fingers to pan, toggle wireframe, or tap **Fit map**. Surfaces
   retain real camera colours where a depth-validated sample exists; grey means
   colour was not observed. **Photos** shows retained camera keyframes. Orange
   markers locate recognized text; green markers identify named destinations.
   The viewer itself uses no camera or AR session. Pause mapping to browse
   without live sensing. Each library row also offers rename and delete.
4. At launch the app tries to recognize the latest saved place. At an earlier
   place, select it and choose **Revisit & Continue Mapping**. Match its reference
   photo. Saved overlays and directions become available only after tracking
   confirms the saved coordinate space. If automatic recognition times out, the
   app preserves the old map and starts a separate new place.
5. Walk the connections you want to use, enter a destination name, and tap
   **Mark here**. Choose **Go to …** or **Return to path start** for visual and
   spoken turn guidance. Keep the phone facing the direction of travel. Routing
   follows continuous recorded paths; tracking gaps, large jumps, and height
   changes break continuity. It cannot invent a route through unvisited space,
   join disconnected paths or separate places, confirm obstacle clearance, or
   replace a mobility aid.
6. Open **Text & Signs** to inspect local OCR observations, their image evidence,
   and detected arrow symbols or shapes. OCR runs at approximately one frame per
   second while mapping is active. Reliable depth places a text mark in the map;
   otherwise it remains an image observation. A sign arrow describes its image,
   not a verified world bearing, floor change, or walkable route.
   **Export text & directions** opens the share sheet for JSON containing
   separate text and directional-sign records, without embedding their photos.

Each saved place contains a securely archived `ARWorldMap`, independent copied
triangle geometry and vertex colours, calibrated JPEG keyframes, the camera
trail, recorded navigation graph and labels, text/sign observations, a reference
photo when available, and versioned metadata. Files stay in local Application
Support; colour sampling and OCR run on device. Writes commit a complete revision
before replacing the manifest, so a failed save preserves the previous version.

Long scans automatically checkpoint and continue in a new storage segment before
the working mesh, image, or text budget fills. Tracking retains the same origin,
and the latest segment keeps the continuous recorded paths and destination
labels. Mesh reconstruction starts a new chunk collection; older segment files
remain individually viewable rather than being stitched into one offline scene.
Open the latest segment to restore the latest route graph. **New Map**, or a new
place after failed launch recognition, starts a separate origin and route graph.
When path recording reaches its own capacity, it stops adding nodes while
mapping and existing destinations remain available. Failed segment saves retain
their checkpoint for **Retry Saving**, while the camera, LiDAR mesh, and computer
vision remain available. Photo/text intake waits for storage recovery, and the
retry includes surfaces observed since the failure. Existing uncoloured saved
maps remain readable. Missing surfaces and grey colour samples remain unknown
observations.

See the [implementation plan](docs/MAPPING_PLAN.md),
[architecture review](docs/MAPPING_ARCHITECTURE.md), and
[device checklist](docs/DEVICE_VALIDATION.md). The shared `test` scheme and
`.github/workflows/ios.yml` run an unsigned iPhone build plus simulator regression
tests on macOS; this does not replace iPhone testing.

---

## Camera and LiDAR tools

**Camera** opens the rear-camera view directly. **LiDAR** offers **Depth**,
**Point Cloud**, **3D Mesh**, and **Data** in its tool row. The selected LiDAR tool
is remembered when moving to another destination and back. The status strip
shows **tracking · FPS · depth on/off · valid-depth % · thermal state**.

| Tab | Feature |
|-----|---------|
| **Camera** | Live rear feed, Start/Pause/Reset, FPS, tracking state, frame timestamp, session state. |
| **Depth** | Depth heatmap (Turbo colormap), raw/smoothed toggle, min/max/median + buffer resolution, center + tap-to-measure distance, adjustable 0–N m range, confidence heatmap, confidence filter, usable %, and an experimental center distance probe. Invalid pixels drawn in **magenta** — never shown as free space. |
| **Point Cloud** | Depth → 3D points via camera intrinsics + pose, RGB-colored, camera/world-space toggle, orbit/pan/zoom, density + point count, XYZ axes in metres (capped at 60k points). |
| **3D Mesh** | ARKit scene reconstruction: wireframe / solid / classification coloring, anchor + vertex/face counts, world axes, tracked-camera marker, Reset Map. |
| **Data** | Live pose (local X/Y/Z + orientation), displacement, top-down movement trail, intrinsics & transform matrices, RGB/depth dimensions, timestamps, example depth grid + 3D points (all with plain-English explanations), and **Record & Export**. |

### Record & Export (LiDAR → Data)
A **3-second**, memory-bounded capture (≤ 20k points), exported via the iOS share
sheet so you can AirDrop/save to your Mac:
- `depth_matrix.csv` — depth buffer in metres
- `metadata.json` — intrinsics, transform, dimensions, tracking quality, counts
- `camera_poses.csv` — pose samples (position + quaternion)
- `point_cloud.ply` — sampled RGB point cloud (opens in MeshLab, Blender, etc.)

This three-second diagnostic export recording starts only on an explicit tap.
Automatic mapping, camera keyframes, and local OCR are separate foreground features.

### AI Vision and Assist

**AI Vision** opens **Live AI** by default. Scroll its tool row horizontally to
reach **Fused**, **Depth Lab**, **Fusion**, **Haptics**, **Benchmarks**, and
**Inspector**. All original tools remain available, and the selected tool is
remembered when returning from another destination. Live AI exposes the camera
and model controls; Fused combines model detections with spatial depth. The
remaining tools inspect depth filters, spatial results, haptic patterns,
performance, and raw perception data.

**Assist** provides the large controls for experimental spoken and haptic
guidance, with a direct shortcut back to AI Vision. Switching destinations does
not cancel a walking route; an active route offers **Show route** and **Stop**
outside Maps.

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
- Per-frame delegate work runs on the main queue. Heavy pixel work (heatmaps,
  point clouds, confidence, map colours, keyframe encoding, local OCR) runs on
  **detached background tasks** and is **throttled** (depth ~12 Hz, point cloud
  ~7 Hz, mesh rebuild ~2.5 Hz, map colours ~2 Hz, OCR ~1 Hz). At most one colour
  worker retains sensor buffers. Camera keyframes require time and viewpoint
  changes; normal colour samples only fill unseen vertices.
- Colour projection uses the captured frame's native sensor orientation,
  intrinsics, and camera pose. Matching LiDAR depth and medium/high confidence
  reject occluded or unreliable samples. Anchor-local spatial cells preserve
  valid observations when ARKit reorders or refines mesh vertices.
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
- [ ] Mapping saves automatically; reopening recognizes the same room before
      showing saved overlays or enabling directions.
- [ ] Coloured objects match the saved surface and gallery; occluded surfaces
      do not inherit foreground colours; missing confidence leaves grey areas.
- [ ] Label two locations along a walked route, follow directions both ways,
      and confirm a tracking gap or separate new map does not create a shortcut.
- [ ] Text and arrow evidence matches the sign; text without reliable depth
      has no invented world marker; OCR runs locally with networking unavailable.
- [ ] Force a segment rollover and a save failure; earlier segments and all
      current photos/text survive, existing destinations remain connected, retired
      meshes do not refill colour sampling, and continuation waits for a successful save.

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
