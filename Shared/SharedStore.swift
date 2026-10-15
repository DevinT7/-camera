import Foundation

enum SharedStore {
    static let groupID = "group.com.devin.camera.notboring"
    /// App Group defaults so the app, widgets and lock-screen extension see the same data. Falls back to standard defaults when unsigned.
    static var defaults: UserDefaults { UserDefaults(suiteName: groupID) ?? .standard }
    static var containerURL: URL? { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) }
}

/// Shooting statistics shown by the activity widget and used by achievements.
struct ShotStats: Codable {
    var total = 0
    var videos = 0
    var streak = 0
    var bestStreak = 0
    var lastDay = ""                       // yyyy-MM-dd
    var perDay: [String: Int] = [:]        // last ~14 days
    var stylesUsed: [String] = []
    var maxZoom: Double = 1
    var usedManual = false
    var usedSuperRaw = false
    var nightShot = false
    var labSaves = 0
    var qrShares = 0
    var lutImported = false
    var unlocked: [String] = []
    var rollsDeveloped: Int? = nil
    var fullRolls: Int? = nil

    static let key = "shotStats.v1"
    static func load() -> ShotStats {
        guard let d = SharedStore.defaults.data(forKey: key), let s = try? JSONDecoder().decode(ShotStats.self, from: d) else { return ShotStats() }
        return s
    }
    func save() { SharedStore.defaults.set(try? JSONEncoder().encode(self), forKey: Self.key) }

    static func dayString(_ d: Date = Date()) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX"); return f.string(from: d)
    }
    func last7() -> [(String, Int)] {
        (0..<7).reversed().map { off in
            let d = Calendar.current.date(byAdding: .day, value: -off, to: Date())!
            let k = Self.dayString(d)
            return (k, perDay[k] ?? 0)
        }
    }
    var todayCount: Int { perDay[Self.dayString()] ?? 0 }
}
