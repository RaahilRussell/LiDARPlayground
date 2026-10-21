# Device validation checklist — mapping and perception

The local Windows authoring environment cannot run Xcode or an iOS Simulator.
GitHub Actions on macOS can build the app and run simulator tests; those CI
results are recorded below. Physical checks still require a LiDAR iPhone/iPad
and, for profiling/installing, a Mac with Xcode 26.5. This is a prototype:
simulator results do not establish navigation safety.

## Camera, LiDAR, and vision regression repair

The subsequent repair restores direct access to the original tools and fixes
shared sensor/processing shutdowns. Its changes and additional UI/lifecycle
coverage are described in [REGRESSION_REPAIR.md](REGRESSION_REPAIR.md); current
build and UI-test results are recorded in the pull request. The 123-test result
below is historical evidence for the earlier feature implementation, not for
this later repair.

- [ ] Interrupt camera delivery while mapping and Assist are active. Verify the
      recovery banner appears, retries are bounded, the current place remains
      selected, and fresh data/alerts resume without restarting Assist. After
      automatic retry exhaustion, Retry Sensing must retry the same world.
- [ ] Save Last Checkpoint during camera loss and while explicitly paused.
      Reopen it offline and compare surfaces, colors, photos, paths, and text
      with the displayed checkpoint time. Saving must not restart a paused
      camera or claim later observations. A new map must not reuse the old
      checkpoint. Verify a failed disk write keeps the checkpoint retryable.
- [ ] Let haptics idle long enough for automatic engine shutdown, then approach
      an observed obstacle. Repeat after a phone call; verify haptics and spoken
      alerts recover, and sensor-unavailable/recovered announcements do not spam.
- [ ] Rotate between portrait and both landscape orientations in Live AI and
      Fused. Boxes and masks must share the displayed camera crop. Confirm the
      LiDAR distance still corresponds to the same detected object.

## Automatic mapping, color, navigation, and OCR follow-up

