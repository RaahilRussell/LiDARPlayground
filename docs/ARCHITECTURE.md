# Wearer Mode architecture

Wearer Mode is the part of the app a blind user runs. Everything else (Sensors tabs,
Live AI, Depth Lab, Fusion, Bench, Inspector) is developer tooling around it.

This is a prototype. Nothing here has been validated with blind users or on a
device as of this change. See "Validation status" at the end.

## What was wrong before

Two bugs in geometry and one in structure. The first two are reproduced
numerically in `docs/evidence/`.

**1. Left/right and distance were read from the wrong camera axis.**
ARKit camera space is fixed to the sensor: camera +x runs along the device's long
edge in every orientation. The app runs in portrait (YOLO input is
`.oriented(.right)` and fusion maps portrait boxes into the depth buffer), so camera
x is *vertical* and camera y is the user's left/right. `WorldHazardMap` computed
bearing as `atan2(local.x, -local.z)` and distance as `hypot(local.x, local.z)`, so
the lateral offset (local.y) was ignored entirely. A wall 1 m to the user's right
came out as **0.05 m, dead ahead, CRITICAL** (`docs/evidence/hazard_axes.py`). With
the phone pitched down 30°, a pole straight ahead was reported "right" and outside
the corridor. `SpatialAlgorithms.occupancy` (via `SpatialAlgorithmsEngine`) and
`SpatialFusionEngine.azimuthDegrees` had the same mix-up. The `inPath` and
"walking alongside" rules added in the last commit were patches over this symptom.

**2. Obstacles were modelled as spheres sized by their bounding box.**
A LiDAR cluster's radius was half its bounding-box diagonal and distance was
`range − radius`. A 3.4 m stretch of hallway wall 1.16 m from the user became a 2 m
sphere at 0.51 m. If RANSAC missed the floor, floor and walls merged into one blob
at 0.11 m (`docs/evidence/cluster_radius.py`). Merged hazards' radii only grew.

**3. Five polling loops in series.** Spatial (200 ms), hazard map (200 ms), proximity
driver (150 ms) and guidance (400 ms) each slept independently. Waiting on each
stage adds ~0.28 s on average (0.55 s worst case) before the vibration and ~0.48 s
(0.95 s worst case) before speech. At 1.4 m/s the worst case is 1.3 m walked blind. Three separate definitions of
"in path" (±30° bearing, ±25° region, 0.5 m corridor) disagreed with each other.

## The pipeline now

One loop in `NavigationEngine`, one tick per new LiDAR frame at ~10 Hz:

```
ARFrame (raw sceneDepth, confidence ≥ medium, stride 4)
  → DepthSampler.worldPoints        world points via CameraProjection
  → FloorEstimator.floorY           lowest level plane 0.6–2.2 m below the phone
  → ObstacleMap.integrate           10 cm world grid: floor / obstacle(bottom, top)
  → PathScanner.assess              nearest obstacle in the corridor + free runs per bearing
  → AlertPolicy.decide              level, haptic cue, utterance
  → HapticCoordinator / SpeechCoordinator
```

Everything from `UserFrame` to `AlertPolicy` is pure, `nonisolated`, and covered by
`testTests/NavigationTests.swift`. `NavigationEngine` only moves data and owns timing.

| File | Responsibility |
|---|---|
| `Core/Navigation/UserFrame.swift` | Gravity-aligned "ahead / right" on the floor plane from the camera pose. The only place that interprets camera orientation. |
| `Core/Navigation/DepthGeometry.swift` | Depth pixel → world point, "is this point in view now", floor height. |
| `Core/Navigation/ObstacleMap.swift` | The map. World-anchored, so things that left the camera view are remembered. |
| `Core/Navigation/PathScanner.swift` | Reads the map from the user's heading. |
| `Core/Navigation/AlertPolicy.swift` | Every alert decision. The one file to change after user testing. |
| `Core/Navigation/SurroundingsDescriber.swift` | The on-demand spoken summary. |
| `Core/Navigation/NavigationEngine.swift` | Runtime loop, outputs, screen-awake, object labels. |
| `Views/Wearer/WearerModeView.swift` | Blind-user UI. |
| `Views/AI/NavigationMapView.swift` | "Map" developer tab: live top-down map, corridor, rays, transition log with latency. |

### The map

Cells are 10 cm squares on the floor plane, keyed in world coordinates.

- A cell with LiDAR points 10 cm to 2.3 m above the floor is an obstacle with a
  bottom and top height. Its extent only grows while it lives: walking up to a pole
  pushes its base out of the frame, and without this the pole turned into a false
  "overhead STOP" at 0.8 m (checked by simulation against the alternative).
- A cell with only floor points is observed free. A cell nobody has seen does not
  exist: unknown is never free.
- A cell in view with no fresh points is forgotten after 0.8 s (the thing moved).
  Out of view it is remembered for 20 s, then dropped. Cells more than 7 m away are
  dropped. The whole map resets when tracking is limited.

### Alert decisions (AlertPolicy)

