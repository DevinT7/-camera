import ActivityKit
import Foundation
import UserNotifications

/// Starts and ends the "Developing…" Live Activity. A Live Activity can only be started while the app is open, which is
/// exactly when a roll is sealed (the last frame was just shot, or the roll was finished early).
enum RollActivity {
    /// iOS ends every Live Activity after 8 hours.
    static let maxDuration: TimeInterval = 8 * 3600

    static func start(number: Int, frames: Int, developAt: Date) {
        guard developAt.timeIntervalSinceNow <= maxDuration, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        end(number: number)
        let attrs = DevelopingAttributes(rollNumber: number, startedAt: Date())
        let state = DevelopingAttributes.ContentState(developAt: developAt, frames: frames)
        // Stale at the develop time: the Lock Screen view switches to "ready" by itself.
        _ = try? Activity.request(attributes: attrs, content: ActivityContent(state: state, staleDate: developAt), pushType: nil)
    }

    static func end(number: Int?) {
        Task {
            for a in Activity<DevelopingAttributes>.activities where number == nil || a.attributes.rollNumber == number {
                await a.end(nil, dismissalPolicy: .immediate)
            }
        }
    }
}

/// Lets a notification show as a banner even while the app is open (the "roll sealed" note arrives right after the last frame).
final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationPresenter()
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
