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

## Wearer Mode navigation (📱)

Hold the phone upright in portrait at chest height (or on a lanyard), screen facing you.
Open Developer ▸ AI Perception ▸ Map to watch the map while a sighted helper walks.

- [ ] `NavigationTests` pass in the Simulator (axes, floor, map, path scan, alert policy).
- [ ] Start guidance: "Guidance started" is spoken; screen does not auto-lock while running.
- [ ] Map tab: green floor cells appear ahead within ~2 s; "Phone height" reads 1.2–1.5 m.
- [ ] Hallway ~2 m wide, walk the middle: level stays CLEAR, no vibration (old build: CRITICAL).
- [ ] Walk past a chair 0.8 m to the side: no alert. Map shows it beside the corridor.
- [ ] Walk at a pole or door edge: tap pulses; with "I use a long cane" ON it never goes above NOTICE and never speaks; OFF → WARNING then STOP with speech.
- [ ] Overhanging object (open cabinet door, sign, branch, table edge) in the path: double taps, "Head/Chest/Waist height obstacle ahead…", then "Stop…" around 1–1.4 m at walking pace.
- [ ] Walk up to a tall pole until it leaves the bottom of the frame: it stays amber (ground), never turns red.
- [ ] Turn 90° after passing an obstacle: it stays on the map (out of view), then disappears ~20 s later.
- [ ] Someone steps into the path then leaves: alert clears within ~1.5 s.
- [ ] Stand still facing an obstacle: one pulse when the level rises, then silence.
- [ ] Cover the LiDAR / point at the ceiling / point at the floor: after ~1 s the right warning is spoken once and a soft buzz repeats every 4 s; uncovering says "Sensing again."
- [ ] Describe Surroundings: says ahead / left / right; unmapped directions are called "not mapped yet", never "open".
- [ ] Map tab "Capture→decision" stays under ~150 ms; "Compute" under ~20 ms; thermal state over 10 minutes.
- [ ] Haptics tab ▸ Wearer Mode vibration language: the six cues and the buzz are distinguishable without looking.

## Regression (📱)

- [ ] Sensor tabs (Camera, Depth, Point Cloud, 3D Mesh, Data) behave as before.
- [ ] Live AI, Depth Lab, Fusion, Haptics tabs behave as before.
- [ ] Fusion tab: an object on the right of the screen shows a positive azimuth (was vertical angle before).
- [ ] Inspector "Run spatial pipeline": LEFT/RIGHT occupancy follows left/right of the screen, not top/bottom.
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
