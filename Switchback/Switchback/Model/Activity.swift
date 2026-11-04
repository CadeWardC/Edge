import Foundation

struct TrackPoint: Codable, Hashable {
    var lat: Double
    var lon: Double
    var alt: Double?
    var time: Date

    var coord: Coord { Coord(lat: lat, lon: lon) }
}

/// A recorded hike.
struct Activity: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var start: Date
    var end: Date
    var segments: [[TrackPoint]]
    var distance: Double
    var movingTime: TimeInterval
    var elapsedTime: TimeInterval
    var gain: Double
    var trailId: String?
    var trailName: String?

    static func == (a: Activity, b: Activity) -> Bool {
        a.id == b.id && a.name == b.name && a.distance == b.distance
    }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    var coordSegments: [[Coord]] { segments.map { $0.map(\.coord) } }

    var bbox: BBox? { BBox(coords: segments.flatMap { $0.map(\.coord) }) }

    /// Elevation from the phone's GPS altitude, smoothed, for the chart.
    var profile: ElevationProfile? {
        let pts = segments.flatMap { $0 }
        var distances: [Double] = []
        var elevations: [Double] = []
        var total = 0.0
        var prev: TrackPoint?
        for p in pts {
            if let prev { total += Geo.distance(prev.coord, p.coord) }
            prev = p
            if let alt = p.alt {
                distances.append(total)
                elevations.append(alt)
            }
        }
        guard elevations.count >= 5 else { return nil }
        let w = 3
        let smooth = elevations.indices.map { i -> Double in
            let lo = max(0, i - w), hi = min(elevations.count - 1, i + w)
            return elevations[lo...hi].reduce(0, +) / Double(hi - lo + 1)
        }
        let step = max(1, smooth.count / 300)
        let idx = Array(stride(from: 0, to: smooth.count, by: step))
        return ElevationProfile(distances: idx.map { distances[$0] }, elevations: idx.map { smooth[$0] }, threshold: 3)
    }

    /// The hike as a trail you can follow again.
    func asTrail() -> Trail {
        let segs = coordSegments.filter { $0.count > 1 }
        let path = segs.flatMap { $0 }
        return Trail(id: "rec-\(id.uuidString)", name: name, source: .recorded, osmId: nil,
                     segments: segs, path: path, length: Geo.length(path), tags: [:], profile: profile)
    }
}
