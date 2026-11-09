import Foundation

/// A JSON value of any type (ArcGIS returns attributes as strings, numbers or null).
enum JSONValue: Decodable {
    case string(String), number(Double), bool(Bool), null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let d = try? c.decode(Double.self) {
            self = .number(d)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else {
            self = .null
        }
    }

    var text: String? {
        switch self {
        case .string(let s):
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        case .number(let d):
            return d == d.rounded() && abs(d) < 1e15 ? String(Int(d)) : String(d)
        case .bool(let b):
            return b ? "yes" : "no"
        case .null:
            return nil
        }
    }
}

/// U.S. Forest Service National Forest System trails (public domain), from the Forest Service's
/// Enterprise Data Warehouse map service.
enum USFS {
    static let queryURL = "https://apps.fs.usda.gov/arcx/rest/services/EDW/EDW_TrailNFSPublish_01/MapServer/0/query"
    static let enabledKey = "usfsTrails"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    /// Rough outline of the US (lower 48, Alaska, Hawaii, Puerto Rico), so other countries never ask.
    private static let usBoxes = [
        BBox(south: 24, west: -125, north: 49.5, east: -66),
        BBox(south: 51, west: -170, north: 71.5, east: -129),
        BBox(south: 18.5, west: -161, north: 22.5, east: -154),
        BBox(south: 17.5, west: -68, north: 18.6, east: -65),
    ]

    static func covers(_ box: BBox) -> Bool { usBoxes.contains { $0.intersects(box) } }

    /// Forest Service trails in the box; an empty list (never an error) when it's off, outside the US, or unreachable.
    static func trailsIfAvailable(in box: BBox) async -> [Trail] {
        guard isEnabled, covers(box) else { return [] }
        return (try? await trails(in: box)) ?? []
    }

    // MARK: Fetching

    private struct FeatureCollection: Decodable {
        let features: [Feature]?
        let exceededTransferLimit: Bool?
        let properties: [String: JSONValue]?
    }

    private struct Feature: Decodable {
        let geometry: Geometry?
        let properties: [String: JSONValue]?
    }

    private struct Geometry: Decodable {
        let lines: [[Coord]]

        private enum Keys: String, CodingKey { case type, coordinates }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            let type = (try? c.decode(String.self, forKey: .type)) ?? ""
            func coords(_ raw: [[Double]]) -> [Coord] {
                raw.compactMap { $0.count >= 2 ? Coord(lat: $0[1], lon: $0[0]) : nil }
            }
            switch type {
            case "LineString":
                lines = [coords((try? c.decode([[Double]].self, forKey: .coordinates)) ?? [])]
            case "MultiLineString":
                lines = ((try? c.decode([[[Double]]].self, forKey: .coordinates)) ?? []).map(coords)
            default:
                lines = []
            }
        }
    }

    static func trails(in box: BBox) async throws -> [Trail] {
        let pageSize = 1000
        var features: [Feature] = []
        for page in 0..<4 {
            var c = URLComponents(string: queryURL)!
            c.queryItems = [
                URLQueryItem(name: "where", value: "1=1"),
                URLQueryItem(name: "geometry", value: String(format: "%.5f,%.5f,%.5f,%.5f", box.west, box.south, box.east, box.north)),
                URLQueryItem(name: "geometryType", value: "esriGeometryEnvelope"),
                URLQueryItem(name: "inSR", value: "4326"),
                URLQueryItem(name: "outSR", value: "4326"),
                URLQueryItem(name: "spatialRel", value: "esriSpatialRelIntersects"),
                URLQueryItem(name: "outFields", value: "*"),
                URLQueryItem(name: "returnGeometry", value: "true"),
                URLQueryItem(name: "maxAllowableOffset", value: "0.00003"),
                URLQueryItem(name: "geometryPrecision", value: "6"),
                URLQueryItem(name: "resultOffset", value: String(page * pageSize)),
                URLQueryItem(name: "resultRecordCount", value: String(pageSize)),
                URLQueryItem(name: "f", value: "geojson"),
            ]
            guard let url = c.url else { throw URLError(.badURL) }
            var req = URLRequest(url: url, timeoutInterval: 25)
            req.setValue(Net.userAgent, forHTTPHeaderField: "User-Agent")
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            let fc = try JSONDecoder().decode(FeatureCollection.self, from: data)
            let got = fc.features ?? []
            features.append(contentsOf: got)
            var more = fc.exceededTransferLimit ?? false
            if case .bool(let b)? = fc.properties?["exceededTransferLimit"] { more = more || b }
            if got.count < pageSize && !more { break }
        }
        return try await Task.detached(priority: .userInitiated) { USFS.build(features) }.value
    }

    /// Joins a trail's segments and turns them into trails.
    private static func build(_ features: [Feature]) -> [Trail] {
        var groups: [String: (name: String, tags: [String: String], pieces: [[Coord]])] = [:]
        for f in features {
            var attrs: [String: String] = [:]
            for (k, v) in f.properties ?? [:] {
                if let t = v.text { attrs[k.uppercased()] = t }
            }
            // land trails only (not snow or water trails)
            if let type = attrs["TRAIL_TYPE"], type.uppercased() != "TERRA" { continue }
            let number = attrs["TRAIL_NO"] ?? ""
            let rawName = attrs["TRAIL_NAME"] ?? ""
            guard !rawName.isEmpty || !number.isEmpty else { continue }
            let name = rawName.isEmpty ? "Trail \(number)" : prettify(rawName)
            let key = number.isEmpty ? name.lowercased() : number + "|" + name.lowercased()
            var tags = groups[key]?.tags ?? [:]
            if tags.isEmpty {
                if !number.isEmpty { tags["ref"] = number }
                if let cls = attrs["TRAIL_CLASS"] { tags["usfs:trail_class"] = cls }
                if let org = attrs["MANAGING_ORG"] ?? attrs["ADMIN_ORG"] { tags["operator"] = org }
                if let surface = attrs["TRAIL_SURFACE"] { tags["usfs:surface"] = surface }
                if let grade = attrs["TYPICAL_TRAIL_GRADE"] { tags["usfs:grade"] = grade }
                if let nat = attrs["NATIONAL_TRAIL_DESIGNATION"], nat != "0" { tags["usfs:national"] = nat }
                if let allowed = attrs["ALLOWED_TERRA_USE"] { tags["usfs:allowed"] = allowed }
            }
            let pieces = (f.geometry?.lines ?? []).filter { $0.count > 1 }
            groups[key] = (name: name, tags: tags, pieces: (groups[key]?.pieces ?? []) + pieces)
        }

        var trails: [Trail] = []
        for (key, g) in groups {
            let chains = Chains.build(g.pieces).map { (coords: $0, length: Geo.length($0)) }
            guard let main = chains.max(by: { $0.length < $1.length }), main.length >= 300,
                  let first = main.coords.first else { continue }
            let id = String(format: "usfs-%@-%.3f,%.3f", key, first.lat, first.lon)
            trails.append(Trail(id: id, name: g.name, source: .usfs, osmId: nil,
                                segments: chains.filter { $0.length >= 30 }.map { Geo.simplify($0.coords, tolerance: 3) },
                                path: Geo.simplify(main.coords, tolerance: 3), length: main.length,
                                tags: g.tags, profile: nil))
        }
        return trails
    }

    /// "BEAR CREEK" → "Bear Creek".
    private static func prettify(_ s: String) -> String {
        s == s.uppercased() ? s.capitalized : s
    }

    /// A name with "trail", "#123" and punctuation removed, for spotting the same trail in OpenStreetMap.
    static func normalized(_ name: String) -> String {
        let lowered = name.lowercased()
        let words = lowered.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && !["trail", "tr", "trl", "path", "the", "no", "nfst", "national", "recreation"].contains($0) }
            .filter { Int($0) == nil }
        return words.joined(separator: " ")
    }
}

