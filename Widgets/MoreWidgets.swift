import WidgetKit
import SwiftUI

private let brandOrange = Color(red: 1, green: 0.35, blue: 0.12)
private let paper = Color(red: 0.91, green: 0.89, blue: 0.85)

// MARK: - Film roll (home screen small/medium, lock screen circular/rectangular)
struct RollEntry: TimelineEntry { let date: Date; let roll: RollSummary }

struct RollProvider: TimelineProvider {
    private var sample: RollSummary { RollSummary(shot: 17, size: 24, pending: 17, nextDevelop: Date().addingTimeInterval(9 * 3600)) }
    func placeholder(in context: Context) -> RollEntry { RollEntry(date: .now, roll: sample) }
    func getSnapshot(in context: Context, completion: @escaping (RollEntry) -> Void) {
        completion(RollEntry(date: .now, roll: context.isPreview ? sample : .load()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<RollEntry>) -> Void) {
        let r = RollSummary.load()
        let next = r.nextDevelop.map { max($0, Date().addingTimeInterval(60)) } ?? Date().addingTimeInterval(3600)
        completion(Timeline(entries: [RollEntry(date: .now, roll: r)], policy: .after(next)))
    }
}

struct RollWidgetView: View {
    @Environment(\.widgetFamily) var family
    let entry: RollEntry
    private var shot: Int { entry.roll.shot }
    private var size: Int { max(entry.roll.size, 1) }
    private var left: Int { max(size - shot, 0) }
    private var progress: Double { Double(shot) / Double(size) }

    @ViewBuilder private var developLine: some View {
        if let d = entry.roll.nextDevelop, d > entry.date {
            (Text("Develops in ") + Text(d, style: .relative))
        } else if entry.roll.pending > 0 {
            Text("Ready to develop")
        } else {
            Text("Film roll mode is off or empty")
        }
    }

    private var ring: some View {
        ZStack {
            Circle().stroke(Color.gray.opacity(0.25), lineWidth: 9)
            Circle().trim(from: 0, to: progress)
                .stroke(brandOrange, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: -2) {
                Text("\(left)").font(.system(size: 30, weight: .black, design: .rounded))
                Text("left").font(.system(size: 11, weight: .bold, design: .rounded)).foregroundStyle(.secondary)
            }
        }
    }

    var body: some View {
        Group {
            switch family {
            case .accessoryCircular:
                Gauge(value: Double(shot), in: 0...Double(size)) {
                    Image(systemName: "film.fill")
                } currentValueLabel: {
                    Text("\(left)")
                }
                .gaugeStyle(.accessoryCircularCapacity)
            case .accessoryRectangular:
                VStack(alignment: .leading, spacing: 2) {
                    Label("Film roll", systemImage: "film.fill").font(.headline)
                    Text("\(left) of \(size) frames left")
                    developLine.font(.caption)
                }
            case .systemMedium:
                HStack(spacing: 18) {
                    ring.frame(width: 104, height: 104)
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Film roll", systemImage: "film.fill").font(.system(size: 13, weight: .heavy, design: .rounded)).foregroundStyle(brandOrange)
                        Text("Frame \(min(shot + 1, size)) of \(size)").font(.system(size: 20, weight: .black, design: .rounded))
                        developLine.font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
                        if entry.roll.pending > 0 {
                            Text("\(entry.roll.pending) frames waiting").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
            default:
                VStack(spacing: 6) {
                    Label("Film roll", systemImage: "film.fill").font(.system(size: 12, weight: .heavy, design: .rounded)).foregroundStyle(brandOrange)
                    ring.frame(width: 84, height: 84)
                    developLine.font(.system(size: 10, weight: .semibold, design: .rounded)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
                }
            }
        }
        .containerBackground(paper, for: .widget)
        .widgetURL(URL(string: "notboringcamera://open"))
    }
}

struct FilmRollWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "FilmRollWidget", provider: RollProvider()) { RollWidgetView(entry: $0) }
            .configurationDisplayName("Film Roll")
            .description("Frames left on your roll and when it develops.")
            .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular])
    }
}

// MARK: - Last photo (home screen)
struct LastPhotoEntry: TimelineEntry { let date: Date; let image: UIImage?; let today: Int; let total: Int }

struct LastPhotoProvider: TimelineProvider {
    private func current() -> LastPhotoEntry {
        var img: UIImage?
        if let url = SharedStore.lastPhotoURL, let d = try? Data(contentsOf: url) { img = UIImage(data: d) }
        let s = ShotStats.load()
        return LastPhotoEntry(date: .now, image: img, today: s.todayCount, total: s.total)
    }
    func placeholder(in context: Context) -> LastPhotoEntry { LastPhotoEntry(date: .now, image: nil, today: 3, total: 248) }
    func getSnapshot(in context: Context, completion: @escaping (LastPhotoEntry) -> Void) { completion(current()) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<LastPhotoEntry>) -> Void) {
        let next = Calendar.current.startOfDay(for: Date()).addingTimeInterval(86_400)
        completion(Timeline(entries: [current()], policy: .after(next)))
    }
}

