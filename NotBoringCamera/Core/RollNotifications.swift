import Foundation
import UserNotifications

/// Local notification for when a film roll is ready. The photos are written into the library the next time the app opens
/// (the notification takes you there), so the wording says "ready", not "saved".
enum RollNotifications {
    private static var center: UNUserNotificationCenter { .current() }
    private static func id(_ roll: UUID) -> String { "roll-\(roll.uuidString)" }

    static func requestIfNeeded() {
        center.getNotificationSettings { s in
            guard s.authorizationStatus == .notDetermined else { return }
            center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        }
    }

    /// (Re)schedules the roll's notification; each new frame pushes it back, because the roll develops 24h after its last frame.
    static func schedule(rollID: UUID, at date: Date, frames: Int) {
        let c = UNMutableNotificationContent()
        c.title = "Your roll is developed"
        c.body = "\(frames) \(frames == 1 ? "photo is" : "photos are") ready. Open !Camera to load \(frames == 1 ? "it" : "them") into your library."
        c.sound = .default
        let interval = max(date.timeIntervalSinceNow, 5)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        center.add(UNNotificationRequest(identifier: id(rollID), content: c, trigger: trigger))
    }

    static func cancel(rollID: UUID) {
        center.removePendingNotificationRequests(withIdentifiers: [id(rollID)])
        center.removeDeliveredNotifications(withIdentifiers: [id(rollID)])
    }
}
