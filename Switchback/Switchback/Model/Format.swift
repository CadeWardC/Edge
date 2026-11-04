import Foundation

enum Units: String, CaseIterable, Identifiable {
    case imperial, metric

    static let storageKey = "units"

    var id: String { rawValue }

    var title: String { self == .imperial ? "Miles & feet" : "Kilometres & metres" }

    static var systemDefault: Units {
        Locale.current.measurementSystem == .metric ? .metric : .imperial
    }

    static var current: Units {
        UserDefaults.standard.string(forKey: storageKey).flatMap(Units.init(rawValue:)) ?? systemDefault
    }
}

enum Fmt {
    static let metersPerMile = 1609.344
    static let feetPerMeter = 3.28084

    static var distanceUnit: String { Units.current == .imperial ? "mi" : "km" }
    static var elevationUnit: String { Units.current == .imperial ? "ft" : "m" }

    static func displayDistance(_ m: Double) -> Double {
        Units.current == .imperial ? m / metersPerMile : m / 1000
    }

    static func displayElevation(_ m: Double) -> Double {
        Units.current == .imperial ? m * feetPerMeter : m
    }

    static func distance(_ m: Double) -> String {
        let v = displayDistance(m)
        return String(format: v < 10 ? "%.1f %@" : "%.0f %@", v, distanceUnit)
    }

    /// Short distances in feet or metres.
    static func shortDistance(_ m: Double) -> String {
        if Units.current == .imperial {
            let ft = m * feetPerMeter
            return ft < 1000 ? "\(Int(ft.rounded())) ft" : distance(m)
        }
        return m < 1000 ? "\(Int(m.rounded())) m" : distance(m)
    }

    static func elevation(_ m: Double) -> String {
        "\(Int(displayElevation(m).rounded()).formatted()) \(elevationUnit)"
    }

    static func duration(_ s: TimeInterval) -> String {
        let mins = max(0, Int((s / 60).rounded()))
        let h = mins / 60, m = mins % 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }

    static func clock(_ s: TimeInterval) -> String {
        let t = max(0, Int(s))
        return String(format: "%d:%02d:%02d", t / 3600, (t / 60) % 60, t % 60)
    }

    static func pace(distance: Double, time: TimeInterval) -> String {
        guard distance > 30, time > 0 else { return "–" }
        let unit = Units.current == .imperial ? metersPerMile : 1000
        let secs = Int(time / (distance / unit))
        guard secs < 100 * 60 else { return "–" }
        return String(format: "%d:%02d /%@", secs / 60, secs % 60, distanceUnit)
    }
}