struct LastPhotoWidgetView: View {
    let entry: LastPhotoEntry
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 1) {
                if entry.image == nil { Image(systemName: "camera.aperture").font(.system(size: 28, weight: .bold)).foregroundStyle(.white.opacity(0.9)).padding(.bottom, 6) }
                Text(entry.image == nil ? "Take a photo" : "\(entry.today) today").font(.system(size: 15, weight: .black, design: .rounded))
                Text("\(entry.total) photos total").font(.system(size: 10, weight: .semibold, design: .rounded)).opacity(0.85)
            }
            .foregroundStyle(.white).shadow(radius: 3)
            .padding(12)
        }
        .containerBackground(for: .widget) {
            if let img = entry.image {
                Image(uiImage: img).resizable().scaledToFill()
            } else {
                LinearGradient(colors: [Color(red: 0.23, green: 0.29, blue: 0.42), Color(red: 0.9, green: 0.54, blue: 0.31)], startPoint: .top, endPoint: .bottom)
            }
        }
        .widgetURL(URL(string: "notboringcamera://open"))
    }
}

struct LastPhotoWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "LastPhotoWidget", provider: LastPhotoProvider()) { LastPhotoWidgetView(entry: $0) }
            .configurationDisplayName("Last Photo")
            .description("Your latest shot, big.")
            .supportedFamilies([.systemSmall, .systemMedium])
            .contentMarginsDisabled()
    }
}

// MARK: - Streak (lock screen + small home widget)
struct StreakProvider: TimelineProvider {
    private var sample: ActivityEntry { var s = ShotStats(); s.streak = 6; s.perDay = [ShotStats.dayString(): 3]; return ActivityEntry(date: .now, stats: s) }
    func placeholder(in context: Context) -> ActivityEntry { sample }
    func getSnapshot(in context: Context, completion: @escaping (ActivityEntry) -> Void) { completion(context.isPreview ? sample : ActivityEntry(date: .now, stats: .load())) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<ActivityEntry>) -> Void) {
        let next = Calendar.current.startOfDay(for: Date()).addingTimeInterval(86_400)
        completion(Timeline(entries: [ActivityEntry(date: .now, stats: .load())], policy: .after(next)))
    }
}

struct StreakWidgetView: View {
    @Environment(\.widgetFamily) var family
    let entry: ActivityEntry
    private var streak: Int { entry.stats.streak }

    var body: some View {
        let days = entry.stats.last7()
        Group {
            switch family {
            case .accessoryCircular:
                Gauge(value: Double(min(streak, 7)), in: 0...7) {
                    Image(systemName: "flame.fill")
                } currentValueLabel: {
                    Text("\(streak)")
                }
                .gaugeStyle(.accessoryCircularCapacity)
            case .accessoryRectangular:
                VStack(alignment: .leading, spacing: 3) {
                    Label("\(streak)-day streak", systemImage: "flame.fill").font(.headline)
                    HStack(alignment: .bottom, spacing: 3) {
                        ForEach(days, id: \.0) { d in
                            RoundedRectangle(cornerRadius: 2).frame(height: d.1 > 0 ? 14 : 5).opacity(d.1 > 0 ? 1 : 0.35)
                        }
                    }
                    Text("\(entry.stats.todayCount) today").font(.caption)
                }
            case .accessoryInline:
                Label("\(streak)-day streak · \(entry.stats.todayCount) today", systemImage: "flame.fill")
            default:
                VStack(spacing: 6) {
                    Image(systemName: "flame.fill").font(.system(size: 30, weight: .bold)).foregroundStyle(brandOrange)
                    Text("\(streak)").font(.system(size: 44, weight: .black, design: .rounded))
                    Text(streak == 1 ? "day streak" : "day streak").font(.system(size: 12, weight: .bold, design: .rounded)).foregroundStyle(.secondary)
                    HStack(spacing: 5) {
                        ForEach(days, id: \.0) { d in Circle().fill(d.1 > 0 ? brandOrange : Color.gray.opacity(0.3)).frame(width: 9, height: 9) }
                    }
                }
            }
        }
        .containerBackground(paper, for: .widget)
        .widgetURL(URL(string: "notboringcamera://open"))
    }
}

struct StreakWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "StreakWidget", provider: StreakProvider()) { StreakWidgetView(entry: $0) }
            .configurationDisplayName("Streak")
            .description("Keep the shooting streak alive.")
            .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}
