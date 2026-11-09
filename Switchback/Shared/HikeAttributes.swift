import ActivityKit
import Foundation

/// What the lock-screen / Dynamic Island Live Activity shows during a hike (shared by the app and the widget).
struct HikeAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var distance: Double
        var gain: Double
        var remaining: Double?
        /// Now minus the time hiked, so a running timer counts up from it.
        var timerStart: Date
        /// The time hiked when paused (the timer stops).
        var pausedElapsed: Double?
        var offTrail: Bool
        var imperial: Bool
    }

    var trailName: String?
}

enum HikeFormat {
    static func distance(_ m: Double, imperial: Bool) -> String {
        let v = imperial ? m / 1609.344 : m / 1000
        return String(format: v < 10 ? "%.1f %@" : "%.0f %@", v, imperial ? "mi" : "km")
    }

    static func elevation(_ m: Double, imperial: Bool) -> String {
        imperial ? "\(Int((m * 3.28084).rounded())) ft" : "\(Int(m.rounded())) m"
    }

    static func clock(_ s: Double) -> String {
        let t = max(0, Int(s))
        return String(format: "%d:%02d:%02d", t / 3600, (t / 60) % 60, t % 60)
    }
}
