# Device validation checklist — mapping and perception

Cloud sessions cannot build, run the Simulator, or touch hardware. Everything
below needs a Mac with Xcode 26.5 and, where marked 📱, a LiDAR iPhone/iPad.
This is a prototype: none of these checks make it a navigation aid.

## New mapping changes: validation status

The mapping change was authored on Windows. Swift syntax parsing and repository
consistency checks are available there; Xcode compilation, Swift Testing execution,
and physical sensor behavior are **not** validated by those checks. The historical
checked items below describe commit `942abeb`, not this change.

`.github/workflows/ios.yml` uses a shared `test` scheme on macOS 26 with Xcode 26.5.
It builds the unsigned iPhone app, runs `testTests` on an iOS 26.5 iPhone Simulator,
and uploads logs/results. It preserves the iOS 26.5 deployment requirement and
signing settings. A successful simulator run validates algorithms and storage,
not LiDAR capture, SLAM accuracy, or relocalization.

New deterministic suites cover binary geometry round trips, finite coordinates,
triangle bounds, duplicate mesh identifiers, aggregate/trail limits, invalid map
names/counts, save/reopen/rename/delete, failed replacement preserving the last
saved map, corrupt/incomplete storage, map extension merging, stale timestamps,
and confidence-gated camera-to-world fusion.

## Live mapping and saved places (iPhone 15 Pro Max)

- [ ] Install on an iPhone 15 Pro Max running iOS 26.5 or later. Allow camera access.
      Deny access once and verify the app displays an actionable error, then
      restore access in Settings and restart the session.
- [ ] Start a new map. Slowly scan a well-lit, textured room from several angles.
      Verify live surfaces/mesh counts grow, the camera trail follows motion,
      and world mapping progresses from initializing/limited toward mapped.
- [ ] Try Save immediately, while paused, during an interruption, and with
      insufficient mapping. Verify a clear readiness explanation and no empty
      library entry. Save a named room after readiness is reached.
- [ ] Open the saved place in the app. Orbit/zoom its offline 3D mesh and trail.
      The preview must work without starting the camera or being in that room.
      Force-quit/relaunch; confirm the same geometry and name remain available.
- [ ] Rename a saved place, including blank/whitespace and >80-character input.
      Invalid names must be rejected; valid names must persist after relaunch.
- [ ] Return physically to the saved room, choose revisit/continue, and aim near
      the reference view. The UI must say relocalizing until ARKit recognizes
      the surroundings; saved geometry must not masquerade as aligned live data.
- [ ] After recognition, confirm surfaces align with the actual room. Walk into
      another part, extend the scan, and save again. Previously mapped surfaces
      outside the current view must remain; a repeat save updates the same place.
- [ ] Attempt revisit in a different room and with the camera covered. Verify
      unresolved relocalization is clearly indicated and saving is unavailable.
      Cancel/start a new map; verify no old geometry or hazards appear at the new
      origin and the previous saved place remains intact.
- [ ] Pause while relocalizing, resume, background/foreground, and lock/unlock.
      Confirm user pause is respected and interruption recovery does not silently
      discard the saved world map. Reset while paused must not start the camera.
- [ ] Start a save/load and immediately start a new map. A late completion must
      not reactivate the previous place or overwrite the new world coordinates.
- [ ] Delete a saved place and relaunch. Confirm it disappears. Corrupt a test
      map copy or remove its geometry file: opening must report an error, and
      the unreadable entry must remain deletable without crashing the library.
- [ ] Exercise low disk space and locked-device file protection using a test
      device. Failed saves must retain the previous saved revision.
- [ ] Scan for 10 minutes and revisit/save repeatedly. Inspect memory, frame
      rate and temperature in Xcode. Verify bounded geometry/trail storage, no
      accumulating retained ARFrames, and a clear message when map limits apply.

## Perception regressions during mapping (physical device)

- [ ] Switch/reset/relocalize maps while AI and proximity are active. No old-world
      hazards may appear in the new origin, including after slow inference ends.
- [ ] Pause the session, cover the camera, or background the app. Fresh sensing
      must expire; previous objects must not be refreshed forever by a polling
      loop. Guidance must not announce an unobserved direction as clear.
- [ ] Turn off haptics, stop/start guidance, and verify the preference stays off.
- [ ] Compare moving-camera object overlays with depth fusion. Results must use
      the RGB frame's matching depth and pose; stale results are discarded.
