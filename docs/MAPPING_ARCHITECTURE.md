# Mapping architecture and review

The shared-session and storage foundations are described here. Foreground
autosave, captured color/photos, continuous recorded routes, and local OCR are
described in [AUTOMATIC_MAPPING_ARCHITECTURE.md](AUTOMATIC_MAPPING_ARCHITECTURE.md).

## Tracking and reconstruction

`ARSessionManager` remains the sole owner of `ARSession`. Apple's world tracking
uses camera imagery and inertial measurements to estimate the phone pose and
map visual features. Enabling `meshWithClassification` (or supported `mesh`)
adds LiDAR scene reconstruction in that coordinate system. Raw/smoothed scene
depth remain available to the existing sensor tools.

This uses Apple's SLAM stack, rather than implementing another estimator or
integrating accelerometer samples independently. ARKit manages sensor timing,
calibration and tracking internally. The app does not claim access to Apple's
internal optimization, loop-closure algorithm, or exact use of LiDAR inside its
pose estimator. The application-level result combines tracked camera/IMU pose
with metric LiDAR surfaces.

## Separation of responsibilities

| Component | Responsibility |
| --- | --- |
| `ARSessionManager` | Sensor capability checks, configuration, lifecycle, tracking quality, session generation, world-map capture/restore |
| `MappingCoordinator` | Save/revisit intent, serialized user operations, generation guards, library state, merge of continued scan surfaces |
| `MapMeshSnapshot` / `SavedMapGeometry` | Copied world-space positions and triangle indices; no retained ARKit frame or Metal buffer |
| `MapStore` | Actor-isolated disk operations, versioned metadata, bounded decoding, atomic revision commits, rename/delete |
| `MappingHomeView` | Live scanning, saved places, progress/errors and relocalization coaching |
| `SavedMapSceneView` | Camera-independent SceneKit viewer with bounded geometry, off-main normals/bounds, orbit/pan/zoom and fit |

`ARWorldMap` is opaque localization state, not the offline presentation format.
The separate mesh archive makes saved surfaces viewable without starting AR,
without camera access, and without being at the original location. The reference
photo provides a viewpoint cue for relocalization. All values use local ARKit
metres, not GPS or a building-wide geographic frame.

## Save and restore correctness

- Save requires a recent accepted frame, normal tracking, nonempty LiDAR
  surfaces, and extending/mapped world-map quality. Geometry is copied before
  asynchronous serialization; the current generation is checked again when
  asynchronous steps finish.
- A place is stored under a UUID directory. Each replacement writes an immutable
  revision, then atomically replaces its manifest. Failed validation or writes
  leave the previous committed revision readable. Old revisions are reclaimed
  only after committing; incomplete initial saves are omitted from the library.
- Metadata, names, vertex/index bounds, finite coordinates, file sizes and map
  identifiers are validated. Corrupt committed manifests remain visible for
  diagnosis/deletion. Geometry uses explicit little-endian binary blocks.
- Revisit installs `initialWorldMap`, resets tracking and scene reconstruction,
  and waits for a new normal-tracking frame containing that archive's unique
  origin anchor. Saved geometry is hidden until the restored coordinate space
  is established. A 30-second notice offers recovery;
  it does not pretend the place has been recognized.
- Pause and foreground resume preserve a pending restore. Reset while paused
  queues reset options without turning the camera back on. New Map deliberately
  starts a new coordinate space. Library browsing leaves automatic foreground
  sensing active; Pause Mapping stops it explicitly.
- Continued saves replace matching mesh identifiers and retain saved chunks
  outside the current view. Explicit ARKit mesh removals during normal tracking
  are recorded separately; reset/relocalization removals are excluded so they
  cannot erase the baseline being restored. Recorded deletions do not reappear
  from the saved baseline. Saved and live trails are combined without repeatedly
  appending the same current-session trail.

## Existing functionality reviewed and repaired

The audit covered the single-session boundary, mesh handling, depth/vision
fusion, spatial and hazard caches, wearer feedback, persistence, and build/test
configuration. The new coordinate-space transitions exposed existing problems:

- Sensor snapshots could remain available while paused or interrupted. Providers
  now reject stopped, stale, relocalizing and previous-generation input.
- Sensor recordings could mix poses across a reset, repeat a paused frame, or
  retain depth from an earlier capture when new depth was missing. Recording now
  clears every payload, requires fresh normal-tracking frames from one generation,
  deduplicates timestamps, and discards incomplete data after interruption or
  cancellation. These session transitions require the on-device checks.
