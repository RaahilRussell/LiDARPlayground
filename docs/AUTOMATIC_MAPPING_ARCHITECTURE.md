# Automatic mapping, color, paths, and text

This extends [the saved-place architecture](MAPPING_ARCHITECTURE.md). The app
still has one `ARSession`, owned by `ARSessionManager`. ARKit supplies visual
inertial tracking, depth, reconstruction, and saved-world relocalization. The app
does not implement or expose a separate SLAM optimizer.

## Foreground lifecycle and persistence

`MappingCoordinator` owns automatic work independently of the selected screen.
App activation starts it once; opening Saved Places, viewing an offline map, or
switching to another mode does not pause the camera. The normal screen idle
timer is disabled during foreground mapping and restored on pause/background.
An explicit pause persists through scene changes. iOS background/lock suspends
the session and its consumers; continuous background camera capture is not part
of this implementation.

On launch, the newest saved archive is tried first. Restored surfaces, navigation,
and text wait for a fresh normal frame containing the archive's origin anchor.
After 30 seconds of unsuccessful **automatic launch** recognition, the old file
is preserved and a new place starts with a different ID and coordinate origin.
An explicitly selected revisit keeps waiting and offers Cancel Revisit. A load
that finishes while inactive is deferred until foreground activation. An
explicit revisit checkpoints a different running place first when quality
permits; a failed checkpoint aborts that switch.

The first valid scan is saved automatically. Subsequent checkpoints are due
every 20 seconds; transient tracking failures use a five-second retry backoff.
Saving requires normal tracking, extending/mapped world-map quality, a fresh
accepted frame, and nonempty LiDAR surfaces. Save/load/delete/rename operations
are serialized. Operation tokens and session generations reject stale work.
Persistent storage errors stop automatic mapping and expose a Resume retry.

The existing atomic manifest/revision store remains the durable boundary. A
checkpoint includes geometry, calibrated photos, navigation, text, signs, a
reference image, and the secure ARKit world map. These are local protected
files. A force-quit or lost tracking can leave observations since the last
successful checkpoint only in memory; the app does not promise a final camera
checkpoint after iOS has suspended it. Manual New Map explicitly discards the
current unsaved remainder after the UI's confirmation.

## Bounded segments, without a global place quota

The runtime and decoder retain per-segment bounds. Geometry approaches rollover
at 70% of its 750,000-vertex, 1,500,000-triangle, or 2,000-anchor limits; estimates
include disjoint restored chunks. Photo and text controllers also request
rollover before their respective hard caps. A segment can hold at most
48 calibrated photos/32 MiB of photo data, 20,000 navigation nodes/40,000 edges
and 100 destination labels,
20,000 text observations and signs each, and 48 MiB of combined text/sign image
evidence. The encoded geometry envelope is bounded to 256 MiB. These bounds
protect in-memory work and decoding, not the number of saved places on disk.

For rollover, the coordinator freezes photo/text intake, copies a final valid
geometry snapshot, temporarily disables only scene reconstruction, and commits
the archive. The same camera/IMU/depth session and path recording continue.
The final immutable capture remains in memory if writing fails; automatic
mapping then pauses visibly and Resume retries that capture. Only a successful
durable save permits reconstruction/photo/text caches to rotate.

