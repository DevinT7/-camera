import ActivityKit
import Foundation

/// Live Activity shown on the Lock Screen and in the Dynamic Island while a sealed roll develops.
/// iOS keeps a Live Activity for at most 8 hours, so it is only used for development times of 8 hours or less.
struct DevelopingAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var developAt: Date
        var frames: Int
    }
    var rollNumber: Int
    var startedAt: Date
}
