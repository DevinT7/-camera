import Foundation
import Photos
import UIKit

/// A roll of film: shots go to private storage (no preview, no deleting) and are "developed" into Photos 24h after the last frame.
struct FilmRoll: Codable, Identifiable {
    var id = UUID()
    var size: Int
    var files: [String] = []
    var lastShot: Date?
    var delay: TimeInterval?     // chosen when the roll was loaded; nil on rolls from before the setting existed (24h)
    var number: Int?
    var developAt: Date? { lastShot.map { $0.addingTimeInterval(delay ?? RollStore.developDelay) } }
    var isFull: Bool { files.count >= size }
}

@MainActor
final class RollStore: ObservableObject {
    static let shared = RollStore()
    static let developDelay: TimeInterval = 24 * 3600

    @Published private(set) var rolls: [FilmRoll] = []
    /// Set when a roll finishes developing; the camera screen presents the reveal + contact sheet for it.
    @Published var developed: DevelopedRoll?

    private static let dir: URL = {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("FilmRolls", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    private static var indexURL: URL { dir.appendingPathComponent("index.json") }

    init() {
        if let d = try? Data(contentsOf: Self.indexURL), let r = try? JSONDecoder().decode([FilmRoll].self, from: d) { rolls = r }
    }

    /// The roll in the camera right now (nil until the first frame of a new one is shot).
    var current: FilmRoll? { rolls.last { !$0.isFull } }
    var framesShot: Int { current?.files.count ?? 0 }
    var framesLeft: Int { (current?.size ?? AppSettings.shared.rollSize) - framesShot }
    var pendingFrames: Int { rolls.reduce(0) { $0 + $1.files.count } }
    var nextDevelop: Date? { rolls.compactMap(\.developAt).min() }

    nonisolated static func write(_ data: Data) -> String? {
        let name = UUID().uuidString + ".heic"
        do { try data.write(to: dir.appendingPathComponent(name), options: .atomic); return name } catch { return nil }
    }

    func add(file: String) {
        if current == nil {
            let n = UserDefaults.standard.integer(forKey: "rollCounter") + 1
            UserDefaults.standard.set(n, forKey: "rollCounter")
            rolls.append(FilmRoll(size: AppSettings.shared.rollSize, delay: Double(AppSettings.shared.developHours) * 3600, number: n))
        }
        let i = rolls.count - 1
        rolls[i].files.append(file)
        rolls[i].lastShot = Date()
        if rolls[i].isFull { StatsStore.shared.recordFullRoll() }
        persist()
        if rolls[i].isFull { seal(rolls[i]) }
        RollNotifications.requestIfNeeded()
        RollNotifications.schedule(rollID: rolls[i].id, at: rolls[i].developAt ?? Date().addingTimeInterval(Self.developDelay), frames: rolls[i].files.count)
    }

    /// Ends the current roll early; it develops 24h after its last frame like any other.
    func rewind() {
        guard let i = rolls.lastIndex(where: { !$0.isFull }), !rolls[i].files.isEmpty else { return }
        rolls[i].size = rolls[i].files.count
        persist()
        seal(rolls[i])
    }

    /// A roll just became final (last frame shot, or finished early): tell the user when it will be ready.
    private func seal(_ r: FilmRoll) {
        guard let at = r.developAt else { return }
        let n = r.number ?? 0
        RollNotifications.sealed(number: n, at: at, hours: Int((r.delay ?? Self.developDelay) / 3600))
        RollActivity.start(number: n, frames: r.files.count, developAt: at)
    }

    func developDue(force: Bool = false) {
        let now = Date()
        let due = rolls.filter { !$0.files.isEmpty && (force || ($0.developAt ?? .distantFuture) <= now) }
        guard !due.isEmpty else { return }
        for roll in due {
            let urls = roll.files.map { Self.dir.appendingPathComponent($0) }
            let blobs = urls.compactMap { try? Data(contentsOf: $0) }
            let thumbs = blobs.compactMap { RollThumbs.thumbnail(from: $0) }
            let group = DispatchGroup()
            var failed = false
            for d in blobs {
                group.enter()
                CameraModel.saveToLibrary(heic: d, dng: nil, date: roll.lastShot ?? Date()) { ok in if !ok { failed = true }; group.leave() }
            }
            group.notify(queue: .main) { [weak self] in
                guard let self, !failed else { return }
                urls.forEach { try? FileManager.default.removeItem(at: $0) }
                RollNotifications.cancel(rollID: roll.id)
                RollActivity.end(number: roll.number)
                self.rolls.removeAll { $0.id == roll.id }
                self.persist()
                StatsStore.shared.recordRollDeveloped()
                self.developed = DevelopedRoll(frames: thumbs, date: roll.lastShot ?? Date(), size: roll.size)
            }
        }
    }

    private func persist() {
        try? JSONEncoder().encode(rolls).write(to: Self.indexURL, options: .atomic)
        RollSummary(shot: framesShot, size: current?.size ?? AppSettings.shared.rollSize, pending: pendingFrames, nextDevelop: nextDevelop).save()
        ActivityReload.reload()
    }
}
