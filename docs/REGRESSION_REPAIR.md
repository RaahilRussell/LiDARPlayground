# Camera, LiDAR, and computer-vision regression repair

The original sensor and vision tools remained in the source, but the mapping
interface made them hard to find. More seriously, shared camera and perception
lifetimes became coupled to map saving and screen changes. The earlier algorithm
tests did not exercise those user flows.

## Repairs

- Camera, LiDAR, AI Vision, Maps, and Assist are direct app destinations. Camera
  is the initial view. Every existing sensor and AI tool remains reachable.
- Storage-write failures pause automatic saving and show a retry action; they
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
- Depth and point-cloud previews limit processing to one worker per view across
  control changes and task restarts, so rapid slider changes cannot accumulate
  detached jobs holding camera buffers. Completed work must match current options.
- The Data screen clears old live readings and distinguishes recorded history
  from the current pose. Sensor recordings use the same fresh-frame gate and
  stop after an explicit pause, even when the camera resumes before the next poll.
- Assist ignores simulated obstacle events from Haptics Lab when speaking about
  live surroundings.
- Camera masks and boxes use the same actual window orientation, ARKit display
  transform, and viewport as the camera. Portrait inference coordinates remain
  unchanged for depth fusion; rendering handles landscape rotation and cropping.

## Intermittent sensor loss, saving, and alerts

The follow-up repair first pulls the current remote branch. Its plan is to keep
the current map origin through sensor recovery, make an already captured map
independent of live frame availability, and recover feedback hardware without
requiring the user to restart Assist.

- A foreground watchdog detects missing camera frames and retries the existing
  session with a bounded retry budget. Explicit Pause and background suspension
  remain authoritative. Recovery must prove the original coordinate origin
  before world mapping or routes resume; it must not silently start a new place.
- Each complete map checkpoint is retained before disk I/O. Save Last Checkpoint
  can write it during a sensor outage or explicit pause. It preserves the exact
  geometry, colors, evidence, and world-map pair and displays the checkpoint time;
  observations after that time are not claimed as saved. New places and storage
  segments cannot borrow another checkpoint. A first scan with no valid
  checkpoint still needs sufficient tracking and surfaces before it can save.
- Missing measurements stop stale obstacle cues while the requested alert loop
  remains active. Fresh camera-relative depth can support nearby warnings while
  world relocalization is pending; world-positioned hazards and routes still
  require localization proof. Haptics restart after idle shutdown/interruption,
  and speech reactivates its audio session for subsequent announcements.
- The UI exposes recovery status and Retry Sensing, and explains which source a
  Save action will use. World-map requests have a timeout so an unresponsive
  camera cannot leave map controls busy indefinitely.
- Temporary capture timeouts retry with backoff. Storage retries refresh cached
  filesystem metadata, and saved obstacle-height evidence survives a failed
  initial write. Archived hazards remain separate from fresh obstacle warnings.

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
depth-probe tap near each edge of the displayed image. Also test camera loss and
recovery while saving, a phone-call interruption, haptics after a long idle gap,
portrait/landscape mask alignment, and Save Last Checkpoint during an outage.
