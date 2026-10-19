import SwiftUI

/// "Little victories.": streak banner, sticker collection, next goal, and the Polaroid photo book.
struct AchievementsView: View {
    @ObservedObject var store = StatsStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var tab = 0
    private var cw: Colorway { AppSettings.shared.colorway }
    private var ink: Color { cw.ink }

    private let encouragements = [
        "A little looking, every single day.",
        "Keep the streak alive.",
        "One frame is all it takes.",
        "Good things take a day.",
        "Notice something small today.",
    ]
    private var line: String { encouragements[Calendar.current.component(.day, from: Date()) % encouragements.count] }

    var body: some View {
        ZStack {
            cw.bodyColor.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        Text("YOUR STICKER COLLECTION").font(.system(size: 11, weight: .medium, design: .monospaced)).tracking(1).foregroundStyle(ink.opacity(0.6))
                        Spacer()
                        Button { dismiss() } label: { Image(systemName: "xmark").font(.system(size: 17, weight: .bold)).foregroundStyle(ink) }
                            .accessibilityLabel("Close")
                    }
                    Text("Little victories.").font(.system(size: 38, weight: .black, design: .rounded)).foregroundStyle(ink)
                    streakBanner
                    picker
                    if tab == 0 { stickers } else { PhotoBookView().foregroundStyle(ink) }
                }
                .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 40)
            }
        }
        .preferredColorScheme(cw.isDarkBody ? .dark : .light)
    }

    // MARK: Streak
    private var streakBanner: some View {
        let s = store.stats.streak
        return HStack(spacing: 14) {
            Image(systemName: s > 0 ? "flame.fill" : "flame").font(.system(size: 28, weight: .bold)).foregroundStyle(.black.opacity(0.85))
            VStack(alignment: .leading, spacing: 2) {
                Text(s > 0 ? "\(s)-day streak!" : "Start a streak").font(.system(size: 22, weight: .black, design: .rounded)).foregroundStyle(.black.opacity(0.88))
                Text(s > 0 ? line : "Take a photo today.").font(.system(size: 12, weight: .medium, design: .rounded)).foregroundStyle(.black.opacity(0.7))
            }
            Spacer()
            Text("\(store.stats.unlocked.count) / \(Achievements.all.count)").font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(.black.opacity(0.7))
        }
        .padding(.horizontal, 18).padding(.vertical, 16)
        .background(cw.accentColor, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var picker: some View {
        HStack(spacing: 0) {
            ForEach([(0, "Stickers"), (1, "Photo book")], id: \.0) { i, title in
                Text(title).font(.system(size: 13, weight: .heavy, design: .rounded))
                    .frame(maxWidth: .infinity).padding(.vertical, 9)
                    .foregroundStyle(tab == i ? .white : ink.opacity(0.65))
                    .background(tab == i ? cw.dialColor : .clear, in: Capsule())
                    .contentShape(Capsule())
                    .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { tab = i }; Feedback.toggle() }
            }
        }
        .padding(3).background(cw.panelColor, in: Capsule())
    }

    // MARK: Stickers
    private var stickers: some View {
        VStack(alignment: .leading, spacing: 16) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach(Array(Achievements.all.enumerated()), id: \.element.id) { i, a in
                    let u = store.isUnlocked(a)
                    VStack(spacing: 8) {
                        StickerView(sticker: a.sticker, locked: !u, size: 70)
                            .rotationEffect(.degrees(i % 2 == 0 ? -5 : 5))
                            .padding(.top, 14)
                        Text(a.title).font(.system(size: 14, weight: .heavy, design: .rounded)).foregroundStyle(ink).multilineTextAlignment(.center)
                        Text(a.detail).font(.system(size: 11, weight: .medium, design: .rounded)).foregroundStyle(ink.opacity(0.6)).multilineTextAlignment(.center)
                            .frame(maxHeight: .infinity, alignment: .top)
                    }
                    .frame(maxWidth: .infinity, minHeight: 160).padding(.horizontal, 10).padding(.bottom, 14)
                    .background(cw.panelColor.opacity(0.55), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .opacity(u ? 1 : 0.62)
                }
            }
            nextGoal
        }
    }

    @ViewBuilder private var nextGoal: some View {
        let stats = store.stats
        let candidates = Achievements.all.filter { !store.isUnlocked($0) }.compactMap { a in Achievements.progress(for: a.id, stats).map { (a, $0) } }
        if let (a, p) = candidates.max(by: { Double($0.1.current) / Double($0.1.target) < Double($1.1.current) / Double($1.1.target) }) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "lock.fill").font(.system(size: 13, weight: .bold))
                    Text("Next: \(a.title)").font(.system(size: 13, weight: .heavy, design: .rounded))
                    Spacer()
                    Text("\(p.current) / \(p.target) \(p.unit)").font(.system(size: 10, weight: .semibold, design: .monospaced)).opacity(0.7)
                }
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(ink.opacity(0.12))
                        Capsule().fill(cw.dialColor).frame(width: g.size.width * min(CGFloat(p.current) / CGFloat(max(p.target, 1)), 1))
                    }
                }.frame(height: 6)
            }
            .foregroundStyle(ink)
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(ink.opacity(0.18), lineWidth: 1))
        }
    }
}