This follow-up adds continuous foreground checkpoints, color/keyframe capture,
visited-path navigation, and local OCR/signage in [PR #3](https://github.com/RaahilRussell/LiDARPlayground/pull/3).
Code head `9b0c1a235e523d324e705ca558880e7b8822c46d` passed its unsigned iPhone
build and **123 tests in 14 suites in 6.388 seconds** in
[GitHub macOS run 39555636456](https://github.com/RaahilRussell/LiDARPlayground/actions/runs/39555636456)
on 2026-10-21. The log confirms `BUILD SUCCEEDED` and `TEST SUCCEEDED`, including
the synthetic-image Vision OCR integration test. The earlier results below
remain evidence for their named commits only. These build and simulator results
do not establish physical sensor behavior. See
[AUTOMATIC_MAPPING_ARCHITECTURE.md](AUTOMATIC_MAPPING_ARCHITECTURE.md) for the
implemented lifecycle, segment, route, and image-evidence boundaries.

The successful log retains actor-isolation warnings in older `DepthRefinement`
and `PointCloudGenerator` helpers, `UIWindowScene.interfaceOrientation`
deprecation warnings, and a redundant nonoptional `#require` warning in the
color tests. It does not establish Swift 6 strict-concurrency compatibility or
a warning-free build.

- [x] The exact follow-up code head above passes the unsigned iPhone build and
      all 123 simulator tests in 14 suites; the run and remaining compiler
      warnings are recorded above.
- [ ] On iPhone 15 Pro Max/iOS 26.5+, launch with an empty library. Without any
      Start or Save tap, verify the camera maps, the first usable map saves,
      and later updates checkpoint about every 20 seconds when tracking permits.
      Confirm the screen remains awake while mapping and normal automatic sleep
      returns on pause/background.
- [ ] Open Camera, every LiDAR and AI Vision tool, Saved Places, an offline
      place, Text & Signs, and Assist.
      Verify automatic capture remains active, no second ARSession/capture
      session starts, and library refresh does not interrupt saving.
- [ ] Pause explicitly, background/foreground and lock/unlock; the camera must
      remain paused until Resume. Repeat while a map is loading or an automatic
      save is pending. An inactive launch/load must not start camera capture.
- [ ] Relaunch in the last saved room and match its reference view. Verify
      restored geometry/labels/text wait for recognition. Relaunch elsewhere:
      after the automatic recognition timeout, a separate new place must start
      while the original remains intact. An explicitly selected revisit must
      remain actionable rather than silently replacing its target.
- [ ] Revisit another place while a ready scan has new data. Verify the current
      scan checkpoints first; force a write failure and verify revisit is
      aborted. With tracking unavailable, verify the UI explains the unsaved
      remainder that will be replaced before switching.
- [ ] Force each storage-segment threshold in a debug build: mesh usage, photos,
      and text evidence. Verify reconstruction/photo/text intake briefly freezes,
      while camera/IMU/depth and path recording continue. After the commit, only
      reconstruction resets: origin, labels, full graph and active route must
      survive. Old mesh anchors must not leak into the new file or color cache.
      Separately fill the navigation graph; only new path recording should stop.
      Pause/background during commit; completion must not unexpectedly restart
      the camera. Force disk failure and verify the final immutable capture and
      last durable revision remain available for retry, while camera, depth,
      live mesh and CV remain usable. Retry Saving must preserve surfaces seen
      after the failure; photo/text intake resumes after the segment commits.
- [ ] Scan colored walls and small objects from multiple angles. Compare saved
      colors with the real surfaces; an object in front of a wall must not paint
      its color onto the wall. Confirm unobserved/low-confidence vertices remain
      uncolored. Revisit and save again; prior valid colors/photos must persist.
- [ ] Inspect keyframes in portrait and both landscape orientations. Check
      image dimensions, calibrated projection, gallery ordering, and capture
      times. Old uncolored archives must still open, and malformed photo/color
      payloads must fail without corrupting the previous saved revision.
- [ ] Walk a connected room/corridor path and label several destinations. Follow
      turns/distance to each label and Return to Start, both before the first
      save and after a saved-place revisit. Verify exact arrival behavior near
      bends and that close parallel corridors are never joined through a wall.
- [ ] Lose tracking, leave the path, move between floors, point the camera away,
      obscure forward depth, and place an obstacle on the recorded route. Verify
      directions stop or report uncertainty rather than announcing clearance.
      Test speech mute/Stop and switching between route and Assist guidance.
- [ ] Show printed text and arrows in portrait/landscape, at different distances,
      in low light, and against reflective surfaces. Check about 1 OCR update per
      second without accumulating workers. Verify text and arrow boxes align
      with their own image, and no-depth text has no invented world position.
- [ ] Show identical words on distinct signs, return to a previously seen sign,
      and rotate the phone without moving. Verify deduplication preserves the
      physical distinction while repeated sightings update the existing mark.
      Reset/revisit while OCR is running; old results must not enter the new map.
- [ ] Force-quit/relaunch, then inspect saved text/sign evidence, photo gallery,
      labels, and graph paths offline. Verify arrows remain image-relative
      observations and never create a walking route or inferred floor change.
- [ ] Delete the active saved file. Verify mapping pauses and explains how
      Resume saves the retained scan under a new entry, rather than immediately
      recreating the deleted place. Delete an inactive entry without stopping
      the current mapping session.
- [ ] Profile 30 minutes of mapping with OCR/color/path recording and several
      saves. Record device temperature, memory peak during serialization, battery
      use, frame cadence, and recovery after a phone call. No physical-device
      performance or navigation-safety acceptance is claimed until these pass.

## Prior saved-place implementation: validation status

This section preserves evidence for the earlier saved-place implementation.
Its 77-test result and references to its final code head are historical; they
do not describe the automatic mapping/color/navigation/OCR follow-up above.

The mapping change was authored on Windows, where Swift syntax parsing and
repository consistency checks were run. Apple SDK compilation and Swift Testing
were then run separately in GitHub's macOS CI. Neither the Windows checks nor
the simulator tests validate physical sensor behavior. The historical setup
record at the end still describes commit `942abeb`, not this change.

`.github/workflows/ios.yml` uses a shared `test` scheme on macOS 26 with Xcode 26.5.
It builds the unsigned iPhone app, runs `testTests` on an iOS 26.5 iPhone Simulator,
and uploads logs/results. It preserves the iOS 26.5 deployment requirement and
signing settings. A successful simulator run validates algorithms and storage,
not LiDAR capture, SLAM accuracy, or relocalization.

New deterministic suites cover binary geometry round trips, finite coordinates,
triangle bounds, duplicate mesh identifiers, aggregate/trail limits, invalid map
names/counts, save/reopen/rename/delete, failed replacement preserving the last
saved map, corrupt/incomplete storage, map extension merging, stale timestamps,
confidence-gated camera-to-world fusion, missing-confidence diagnostic filters,
future archive versions, and symbolic-link storage rejection.

### Prior implementation GitHub macOS CI results (2026-10-21)

- Initial mapping head `291d0fea`: unsigned iPhone build succeeded; **69 tests in
  8 suites passed**, with `TEST SUCCEEDED` in
  [run 39549322369](https://github.com/RaahilRussell/LiDARPlayground/actions/runs/39549322369).
- Final code head `77644c22d337d9df36ab4da14a268d2e8cbe4165`: unsigned iPhone build
  succeeded and **77 tests in 10 suites passed** in
  [run 39550314472](https://github.com/RaahilRussell/LiDARPlayground/actions/runs/39550314472).
  The completed run reports both `BUILD SUCCEEDED` and `TEST SUCCEEDED`, including
  the storage recovery and diagnostic confidence regressions.
- The final build log reports existing actor-isolation warnings in older
  `DepthRefinement` / `PointCloudGenerator` helpers and a deprecation warning for
  `UIWindowScene.interfaceOrientation`. A successful build is not a claim of
  Swift 6 strict-concurrency compatibility or a warning-free build.

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

## Prior saved-place implementation build and unit tests (Mac)

- [x] `xcodebuild … -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build` succeeds for final code head `77644c22d337d9df36ab4da14a268d2e8cbe4165` in GitHub macOS CI (command in `CLAUDE.md`).
- [x] The verified unsigned build completed without compiler errors. Existing isolation/deprecation warnings remain as described above.
- [x] `testTests` passes for the final code head on an iOS 26.5 Simulator: 77 tests in 10 suites (Product ▸ Test, or
      `xcodebuild test -project test.xcodeproj -scheme test -destination 'platform=iOS Simulator,name=<device>'`).
      Existing suites plus saved places, perception freshness, diagnostic confidence, and storage recovery are included.
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
- [ ] Start a three-second recording, then pause, reset, or revisit another map.
      The recording must abort without exporting mixed-coordinate or stale data.
      A later recording without depth must not reuse an earlier depth/cloud export.
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