| Rule | Why |
|---|---|
| Only the walking corridor (±0.35 m) alerts. Walls beside you never do. | Unnecessary alerts slowed augmented-cane users without reducing collisions [3]; tactile displays need filter rules against overload [4]. |
| Obstacles are *ground* (bottom edge ≤ 0.686 m) or *overhead* (above). | 27 in / 0.686 m is the ADA cane-sweep line; 80 in / 2.03 m is headroom [1]. Head-level obstacles are the hazard the cane misses [2]. |
| Cane-user profile (default): ground obstacles cap at NOTICE, no speech. | The cane already finds them. |
| Levels by distance (3.0 / 1.8 / 1.0 m) and, while walking, time-to-contact (4 / 2.5 / 1.2 s). Step down only after 0.6 s. | Faster walking warns earlier; hold stops flicker. |
| Haptics carry the continuous signal: 3 levels, cadence 1.2 / 0.5 / 0.18 s, strength rising. Tap = ground, double tap = overhead, long soft buzz = can't see. | Reviews report blind users favour vibration in noise and dislike audio that masks environmental sound, though findings conflict and spatial audio wins on precision in some studies [5][6]; few coding parameters [4]. One actuator means no left/right, so texture encodes height only. |
| Standing still: one pulse when the level rises, no repeats. | Constant buzzing at a wall you are waiting beside is noise. |
| Speech only for: overhanging obstacle at WARNING/STOP (with height: waist / chest / head), any STOP, "clearer to your left/right" when ≥ 2 m of *observed* floor exists, sensing lost/regained. Never "clear". Same obstacle re-announced only if it gets more urgent. | Speech is precise but slow and masks the environment. |
| Sensing lost (no depth, tracking limited, no floor, phone facing floor) for 1 s: spoken once, buzz every 4 s, never reported as clear. | Silence must never mean safe. |
| Object names (YOLO) only change wording. | A label is not geometry. |

### Tuning knobs, in order of expected impact

1. `PathScannerConfig.corridorHalfWidth` (0.35 m). Too narrow misses shoulder hits;
   too wide alerts on door frames (a 32 in ADA door leaves ~0.4 m each side).
2. `AlertThresholds` distances and TTC tiers.
3. `ObstacleMapConfig.visibleForgetSeconds` / `memorySeconds`.
4. `HapticCue` intensities and `HapticCue.interval(for:)`.

## Recommended next changes (bigger than this MVP)

1. **Test with blind users before tuning further.** Use the Haptics tab's "Wearer
   Mode vibration language" panel to teach and rate the cues, then short walks with
   the Map tab recording transitions. Every threshold above is a reasoned default,
   not a measured one.
2. **Drop-offs and stairs down.** The map knows where floor was seen; a missing or
   lower floor ahead is the next hazard class. Not detected today, and the UI says so.
3. **Wearable mount.** A chest or lanyard mount keeps the heading stable and the floor
   in view. Hand-held sway adds false speed and pitch changes.
4. **Use ARKit scene mesh for the map** (`ARMeshAnchor`, already enabled in the session
   configuration). It is denser and temporally fused by ARKit; the per-frame grid
   could become a mesh slice at body height.
5. **Background/lock behaviour.** iOS stops the camera when the app leaves the
   foreground; guidance keeps the screen awake but cannot run locked. A Live Activity
   or guided-access setup is worth evaluating.
6. **Retire the developer-only proximity state machine** (`ProximityStateMachine`,
   `DemoScenario`) once the Inspector demo is no longer needed, so only one alert
   logic remains in the codebase.
7. **A wrist or chest haptic band** would allow left/right vibration, which one
   phone actuator cannot.

## Validation status

- Done in cloud (no Xcode, no Swift toolchain): the new core logic was ported line
  by line to Python and run on ray-cast synthetic LiDAR frames from a portrait phone
  at 1.35 m, pitched 15° down. Results: hallway with walls 1 m either side → CLEAR
  throughout (old code: CRITICAL); walking past a box 0.75 m to the side → CLEAR;
  pole 4 m ahead → stays *ground* to contact, NOTICE for cane users, WARNING at
  2.8 m and STOP at 1.4 m otherwise; sign at 1.5–1.9 m → "Head height obstacle ahead,
  3 meters", then STOP at 1.4 m; table top at 0.70–0.76 m → waist-height warnings;
  obstacle that leaves → CLEAR 1.4 s later.
- **Not done:** compiling, unit tests, any on-device run. See
  `docs/DEVICE_VALIDATION.md`.

## Sources

1. U.S. Access Board, Guide to the ADA Standards, Chapter 3: Protruding Objects. https://www.access-board.gov/ada/guides/chapter-3-protruding-objects/
2. Manduchi & Kurniawan, "Watch Your Head, Mind Your Step: Mobility-Related Accidents Experienced by People with Visual Impairment", UCSC-SOE-10-24. https://tr.soe.ucsc.edu/research/technical-reports/UCSC-SOE-10-24
3. "The cost of knowing: How obstacle alerts reduce walking speeds of augmented white cane users", Aalborg University. https://vbn.aau.dk/en/publications/the-cost-of-knowing-how-obstacle-alerts-reduce-walking-speeds-of-
4. van Erp et al., tactile obstacle display recommendations, Frontiers in ICT 2017. https://www.frontiersin.org/journals/ict/articles/10.3389/fict.2017.00023/pdf
5. "How Can Haptic Feedback Assist People with Blind and Low Vision (BLV): A Systematic Literature Review", ACM 2025. https://dl.acm.org/doi/10.1145/3711931
6. Tang & Huang, "Navigation Assistance Via Haptic Technology for Blind or Low-Vision Users: A Scoping Review", 2025. https://journals.sagepub.com/doi/10.1177/10711813251360706
