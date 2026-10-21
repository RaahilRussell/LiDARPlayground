# Camera, LiDAR, and computer-vision regression repair

The original sensor and vision tools remained in the source, but the mapping
interface made them hard to find. More seriously, shared camera and perception
lifetimes became coupled to map saving and screen changes. The earlier algorithm
tests did not exercise those user flows.

## Repairs

- Camera, LiDAR, AI Vision, Maps, and Assist are direct app destinations. Camera
  is the initial view. Every existing sensor and AI tool remains reachable.
- Map-saving failures stop automatic save retries and show a retry action; they
  must not pause the shared camera, raw depth, or computer vision. A failed final
  segment checkpoint retains its data while live reconstruction recovers.
- Changing screens and handing spoken guidance to a route must not silently
  stop another feature's vision or depth processing. Shared consumers need
  explicit ownership, independent of which screen disappeared most recently.
- Camera-only inference can use a fresh current image while saved-world
  recognition is pending. World-coordinate fusion and navigation still require
  an aligned, normally tracked frame.
- The current AR frame can advance ahead of the main-queue delegate. Freshness
  checks allow that case while rejecting frames from before a reset, old frames,
  and unlocalized world positions.
- Depth display and its touch probe share the same aspect-fit rectangle. Depth,
  point-cloud, and mesh displays clear stale readings on pause/reset and discard
  late background results from a previous session.

## Verification

The repair adds regression coverage for the identified lifecycle and display
failures, plus a simulator UI smoke test that opens the app's destinations and
the original tools. The macOS workflow runs these with the existing mapping,
storage, OCR, color, navigation, and perception tests. Current build/test results
are linked in the pull request; the earlier 123-test result predates this repair.

Physical verification remains necessary for camera output, actual LiDAR depth,
model overlays, relocalization, and sustained concurrent mapping/OCR/vision.
On an iPhone, check transitions in both directions between Live AI, Fused,
Maps, and Assist; pause/resume; a failed save followed by Retry Saving; and a
depth-probe tap near each edge of the displayed image.
