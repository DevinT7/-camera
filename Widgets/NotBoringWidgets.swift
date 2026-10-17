import WidgetKit
import SwiftUI
import AppIntents

// MARK: Activity widget (home screen)
struct ActivityEntry: TimelineEntry { let date: Date; let stats: ShotStats }

struct ActivityProvider: TimelineProvider {
    func placeholder(in context: Context) -> ActivityEntry { ActivityEntry(date: .now, stats: sample) }
    func getSnapshot(in context: Context, completion: @escaping (ActivityEntry) -> Void) { completion(ActivityEntry(date: .now, stats: context.isPreview ? sample : .load())) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<ActivityEntry>) -> Void) {
        let next = Calendar.current.startOfDay(for: Date()).addingTimeInterval(86_400)
        completion(Timeline(entries: [ActivityEntry(date: .now, stats: .load())], policy: .after(next)))
    }
    private var sample: ShotStats {
        var s = ShotStats(); s.total = 248; s.streak = 6
        for (i, (k, _)) in s.last7().enumerated() { s.perDay[k] = [2, 5, 0, 8, 3, 6, 4][i] }
        return s
    }
}

struct ActivityWidgetView: View {
    @Environment(\.widgetFamily) var family
    let entry: ActivityEntry
    private let orange = Color(red: 1, green: 0.35, blue: 0.12)

    var body: some View {
        let days = entry.stats.last7()
        let mx = max(days.map(\.1).max() ?? 1, 1)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("!Camera", systemImage: "camera.fill").font(.system(size: 12, weight: .heavy, design: .rounded)).foregroundStyle(orange)
                Spacer()
                Label("\(entry.stats.streak)", systemImage: "flame.fill").font(.system(size: 12, weight: .heavy, design: .rounded)).foregroundStyle(.orange)
            }
            Text("\(entry.stats.todayCount)").font(.system(size: family == .systemSmall ? 40 : 46, weight: .black, design: .rounded)) +
            Text(" today").font(.system(size: 13, weight: .bold, design: .rounded)).foregroundColor(.secondary)
            Spacer(minLength: 0)
            HStack(alignment: .bottom, spacing: 5) {
                ForEach(days, id: \.0) { d in
                    VStack(spacing: 3) {
                        RoundedRectangle(cornerRadius: 3).fill(d.1 > 0 ? orange : Color.gray.opacity(0.3))
                            .frame(height: max(4, CGFloat(d.1) / CGFloat(mx) * 34))
                    }.frame(maxWidth: .infinity)
                }
            }.frame(height: 36)
            if family != .systemSmall {
                Text("\(entry.stats.total) photos total · best streak \(entry.stats.bestStreak) days").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .containerBackground(Color(red: 0.91, green: 0.89, blue: 0.85), for: .widget)
        .widgetURL(URL(string: "notboringcamera://open"))
    }
}

struct ActivityWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ActivityWidget", provider: ActivityProvider()) { ActivityWidgetView(entry: $0) }
            .configurationDisplayName("Activity")
            .description("Your shooting streak and the last 7 days.")
            .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// MARK: Launch widget (home screen + lock screen)
struct LaunchEntry: TimelineEntry { let date: Date }
struct LaunchProvider: TimelineProvider {
    func placeholder(in context: Context) -> LaunchEntry { LaunchEntry(date: .now) }
    func getSnapshot(in context: Context, completion: @escaping (LaunchEntry) -> Void) { completion(LaunchEntry(date: .now)) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<LaunchEntry>) -> Void) { completion(Timeline(entries: [LaunchEntry(date: .now)], policy: .never)) }
}
struct LaunchWidgetView: View {
    @Environment(\.widgetFamily) var family
    var body: some View {
        Group {
            switch family {
            case .accessoryCircular:
                ZStack { AccessoryWidgetBackground(); Image("BangLens").resizable().scaledToFit().padding(11).widgetAccentable() }
            case .accessoryInline:
                Label("Open !Camera", systemImage: "camera.fill")
            case .accessoryRectangular:
                HStack { Image(systemName: "camera.fill").font(.title2); VStack(alignment: .leading) { Text("!Camera").font(.headline); Text("Tap to shoot").font(.caption) } }
            default:
                ZStack {
                    Color(red: 1, green: 0.35, blue: 0.12)
                    VStack(spacing: 6) { Image(systemName: "camera.fill").font(.system(size: 34, weight: .bold)); Text("!Camera").font(.system(size: 15, weight: .black, design: .rounded)) }.foregroundStyle(.white)
                }
            }
        }
        .containerBackground(.clear, for: .widget)
        .widgetURL(URL(string: "notboringcamera://open"))
    }
}
struct LaunchWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "LaunchWidget", provider: LaunchProvider()) { _ in LaunchWidgetView() }
            .configurationDisplayName("Launch !Camera")
            .description("One tap to the camera.")
            .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

// MARK: Control Center / Lock Screen controls (also assignable to the Action button and Camera Control)
struct OpenCameraControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.devin.camera.notboring.open") {
            ControlWidgetButton(action: OpenCameraIntent()) { Label("!Camera", image: "BangLens") }
        }
        .displayName("!Camera")
        .description("Open !Camera.")
    }
}

struct CaptureCameraControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.devin.camera.notboring.capture") {
            ControlWidgetButton(action: LaunchCaptureIntent()) { Label("!Camera Capture", image: "BangLens") }
        }
        .displayName("!Camera Capture")
        .description("Quick capture from the Lock Screen or Camera Control.")
    }
}

@main
struct NotBoringWidgetBundle: WidgetBundle {
    var body: some Widget {
        ActivityWidget()
        FilmRollWidget()
        LastPhotoWidget()
        StreakWidget()
        LaunchWidget()
        OpenCameraControl()
        CaptureCameraControl()
    }
}