/// Every trail source, combined.
enum TrailSources {
    /// Everything at once (for offline downloads).
    static func trails(in box: BBox) async throws -> [Trail] {
        async let forest = USFS.trailsIfAvailable(in: box)
        let osm = try await Overpass.trails(in: box)
        return merge(osm: osm, forest: await forest)
    }

    /// The quick first pass: routes, named paths and tracks.
    static func main(in box: BBox) async throws -> [Trail] {
        try await Overpass.trails(in: box, part: .main)
    }

    /// The slower second pass, added once the main trails are showing: unnamed paths and Forest Service trails.
    /// Returns the main trails (with any Forest Service details folded in) plus the new ones. Never throws.
    static func withExtras(in box: BBox, main: [Trail]) async -> [Trail] {
        async let forest = USFS.trailsIfAvailable(in: box)
        let unnamed = (try? await Overpass.trails(in: box, part: .unnamed)) ?? []
        let combined = main + dropDuplicates(unnamed, against: main)
        return merge(osm: combined, forest: await forest)
    }

    /// Unnamed pieces that just retrace a named trail (fetched separately, so not caught while parsing).
    static func dropDuplicates(_ unnamed: [Trail], against named: [Trail]) -> [Trail] {
        let boxes = named.map { ($0, $0.bbox.expanded(byDegrees: 0.0005)) }
        return unnamed.filter { u in
            let near = boxes.filter { $0.1.intersects(u.bbox) }.map(\.0)
            guard !near.isEmpty else { return true }
            let samples = Geo.resample(u.path, count: 5).map(\.coord)
            let covered = samples.filter { c in near.contains { Geo.distanceToPath(c, segments: $0.segments) < 15 } }
            return covered.count < 4
        }
    }

    /// Forest Service trails that are already in OpenStreetMap are folded into the OSM trail (adding the
    /// official details); the rest are added as their own trails.
    static func merge(osm: [Trail], forest: [Trail]) -> [Trail] {
        guard !forest.isEmpty else { return osm }
        var out = osm
        var index: [String: [Int]] = [:]
        for (i, t) in osm.enumerated() {
            let n = USFS.normalized(t.name)
            if !n.isEmpty { index[n, default: []].append(i) }
            if let ref = t.tags["ref"] { index["#" + ref.lowercased(), default: []].append(i) }
        }
        for f in forest {
            var keys: [String] = []
            let n = USFS.normalized(f.name)
            if !n.isEmpty { keys.append(n) }
            if let ref = f.tags["ref"] { keys.append("#" + ref.lowercased()) }
            let box = f.bbox.expanded(byDegrees: 0.005)
            var match: Int?
            for k in keys {
                if let i = (index[k] ?? []).first(where: { out[$0].bbox.intersects(box) }) {
                    match = i
                    break
                }
            }
            if let i = match {
                for (k, v) in f.tags where out[i].tags[k] == nil { out[i].tags[k] = v }
            } else {
                out.append(f)
            }
        }
        return out
    }
}
