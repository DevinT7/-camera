import SwiftUI
import AudioToolbox
import CoreMotion

extension Color {
    init(hex: String) {
        var v: UInt64 = 0
        Scanner(string: hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))).scanHexInt64(&v)
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

/// A saveable/shareable set of body colours ("colorway"). Custom colorways are a Plus feature.
struct Colorway: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var body: String
    var panel: String
    var dial: String
    var accent: String
    var shutter: String

    static let presets: [Colorway] = [
        .init(id: "orange", name: "Signal Orange", body: "E8E4D8", panel: "CFCABB", dial: "FF5A1F", accent: "FFC21A", shutter: "FF3B30"),
        .init(id: "graphite", name: "Graphite", body: "26262A", panel: "1A1A1D", dial: "8E8E93", accent: "FFD60A", shutter: "F2F2F7"),
        .init(id: "mint", name: "Mint Cream", body: "D9EFE3", panel: "BFE0CF", dial: "1FA971", accent: "FF9F0A", shutter: "FF453A"),
        .init(id: "bubblegum", name: "Bubblegum", body: "F8D7E4", panel: "EFBFD2", dial: "FF4F9A", accent: "5E5CE6", shutter: "FFFFFF"),
        .init(id: "cobalt", name: "Cobalt", body: "DDE4F5", panel: "C4CFEA", dial: "2F54EB", accent: "FFB020", shutter: "FF3B30"),
        .init(id: "nye", name: "New Year's Eve", body: "15151F", panel: "0D0D14", dial: "D4AF37", accent: "F5F0DC", shutter: "D4AF37"),
    ]
    static func named(_ id: String) -> Colorway { presets.first { $0.id == id } ?? presets[0] }

    var bodyColor: Color { Color(hex: body) }
    var panelColor: Color { Color(hex: panel) }
    var dialColor: Color { Color(hex: dial) }
    var accentColor: Color { Color(hex: accent) }
    var shutterColor: Color { Color(hex: shutter) }
    var isDarkBody: Bool { (UInt64(body, radix: 16) ?? 0) < 0x808080 }
    var ink: Color { isDarkBody ? Color(hex: "F2F2F7") : Color(hex: "1C1C1E") }
}

enum Feedback {
    static func tick() {
        guard AppSettings.shared.haptics else { return }
        UISelectionFeedbackGenerator().selectionChanged()
        click()
    }
    static func thump() {
        guard AppSettings.shared.haptics else { return }
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
    }
    static func toggle() {
        guard AppSettings.shared.haptics else { return }
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        click()
    }
    private static let clickIDs: [SystemSoundID] = [1104, 1105, 1123, 1306, 1057]
    static func click() {
        guard AppSettings.shared.sounds else { return }
        AudioServicesPlaySystemSound(clickIDs.randomElement()!)
    }
    static func shutter() {
        if AppSettings.shared.sounds { AudioServicesPlaySystemSound(1108) }
        thump()
    }
}

/// Drives the moving "real-time shadow" on the 3D-ish controls from device tilt.
final class Tilt: ObservableObject {
    @Published var x: CGFloat = 0
    @Published var y: CGFloat = 1
    private let mm = CMMotionManager()
    init() {
        guard mm.isDeviceMotionAvailable else { return }
        mm.deviceMotionUpdateInterval = 1 / 30
        mm.startDeviceMotionUpdates(to: .main) { [weak self] m, _ in
            guard let g = m?.gravity else { return }
            self?.x = CGFloat(g.x)
            self?.y = CGFloat(-g.y)
        }
    }
    deinit { mm.stopDeviceMotionUpdates() }
}