- [ ] Check reflective/dark surfaces and missing/low-confidence depth. These
      must remain uncertain and must not become confident world hazards.
- [ ] Observe free space only to one side with forward depth unavailable. The
      forward path must remain uncertain rather than inheriting the side's clear
      state. Offline saved geometry must never drive live obstacle guidance.

## Build and unit tests (Mac)

- [ ] `xcodebuild … -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build` succeeds for the mapping branch (command in `CLAUDE.md`).
- [ ] No new Swift concurrency errors; review any new isolation warnings.
- [ ] `testTests` passes for the mapping branch on an iOS 26.5 Simulator (Product ▸ Test, or
      `xcodebuild test -project test.xcodeproj -scheme test -destination 'platform=iOS Simulator,name=<device>'`).
      Suites: Depth refinement, Spatial algorithms, Proximity, Benchmark statistics, Demo mode, Inspector models.
- [ ] Simulator: Bench shows "Needs a physical ARKit device"; Inspector demo mode runs; no crash.

## Benchmarks tab (📱)

- [ ] "Compare n/s/m" runs YOLO26n → s → m, ~20 s each, phase badge goes LOADING → WARM-UP → MEASURING.
- [ ] Per-model results populate; inference p50 ordering is plausible (n ≤ s ≤ m) for the scene.
- [ ] Frame-time graph stays bounded (≤ 360 points), warm-up points grey, dashed target line visible.
- [ ] Missed camera frames ≈ 0 for nano at rest; rises plausibly under load. Skipped slots > 0 for medium.
- [ ] Thermal start/end and colour reflect Settings ▸ Battery / device warmth over repeated runs.
- [ ] Cancel mid-run → PARTIAL row, then Live AI shows the original model, rate, compute option and on/off state.
- [ ] Start a run, then background the app / switch tab / lock the screen → run cancels with that reason and config is restored.
- [ ] Pause the AR session (Camera tab) then press Run → refuses with a clear message instead of restarting the session.
- [ ] Memory stays flat across several runs (Xcode memory gauge); no growth from frames or graph points.
- [ ] Compute picker: "CPU only" vs other options produce different timings (the pinned SDK maps every non-CPU option to CPU + Neural Engine).

## Inspector tab (📱)

- [ ] Frame metadata updates ~4 Hz: RGB 1920×1440 (or format in use) `420f`, depth 256×192, tracking, intrinsics, position.
- [ ] RGB / depth / confidence previews match the scene and orientation; magenta = invalid depth.
- [ ] "Run YOLO model" shows labels/boxes/timings; turning it off stops inference. If the model was already on before opening Inspector, leaving the tab leaves it on.
- [ ] "Run spatial + proximity" logs occupancy/floor/proximity transitions; history caps at 100.
- [ ] Latency breakdown shows "—" for stages not running; values are plausible when running.
- [ ] Demo mode: label DEMO everywhere, live previews stop, sequence repeats identically after Reset.
- [ ] Demo: no vibration unless "Play haptics for demo transitions" is on; with it on, transitions vibrate.
- [ ] Switching back to Live stops the demo and resumes live polling.

## Regression (📱)

- [ ] Sensor tabs (Camera, Depth, Point Cloud, 3D Mesh, Data) behave as before.
- [ ] Live AI, Depth Lab, Fusion, Haptics tabs behave as before; Haptic Lab simulated proximity still works.
- [ ] Live AI rate slider now achieves close to the requested Hz (loop paces start-to-start).
- [ ] Background/foreground resumes the AR session cleanly.

## Local validation recorded during setup

Validated commit `942abeb` on the Mac using Xcode 26.5:

- Unsigned Debug build for generic iOS: succeeded.
- iPhone 17 Pro Simulator, iOS 26.5: 53 tests passed (58 cases including
  parameterized inputs), zero failures and zero skipped tests.
- Simulator app launch: succeeded; unsupported ARKit state and AI Perception
  screen were visible. Full Bench/Inspector visual interaction remains unchecked
  because desktop coordinate input failed during verification.
- Existing concurrency warnings remain in older sensor/rendering helpers.
  This validation does not assert Swift 6 strict-concurrency compatibility.
- Physical-device benchmarking, LiDAR previews, thermal behavior, and haptic
  output remain unchecked. Do not treat simulator tests as device validation.
