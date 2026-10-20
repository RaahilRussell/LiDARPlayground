# Device validation checklist — Phases 7–9

Cloud sessions cannot build, run the Simulator, or touch hardware. Everything
below needs a Mac with Xcode 26.5 and, where marked 📱, a LiDAR iPhone/iPad.
This is a prototype: none of these checks make it a navigation aid.

## Build and unit tests (Mac)

- [x] `xcodebuild … -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build` succeeds (command in `CLAUDE.md`).
- [ ] No new Swift concurrency errors; review any new isolation warnings.
- [x] `testTests` passes on an iOS 26.5 Simulator (Product ▸ Test, or
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
