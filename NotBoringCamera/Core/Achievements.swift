import SwiftUI

struct Sticker: Identifiable, Hashable {
    let id: String
    let symbol: String
    let title: String
    let fg: String
    let bg: String
}

struct Achievement: Identifiable {
    let id: String
    let title: String
    let detail: String
    let sticker: Sticker
    let check: (ShotStats) -> Bool
}

enum Achievements {
    static let all: [Achievement] = [
        a("first", "First Frame", "Take your first photo.", "camera.fill", "FF5A1F") { $0.total >= 1 },
        a("ten", "Warming Up", "Take 10 photos.", "flame.fill", "FF9F0A") { $0.total >= 10 },
        a("hundred", "Centurion", "Take 100 photos.", "100.circle.fill", "30B0C7") { $0.total >= 100 },
        a("thousand", "Shutterbug", "Take 1,000 photos.", "crown.fill", "FFD60A") { $0.total >= 1000 },
        a("streak3", "On a Roll", "Shoot 3 days in a row.", "3.circle.fill", "34C759") { $0.bestStreak >= 3 },
        a("streak7", "Weekly Habit", "Shoot 7 days in a row.", "calendar", "5E5CE6") { $0.bestStreak >= 7 },
        a("streak30", "Daily Ritual", "Shoot 30 days in a row.", "sparkles", "FF2D55") { $0.bestStreak >= 30 },
        a("manual", "Hands On", "Take a photo in Manual mode.", "slider.horizontal.3", "8E8E93") { $0.usedManual },
        a("superraw", "Raw Talent", "Shoot with SuperRAW.", "film.fill", "BF5AF2") { $0.usedSuperRaw },
        a("stylist", "Stylist", "Shoot with every built-in Style.", "paintpalette.fill", "FF375F") { Set($0.stylesUsed).isSuperset(of: Styles.builtIn.map(\.id)) },
        a("zoom", "Long Reach", "Shoot at 8× zoom or more.", "scope", "0A84FF") { $0.maxZoom >= 8 },
        a("night", "Night Owl", "Shoot between midnight and 4am.", "moon.stars.fill", "64D2FF") { $0.nightShot },
        a("video", "Rolling", "Record your first video.", "video.fill", "FF453A") { $0.videos >= 1 },
        a("lab", "Lab Rat", "Save an edit from Photo Lab.", "wand.and.stars", "AC8E68") { $0.labSaves >= 1 },
        a("lut", "Bring Your Own", "Import a .CUBE LUT.", "square.and.arrow.down.fill", "30D158") { $0.lutImported },
        a("share", "Sharing Is Caring", "Share a colorway by QR code.", "qrcode", "FFB020") { $0.qrShares >= 1 },
    ]

    private static func a(_ id: String, _ title: String, _ detail: String, _ symbol: String, _ bg: String, _ check: @escaping (ShotStats) -> Bool) -> Achievement {
        Achievement(id: id, title: title, detail: detail, sticker: Sticker(id: "sticker-" + id, symbol: symbol, title: title, fg: "FFFFFF", bg: bg), check: check)
    }
}

/// Records activity, unlocks achievements, and refreshes the widgets.
@MainActor
final class StatsStore: ObservableObject {
    static let shared = StatsStore()
    @Published private(set) var stats = ShotStats.load()
    @Published var justUnlocked: Achievement?

    func recordPhoto(styleID: String, manual: Bool, superRaw: Bool, zoom: Double) {
        mutate { s in
            s.total += 1
            s.maxZoom = max(s.maxZoom, zoom)
            if manual { s.usedManual = true }
            if superRaw { s.usedSuperRaw = true }
            if !s.stylesUsed.contains(styleID) { s.stylesUsed.append(styleID) }
            let h = Calendar.current.component(.hour, from: Date())
            if h < 4 { s.nightShot = true }
            Self.bumpDay(&s)
        }
    }
    func recordVideo() { mutate { s in s.videos += 1; Self.bumpDay(&s) } }
    func recordLabSave() { mutate { $0.labSaves += 1 } }
    func recordQRShare() { mutate { $0.qrShares += 1 } }
    func recordLUTImport() { mutate { $0.lutImported = true } }

    private static func bumpDay(_ s: inout ShotStats) {
        let today = ShotStats.dayString()
        let yesterday = ShotStats.dayString(Calendar.current.date(byAdding: .day, value: -1, to: Date())!)
        if s.lastDay != today { s.streak = (s.lastDay == yesterday) ? s.streak + 1 : 1 }
        s.lastDay = today
        s.bestStreak = max(s.bestStreak, s.streak)
        s.perDay[today, default: 0] += 1
        let cutoff = ShotStats.dayString(Calendar.current.date(byAdding: .day, value: -14, to: Date())!)
        s.perDay = s.perDay.filter { $0.key >= cutoff }
    }

    private func mutate(_ f: (inout ShotStats) -> Void) {
        var s = stats
        f(&s)
        var newly: Achievement?
        for a in Achievements.all where !s.unlocked.contains(a.id) && a.check(s) {
            s.unlocked.append(a.id); newly = newly ?? a
        }
        s.save()
        stats = s
        if let n = newly {
            justUnlocked = n
            Feedback.thump()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in if self?.justUnlocked?.id == n.id { self?.justUnlocked = nil } }
        }
        ActivityReload.reload()
    }

    func isUnlocked(_ a: Achievement) -> Bool { stats.unlocked.contains(a.id) }
    var unlockedStickers: [Sticker] { Achievements.all.filter(isUnlocked).map(\.sticker) }
}

#if canImport(WidgetKit)
import WidgetKit
enum ActivityReload { static func reload() { WidgetCenter.shared.reloadAllTimelines() } }
#endif

struct StickerView: View {
    let sticker: Sticker
    var locked = false
    var size: CGFloat = 64
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(locked ? Color.gray.opacity(0.25) : Color(hex: sticker.bg))
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).strokeBorder(.white.opacity(locked ? 0.1 : 0.9), lineWidth: size * 0.05)
            Image(systemName: locked ? "lock.fill" : sticker.symbol)
                .font(.system(size: size * 0.46, weight: .bold)).foregroundStyle(locked ? .gray : Color(hex: sticker.fg))
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(locked ? 0 : 0.25), radius: 3, y: 2)
    }
}

struct AchievementsView: View {
    @ObservedObject var store = StatsStore.shared
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 24) {
                        stat("\(store.stats.total)", "photos"); stat("\(store.stats.streak)", "day streak"); stat("\(store.stats.unlocked.count)/\(Achievements.all.count)", "stickers")
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 14)], spacing: 18) {
                        ForEach(Achievements.all) { a in
                            let u = store.isUnlocked(a)
                            VStack(spacing: 6) {
                                StickerView(sticker: a.sticker, locked: !u, size: 72)
                                Text(a.title).font(.system(size: 13, weight: .bold, design: .rounded)).multilineTextAlignment(.center)
                                Text(a.detail).font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            }.opacity(u ? 1 : 0.7)
                        }
                    }
                }.padding()
            }
            .navigationTitle("Achievements").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
    private func stat(_ v: String, _ l: String) -> some View {
        VStack { Text(v).font(.system(size: 28, weight: .black, design: .rounded)); Text(l).font(.caption).foregroundStyle(.secondary) }
    }
}
