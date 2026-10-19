import ActivityKit
import WidgetKit
import SwiftUI

private let devOrange = Color(red: 1, green: 0.55, blue: 0.1)
private let devInk = Color(red: 0.09, green: 0.085, blue: 0.08)

/// "Developing · Roll 004": Lock Screen banner and Dynamic Island.
struct DevelopingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DevelopingAttributes.self) { context in
            LockScreenView(context: context)
                .activityBackgroundTint(devInk)
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let end = max(context.state.developAt, Date())
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "film.stack.fill").font(.system(size: 26)).foregroundStyle(devOrange).padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if context.isStale {
                        Text("Ready").font(.system(size: 17, weight: .black, design: .rounded)).foregroundStyle(devOrange)
                    } else {
                        Text(timerInterval: Date()...end, countsDown: true).monospacedDigit().multilineTextAlignment(.trailing)
                            .font(.system(size: 17, weight: .black, design: .rounded)).foregroundStyle(devOrange).frame(width: 78, alignment: .trailing)
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.isStale ? "Roll \(String(format: "%03d", context.attributes.rollNumber)) is developed" : "Developing roll \(String(format: "%03d", context.attributes.rollNumber))")
                        .font(.system(size: 15, weight: .heavy, design: .rounded))
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if context.isStale {
                        Text("Open !Camera to load \(context.state.frames) photos.").font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
                    } else {
                        VStack(spacing: 4) {
                            ProgressView(timerInterval: context.attributes.startedAt...max(end, context.attributes.startedAt.addingTimeInterval(1)), countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
                                .tint(devOrange)
                            Text("Ready at \(context.state.developAt.formatted(date: .omitted, time: .shortened))").font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
                        }
                    }
                }
            } compactLeading: {
                Image(systemName: "film.fill").foregroundStyle(devOrange)
            } compactTrailing: {
                if context.isStale {
                    Image(systemName: "checkmark").foregroundStyle(devOrange)
                } else {
                    Text(timerInterval: Date()...end, countsDown: true).monospacedDigit().font(.system(size: 13, weight: .heavy, design: .rounded))
                        .foregroundStyle(devOrange).frame(width: 46)
                }
            } minimal: {
                Image(systemName: "film.fill").foregroundStyle(devOrange)
            }
            .widgetURL(URL(string: "notboringcamera://open"))
        }
    }
}

private struct LockScreenView: View {
    let context: ActivityViewContext<DevelopingAttributes>
    private var number: String { String(format: "%03d", context.attributes.rollNumber) }

    var body: some View {
        let end = max(context.state.developAt, Date())
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(devOrange.opacity(0.18)).frame(width: 46, height: 46)
                Image(systemName: context.isStale ? "checkmark" : "film.stack.fill").font(.system(size: 21, weight: .bold)).foregroundStyle(devOrange)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(context.isStale ? "DEVELOPED · ROLL \(number)" : "DEVELOPING · ROLL \(number)")
                    .font(.system(size: 10, weight: .heavy, design: .monospaced)).tracking(1).foregroundStyle(devOrange)
                if context.isStale {
                    Text("Your photos are ready").font(.system(size: 18, weight: .black, design: .rounded)).foregroundStyle(.white)
                    Text("Open !Camera to load \(context.state.frames) photos.").font(.system(size: 12, weight: .medium, design: .rounded)).foregroundStyle(.white.opacity(0.65))
                } else {
                    Text("Ready at \(context.state.developAt.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 18, weight: .black, design: .rounded)).foregroundStyle(.white)
                    ProgressView(timerInterval: context.attributes.startedAt...max(end, context.attributes.startedAt.addingTimeInterval(1)), countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
                        .tint(devOrange)
                }
            }
            if !context.isStale {
                Spacer(minLength: 0)
                Text(timerInterval: Date()...end, countsDown: true).monospacedDigit().multilineTextAlignment(.trailing)
                    .font(.system(size: 17, weight: .black, design: .rounded)).foregroundStyle(devOrange).frame(width: 74, alignment: .trailing)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
    }
}
