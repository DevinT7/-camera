import AppIntents

/// Launches the LockedCameraCapture extension from the Lock Screen / Control Center / Camera Control.
struct LaunchCaptureIntent: CameraCaptureIntent {
    static let title: LocalizedStringResource = "Capture with !Camera"
    static let description = IntentDescription("Quick capture from the Lock Screen.")
    func perform() async throws -> some IntentResult { .result() }
}
