# Automatic color mapping, labeled navigation, and local text recognition

This follow-up plan was written before the new implementation. It extends the
single ARKit session and saved-place architecture from `MAPPING_PLAN.md`.

## Intended behavior

- Start mapping when the foreground app becomes active, without a Start or Save
  tap. Save the first usable map and checkpoint changes periodically. Continue
  sensing while browsing the local library. Respect an explicit Pause control.
- Resume the most recent place after launch. If automatic recognition times out,
  preserve it and begin a separate scan; an explicit revisit remains actionable.
- Save camera-derived surface colors and photographic keyframes, so the offline
  viewer shows captured appearance as well as geometry.
- Let the user name their current walked location, choose that destination later,
  and follow live turn/distance instructions or return to the route start.
- Run Apple Vision OCR locally at approximately one frame per second. Mark text
  automatically. Store directional signage separately with arrow direction,
  confidence, source image location, and any supported world position.

## Architectural decisions

1. Keep one ARSession. iOS background/lock interrupts camera tracking; this is
   continuous foreground capture with lifecycle recovery, not a background
   camera entitlement. Prevent automatic screen sleep while actively mapping,
   and restore the normal idle-timer behavior when paused/backgrounded.
2. Coordinate automatic saves, manual saves, restore, and delete through the
   existing persistence owner. Never silently overwrite a different coordinate
   space or drop accumulated changes. Checkpoint failures remain visible.
3. Project world vertices into the matching camera frame; accept colors only
   with confident agreeing depth, preserving prior valid colors. Store image
   keyframes with pose/intrinsics. Decode old uncolored maps with defaults.
4. Build a graph from successive accepted walking poses. Shortest-path search
   uses recorded edges only; geometric proximity does not create a corridor
   through a wall. Tracking gaps, coordinate resets, and unsupported floor
   changes break connectivity. A destination is a labeled visited graph node.
5. Suspend walking directions on stale tracking, relocalization, off-route
   positions, or unknown/blocked forward depth. Recalculate over known paths;
   never invent a detour through unobserved space. Coordinate speech ownership
   with existing wearer guidance and expose Stop and speech controls.
6. OCR consumes one immutable image/depth/pose sample at a time, with no backlog
   or cloud request. Reject results from old generations. Text without reliable
   depth remains an image observation, not an invented 3D location. Deduplicate
   repeated observations without merging separate physical signs. Arrow
   direction is image-relative signage metadata, not a proven walking edge.
7. Storage capacity is not a feature quota. Retain local observations and
   revisions needed for continuity; keep runtime/decoder bounds to protect the
   phone. If a bounded segment fills, commit it before moving to another segment
   and do not claim routes across unrelated coordinate spaces.

## Work and verification

Implement color/storage, navigation, and automatic lifecycle in parallel; root
integrates the app UI and OCR. Add algorithm/serialization regressions for color
projection, legacy maps, route topology, interruptions, signs/arrows, and save
policy. Run the shared unsigned iPhone build and simulator tests in macOS CI.
Record actual results separately from physical iPhone checks of color alignment,
OCR and arrows, relocalization, route accuracy, obstruction response, and thermal
behavior. This remains a prototype, not a validated mobility aid.

## Platform references

- [ARKit session lifecycle](https://developer.apple.com/documentation/arkit/managing-session-life-cycle-and-tracking-quality)
- [Recognizing text in images](https://developer.apple.com/documentation/vision/recognizing-text-in-images)
- [Reconstructed scene geometry](https://developer.apple.com/documentation/arkit/visualizing-and-interacting-with-a-reconstructed-scene)
