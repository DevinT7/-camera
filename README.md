# !Camera clone (SwiftUI + AVFoundation + SceneKit)

Rebuilt from public information about "(Not Boring) Camera" (App Store listing, release notes, reviews). No binary was decompiled.

## Build
`xcodegen generate && open NotBoringCamera.xcodeproj`. Set your signing team on all three targets, keep the App Group `group.com.devin.camera.notboring` (or change it in `Shared/SharedStore.swift` and the three `.entitlements` files), and run on a real iPhone (the simulator has no camera).

## Targets
- **NotBoringCamera**: the app (photo + video, Styles, Photo Lab, achievements/stickers, colorways + QR, SceneKit 3D body).
- **NotBoringWidgets**: Activity widget, Launch widget (home + Lock Screen), Control Center / Lock Screen controls (Open, Capture).
- **NotBoringLockedCapture**: LockedCameraCapture extension (Lock Screen / Camera Control quick capture). Photos are imported into the library next time the app opens.

## Notes
- Zoom is continuous (pinch, drag the zoom pill, or tap the 0.5/1/2/4/8 shortcuts).
- Everything is unlocked: no subscription or paywall.
- Camera Control (iPhone 16+) exposes Zoom, Exposure and Style while the app is open; assign the "!Camera Capture" control to Camera Control in Settings to launch from outside the app.
- Colorways share as `notboringcamera://colorway?d=…` QR codes / links (Settings → Colorways).
