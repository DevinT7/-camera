import SwiftUI
import AppIntents
import LockedCameraCapture
import Photos

struct NotBoringShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: OpenCameraIntent(), phrases: ["Open \(.applicationName)", "Take a photo with \(.applicationName)"],
                    shortTitle: "Open !Camera", systemImageName: "camera.fill")
    }
}

/// Imports photos captured from the Lock Screen / Camera Control into the library.
enum LockedCaptureImporter {
    static func importPending() {
        for url in LockedCameraCaptureManager.shared.sessionContentURLs {
            let files = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
            for f in files where f.pathExtension.lowercased() == "heic" {
                PHPhotoLibrary.shared().performChanges({
                    PHAssetCreationRequest.creationRequestForAssetFromImage(atFileURL: f)
                }) { ok, _ in if ok { try? FileManager.default.removeItem(at: f) } }
            }
        }
    }
}
