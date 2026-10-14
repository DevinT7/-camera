import SwiftUI

@main
struct NotBoringCameraApp: App {
    @StateObject private var settings = AppSettings.shared
    @StateObject private var camera = CameraModel()

    var body: some Scene {
        WindowGroup {
            CameraView()
                .environmentObject(settings)
                .environmentObject(camera)
                .onOpenURL { url in
                    if let c = ColorwayCodec.colorway(from: url) { settings.customColorways.append(c); settings.colorwayID = c.id }
                }
                .onAppear { LockedCaptureImporter.importPending() }
        }
    }
}
