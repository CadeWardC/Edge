import Foundation
import SwiftUI

extension Color {
    static let trailGreen = Color(red: 0.13, green: 0.42, blue: 0.27)
}

enum Difficulty: String, Codable, CaseIterable, Identifiable, Comparable {
    case easy, moderate, hard, veryHard

    var id: String { rawValue }

    var title: String {
        switch self {
        case .easy: return "Easy"
        case .moderate: return "Moderate"
        case .hard: return "Hard"
        case .veryHard: return "Very hard"
        }
    }

    var color: Color {
        switch self {
        case .easy: return .green
        case .moderate: return .blue
        case .hard: return .red
        case .veryHard: return .purple
        }
    }

    private var rank: Int { Difficulty.allCases.firstIndex(of: self) ?? 0 }

    static func < (a: Difficulty, b: Difficulty) -> Bool { a.rank < b.rank }
}

/// Elevation along a line: distances from the start (m) and heights (m).
struct ElevationProfile: Codable, Hashable {
    var distances: [Double]
    var elevations: [Double]
    var gain: Double
    var loss: Double
    var minElevation: Double
    var maxElevation: Double

    /// `threshold` ignores wiggles smaller than that many metres when adding up the climb.
    init(distances: [Double], elevations: [Double], threshold: Double = 2) {
        self.distances = distances
        self.elevations = elevations
        var gain = 0.0, loss = 0.0
        if var ref = elevations.first {
            for e in elevations.dropFirst() {
                if e - ref >= threshold {
                    gain += e - ref
                    ref = e
                } else if ref - e >= threshold {
                    loss += ref - e
                    ref = e
                }
            }
        }
        self.gain = gain
        self.loss = loss
        minElevation = elevations.min() ?? 0
        maxElevation = elevations.max() ?? 0
    }
}

struct TrailFact: Hashable {
    let title: String
    let value: String
}

struct Trail: Codable, Identifiable, Hashable {
    enum Source: String, Codable {
        case osmRelation, osmWay, imported, recorded, usfs
    }

    var id: String
    var name: String
    var source: Source
    var osmId: Int64?
    /// Every line of the trail, as drawn on the map.
    var segments: [[Coord]]
    /// The main continuous line: used for the length, the elevation profile and navigation.
    var path: [Coord]
    var length: Double
    var tags: [String: String]
    var profile: ElevationProfile?

    static func == (a: Trail, b: Trail) -> Bool {
        a.id == b.id && a.name == b.name && a.profile == b.profile
    }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    var start: Coord { path.first ?? segments.first?.first ?? Coord(lat: 0, lon: 0) }

    var bbox: BBox {
        BBox(coords: segments.flatMap { $0 }) ?? BBox(south: start.lat, west: start.lon, north: start.lat, east: start.lon)
    }

    var isLoop: Bool {
        guard let f = path.first, let l = path.last, length > 500 else { return false }
        return Geo.distance(f, l) < max(150, length * 0.03)
    }

    var routeTypeTitle: String { isLoop ? "Loop" : "One way" }

    var difficulty: Difficulty {
        let km = length / 1000
        let effort = km + (profile?.gain ?? 0) / 100
        var level: Difficulty = effort < 8 ? .easy : effort < 16 ? .moderate : effort < 26 ? .hard : .veryHard
        // Forest Service class 1 (minimally developed) trails are rough going
        if tags["usfs:trail_class"]?.filter(\.isNumber) == "1" { level = max(level, .moderate) }
        switch tags["sac_scale"] {
        case "mountain_hiking": level = max(level, .moderate)
        case "demanding_mountain_hiking": level = max(level, .hard)
        case "alpine_hiking", "demanding_alpine_hiking", "difficult_alpine_hiking": level = .veryHard
        default: break
        }
        return level
    }

    /// Naismith's rule at an easy pace: 4.5 km/h plus an hour for every 600 m of climb.
    var estimatedDuration: TimeInterval {
        (length / 1000 / 4.5 + (profile?.gain ?? 0) / 600) * 3600
    }

    var osmURL: URL? {
        guard let osmId else { return nil }
        switch source {
        case .osmRelation: return URL(string: "https://www.openstreetmap.org/relation/\(osmId)")
        case .osmWay: return URL(string: "https://www.openstreetmap.org/way/\(osmId)")
        default: return nil
        }
    }

    var summary: String? { tags["description"] ?? tags["description:en"] ?? tags["note"] }

    /// Facts from the OpenStreetMap tags worth showing, in a friendly form.
    var facts: [TrailFact] {
        var out: [TrailFact] = []
        if let from = tags["from"], let to = tags["to"] { out.append(TrailFact(title: "Route", value: "\(from) → \(to)")) }
        if let network = tags["network"] {
            let names = ["lwn": "Local", "rwn": "Regional", "nwn": "National", "iwn": "International"]
            out.append(TrailFact(title: "Network", value: names[network] ?? network))
        }
        if let op = tags["operator"] { out.append(TrailFact(title: "Managed by", value: op)) }
        if let sac = tags["sac_scale"] {
            let names = [
                "hiking": "T1 · Hiking",
                "mountain_hiking": "T2 · Mountain hiking",
                "demanding_mountain_hiking": "T3 · Demanding mountain hiking",
                "alpine_hiking": "T4 · Alpine hiking",
                "demanding_alpine_hiking": "T5 · Demanding alpine hiking",
                "difficult_alpine_hiking": "T6 · Difficult alpine hiking",
            ]
            out.append(TrailFact(title: "SAC scale", value: names[sac] ?? sac))
        }
        if let surface = tags["surface"] { out.append(TrailFact(title: "Surface", value: surface.replacingOccurrences(of: "_", with: " ").capitalized)) }
        if let vis = tags["trail_visibility"] { out.append(TrailFact(title: "Trail visibility", value: vis.capitalized)) }
        if let ref = tags["ref"] { out.append(TrailFact(title: "Ref", value: ref)) }
        if let symbol = tags["symbol"] { out.append(TrailFact(title: "Waymarks", value: symbol)) }
        if let cls = tags["usfs:trail_class"] {
            let digits = cls.filter(\.isNumber)
            let names = ["1": "TC1 · Minimally developed", "2": "TC2 · Moderately developed", "3": "TC3 · Developed",
                         "4": "TC4 · Highly developed", "5": "TC5 · Fully developed"]
            out.append(TrailFact(title: "Forest Service class", value: names[digits] ?? cls))
        }
        if let surface = tags["usfs:surface"], tags["surface"] == nil {
            out.append(TrailFact(title: "Surface", value: surface.replacingOccurrences(of: "_", with: " ").capitalized))
        }
        if let grade = tags["usfs:grade"] { out.append(TrailFact(title: "Typical grade", value: grade)) }
        if let nat = tags["usfs:national"] { out.append(TrailFact(title: "National designation", value: nat.capitalized)) }
        if let dogs = tags["dog"] { out.append(TrailFact(title: "Dogs", value: dogs.capitalized)) }
        return out
    }

    var website: URL? {
        (tags["website"] ?? tags["url"]).flatMap { URL(string: $0) }
    }
}
