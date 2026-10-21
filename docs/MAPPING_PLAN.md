# SLAM mapping implementation plan

## User outcome

On an iPhone 15 Pro Max, scan an environment while seeing its reconstructed
surfaces, save a named place, browse that place in an interactive 3D viewer after
restarting the app, and relocalize at the original place to continue mapping.

## Architecture decisions

1. Keep `ARSessionManager` as the only owner of one `ARSession`.
   `ARWorldTrackingConfiguration` supplies Apple's visual-inertial tracking
   (camera + IMU); scene reconstruction and scene depth supply LiDAR geometry.
   Do not independently integrate Core Motion into a second pose estimate.
2. Separate localization data from presentation geometry. Securely archive an
   `ARWorldMap` for relocalization and copy mesh vertices/triangle indices into
   a versioned, validated archive for offline viewing. Store the camera trail
   and a reference photo to help the user find the original viewpoint.
3. Put capture/save/restore orchestration in `MappingCoordinator`, persistence
   in an isolated `MapStore`, and rendering in views. The offline viewer uses
   SceneKit without creating another AR session.
4. Save only with normal tracking and sufficient world-map quality. Restore
   with an explicit relocalization state; do not align stored geometry or allow
   mapping saves until tracking has recovered in the saved coordinate system.
   A timeout offers retry/new-map recovery without deleting the saved place.
5. Increment a session generation on coordinate-system changes. Reject stale
   async results and clear world-space perception caches across generations.
6. Bound mesh/archive sizes and trail length. Keep disk I/O outside the main
   actor, retain the last committed revision on failed writes, and show storage
   errors. Saved spatial data stays in the app's local Application Support.

## Implementation sequence

- Inspect existing sensor, mesh, wearer/perception and build flows.
- Implement session lifecycle and persistence in parallel, with explicit APIs.
- Add live mapping, saved places, offline viewing, rename/delete and revisit UI.
- Integrate generation/freshness checks with existing perception pipelines.
- Add regression tests, a shared Xcode scheme, and macOS CI using the existing
  iOS 26.5 deployment target; preserve signing and model assets.
- Review the combined changes, run available static checks, and document the
  Xcode and iPhone checks that require Apple hardware.

## Acceptance checks

- One AR session; unsupported devices can still browse saved geometry.
- A saved place survives app termination and displays without live AR input.
- Relocalization never presents old surfaces as aligned before success.
- Reset, pause, background, failed save, malformed archive and delete are handled.
- Returning to a map does not combine stale perception coordinates with new ones.
- Corrupt or oversized geometry is rejected before rendering.
- On-device checks cover scanning, revisiting, lighting changes, tracking loss,
  thermal pressure, and prolonged operation. This remains a research prototype.

## Platform references

- [Understanding world tracking](https://developer.apple.com/documentation/arkit/understanding-world-tracking)
- [Saving and loading world data](https://developer.apple.com/documentation/arkit/saving-and-loading-world-data)
- [Initial world map](https://developer.apple.com/documentation/arkit/arworldtrackingconfiguration/initialworldmap)

This plan was written before implementation. Local execution is on Windows;
source checks cannot establish that the iOS app builds or that SLAM works on a
physical device. Record those results separately and explicitly.