Reconstruction restarts using `resetSceneReconstruction`, without `resetTracking`
or `removeExistingAnchors`. Apple specifies that this option removes the mesh
anchors; tracking coordinates and the saved-place origin marker are retained.
Fresh frame timestamps and post-reset mesh-anchor admission prevent old chunks
from being captured into the new file. [Apple's resetSceneReconstruction reference](https://developer.apple.com/documentation/arkit/arsession/runoptions/resetscenereconstruction)

The next file has a new ID, a shared logical `placeID`, and a new `segmentIndex`.
It keeps the same world coordinates, complete navigation graph, labels, and
active route. Every later checkpoint includes the graph's newest nodes, so path
samples recorded during a file write are not discarded. At navigation capacity,
only new path recording stops with a visible explanation; existing routes and
camera/color/OCR work remain available. Explicit New Map or a different-place
restore changes the origin and cannot bridge unrelated graphs.

Segments appear as individual library entries. Their mesh/photo/text payloads
are not automatically combined into one offline scene, even when their world
coordinates match. A sudden size jump beyond a hard cap can require manual
recovery; no decoder or save path silently truncates meshes or photos. Deleting
the active saved file pauses mapping to avoid silently recreating it; Resume
can save the retained live scan as a new entry.

The 6,000-point display trail is a bounded visualization. It is independent of
the navigation graph, whose visited nodes and labels persist separately.

## Captured appearance

`MappingColorCapture` receives only accepted normal-tracking frames. A bounded
worker samples at most twice per second, projecting mesh vertices into the
matching RGB image. Color requires agreeing medium/high-confidence depth, so a
foreground object is not painted onto a farther wall. The first valid sample
is retained in anchor-local position cells; this avoids dependence on mutable
mesh vertex ordering. Unseen vertices remain visibly uncolored.

Camera keyframes are separate JPEG observations with their world pose,
intrinsics, dimensions, and capture time. They retain native sensor orientation;
the longest side is reduced to 1,024 pixels and intrinsics scale with it.
JPEG EXIF metadata records the capture orientation so the gallery presents an upright
image without rotating its calibrated pixel coordinates. A new
view is eligible after six seconds and sufficient camera translation or
rotation. This is sampled photographic coverage, not full-resolution video or
a texture atlas. The offline viewer offers captured vertex colors, surfaces,
wireframe, path/labels, and a photo gallery. It does not perform photogrammetric
texture baking or repair invisible surfaces.

## Recorded routes and destinations

`NavigationController` records accepted poses at about 5 Hz, sampling new nodes
after meaningful motion. Edges represent short consecutive observed movements.
Tracking gaps, stale frames, origin changes, large jumps, and unsupported height
changes break connectivity. Spatial proximity alone does not connect corridors.
A destination names a visited node; Return to Start targets the graph's first
node. Current-scan routes can be used before the first save. Restored graph
directions require proof that the saved coordinate space was recognized.

Shortest-path search uses saved edges. Live following gives turns and remaining
distance, with optional speech. It pauses directions on tracking loss, leaving
the recorded path, an observed obstruction, or unavailable forward depth. The
camera must face the direction of travel. Selecting a destination calculates a
route through recorded paths; the app does not invent a detour around an
obstacle, join disconnected components, or plan between unrelated origins/floors.
Route speech and the existing Assist guidance have mutually exclusive control.
This prototype has not been validated as a mobility aid or evacuation system.

## Local OCR and signage

`LocalTextRecognitionController` runs Apple Vision OCR at approximately 1 Hz,
one worker at a time, without sending images to a service. Image boxes are
normalized against that observation's upright evidence image. Live world marks
are available only when confident depth supports a position. Without depth,
text remains an image observation; the code does not invent its distance.

Repeated text is matched by normalized spelling and nearby world position, or
by a recent nearly identical viewpoint/direction and overlapping image box
when depth is absent. Different repeated signs can remain separate. Persistent
observations retain the most recent evidence and a sighting count, rather than
one duplicate image for every OCR tick. Old-generation or stale results are
discarded when a session changes.

Recognized arrow glyphs and approximate printed-arrow contours become separate
signage records associated with nearby text in the same image. Direction is
image-relative. An up arrow does not establish stairs, a world bearing, or a
walkable edge, and signs do not automatically create graph routes. OCR spelling,
arrow association, and depth placement remain estimates the user can inspect
in the saved image. Dense text, lighting, reflections, and unusual arrow shapes
can reduce coverage or create false positives.

## Verification boundary

Windows syntax parsing and source review were supplemented by Apple SDK
compilation and simulator tests in GitHub macOS CI. Follow-up code head
`9b0c1a235e523d324e705ca558880e7b8822c46d` passed the unsigned iPhone build and
**123 tests in 14 suites in 6.388 seconds** in
[run 39555636456](https://github.com/RaahilRussell/LiDARPlayground/actions/runs/39555636456).
This is the verified code for [PR #3](https://github.com/RaahilRussell/LiDARPlayground/pull/3);
the earlier 77-test result covers the prior saved-place implementation. Remaining
compiler warnings, historical evidence, and physical acceptance checks are recorded in
[DEVICE_VALIDATION.md](DEVICE_VALIDATION.md). No physical iPhone measurements of
tracking drift, relocalization, color alignment, OCR quality, route safety,
battery, or sustained thermal behavior have been performed in this workspace.
