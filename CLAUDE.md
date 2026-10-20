# LiDARPlayground

SwiftUI iOS app in `test.xcodeproj`, scheme `test`; targets `test` and `testTests`.
Uses ARKit, SceneKit, CoreHaptics, Core ML, and the pinned UltralyticsYOLO Swift
package. Source lives in `test/`; Core ML models are in `test/Models/`.
Current deployment target is iOS 26.5. Do not lower it or change signing/team
settings just to satisfy a cloud build.

## Cloud work

- Work on a separate `claude/` branch, commit changes, and push the branch.
- Never push directly to main, force-push, or commit credentials/signing files.
- Keep changes scoped to the requested task. Preserve existing model assets.
- Anthropic-hosted cloud environments do not provide Xcode or iOS Simulator.
  Do not claim an iOS build, simulator run, or device test from Linux.
- LiDAR, camera tracking, proximity warnings, and haptics need physical-device
  validation. This is a prototype; do not claim navigation safety.
- Report checks actually run and remaining validation clearly.

## macOS build

```sh
DEVELOPER_DIR=/Users/raahil/Downloads/Xcode.app/Contents/Developer \
xcodebuild -project test.xcodeproj -scheme test -configuration Debug \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

See `CLOUD_WORKFLOW.md` for starting cloud tasks and retrieving changes.
