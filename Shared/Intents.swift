import AppIntents

/// Opens the full app. Used by the Action button, Shortcuts, Siri, the Control Center control and the home-screen widget.
struct OpenCameraIntent: AppIntent {
    static let title: LocalizedStringResource = "Open !Camera"
    static let description = IntentDescription("Opens !Camera ready to shoot.")
    static let openAppWhenRun = true
    func perform() async throws -> some IntentResult { .result() }
}