- World-space detections and clusters could survive an origin reset. Generation
  guards clear these caches and reject detached work from an older scan.
- Object boxes could be fused with a newer frame's depth/pose. Fusion now uses
  the exact source snapshot paired with the inference result, retaining at most
  one completed inference snapshot.
- Low-confidence or missing-confidence depth could produce confident object
  geometry. Only matched medium/high-confidence samples contribute to fusion.
- Diagnostic depth heatmaps, aggregate depth statistics and point clouds honor
  their configured confidence filters. Missing confidence is excluded when a
  filter is enabled. Raw distance probes (including the center-depth readout),
  unfiltered depth views and confidence visualizations remain raw diagnostic
  data; they do not establish confident world geometry or observed free space.
- Reprocessing unchanged observations refreshed hazard age forever. Hazard
  updates now use capture timestamps and deduplicate each source frame.
- Missing observations could be described as clear; speech now describes the
  lack of confirmation. Forward clear feedback requires forward observed-free
  depth. Starting guidance preserves the user's haptic preference.
- Live proximity thresholds now use the actual nearest depth, including samples
  labelled observed-free by the occupancy layer. A 1.5-metre obstacle therefore
  still triggers a configured 2-metre caution threshold. Demo and live selection
  share the same policy, while unknown forward space remains uncertain.
- The project still advertised visionOS targets despite using iOS-only world
  tracking. Those destinations were removed; deployment and signing were kept.
- The live mesh renderer omitted ARKit's normals and copied unused index-buffer
  capacity. It now includes normals for lighting and copies only used indices.

## Performance and limits

The app targets room-scale scans with automatic and explicit checkpoints.
Per-segment archive caps are 2,000 mesh
anchors, 750,000 vertices, 1,500,000 triangles, 6,000 trail points, 64 MiB of
world-map data, 256 MiB of serialized geometry and 5 MiB of reference image data.
The automatic coordinator rotates reconstruction/photo/text storage segments
before their limits while preserving the AR tracking world and navigation graph.
The companion architecture document describes the additional payload bounds.
The limits reject an oversized save with an explanation; they do not silently
drop triangles. Disk work and offline normal generation run outside the main
actor. Native scene updates and ARKit buffer copying remain on the session actor.
The live overlay refreshes at approximately 2.5 Hz while ARKit tracks at its own
camera rate. Profile capture latency and sustained memory/thermal use on device.

SceneKit is retained to fit the existing rendering architecture. A future move
to RealityKit can preserve the map store and coordinator boundaries. The saved
geometry now includes observed vertex colors and calibrated keyframe photos;
it does not contain a baked texture atlas. The reference image remains a
localization aid. Historical surfaces may represent objects that have moved. They are not
fed into the live hazard system as current obstacles or certified free space.
If ARKit reconstructs the same surface with a new anchor identifier on a later
visit, historical and new chunks can overlap. This version does not globally
remesh or optimize those chunks; the archive caps still apply.

ARKit relocalization depends on visual overlap, lighting and scene stability.
There is no guarantee of recognition, globally consistent multi-room mapping,
cross-device map compatibility, successful automatic place recognition, or
navigation safety. Recognition and recorded-route guidance need measured
physical-device validation.

## Verification

Regression tests cover binary geometry round trips, invalid indices/nonfinite
coordinates, archive limits and count mismatches, persistence across store
instances, rename/delete, failed replacement preservation, corruption, timestamp
freshness and depth-confidence fusion. The shared scheme includes existing
algorithm tests. CI builds the iPhone target without signing and runs tests on
an iOS 26.5 simulator.

Windows source/syntax checks do not establish Apple SDK type correctness. CI
results and physical iPhone results must be reported separately. The full
hardware acceptance checklist is in `DEVICE_VALIDATION.md`.

## Primary references

- [Apple: Understanding world tracking](https://developer.apple.com/documentation/arkit/understanding-world-tracking)
- [Apple: Saving and loading world data](https://developer.apple.com/documentation/arkit/saving-and-loading-world-data)
- [Apple: ARWorldMap](https://developer.apple.com/documentation/arkit/arworldmap)
- [Apple: Initial world map](https://developer.apple.com/documentation/arkit/arworldtrackingconfiguration/initialworldmap)
