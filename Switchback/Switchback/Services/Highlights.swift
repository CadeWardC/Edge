import Foundation

enum POIKind: String, Codable, CaseIterable {
    case viewpoint, peak, waterfall, water, lake, cave, shelter, campsite, picnic, toilets, parking

    var title: String {
        switch self {
        case .viewpoint: return "Viewpoint"
        case .peak: return "Peak"
        case .waterfall: return "Waterfall"
        case .water: return "Water"
        case .lake: return "Lake"
        case .cave: return "Cave"
        case .shelter: return "Shelter"
        case .campsite: return "Campsite"
        case .picnic: return "Picnic area"
        case .toilets: return "Toilets"
        case .parking: return "Parking"
        }
    }

    var symbol: String {
        switch self {
        case .viewpoint: return "binoculars.fill"
        case .peak: return "mountain.2.fill"
        case .waterfall: return "water.waves"
        case .water: return "drop.fill"
        case .lake: return "drop.circle.fill"
        case .cave: return "mountain.2"
        case .shelter: return "house.fill"
        case .campsite: return "tent.fill"
        case .picnic: return "fork.knife"
        case .toilets: return "toilet.fill"
        case .parking: return "car.fill"
        }
    }

    /// Sights worth mentioning in a trail's summary (rather than facilities).
    var isSight: Bool { [.viewpoint, .peak, .waterfall, .lake, .cave].contains(self) }
}

/// A point of interest along a trail, from OpenStreetMap.
struct TrailPOI: Codable, Hashable, Identifiable {
    var id: String
    var kind: POIKind
    var name: String?
    var lat: Double
    var lon: Double
    /// Distance along the trail from its start, in metres.
    var along: Double
    var elevation: Double?
    var commons: String?
    var wikidata: String?

    var coord: Coord { Coord(lat: lat, lon: lon) }
    var displayName: String { name ?? kind.title }
}

/// Viewpoints, peaks, water, shelters and the like along each trail, kept in Application Support so they're
/// there offline.
@MainActor
final class Highlights: ObservableObject {
    static let shared = Highlights()

    @Published private(set) var byId: [String: [TrailPOI]] = [:]
    private var inFlight = Set<String>()
    private let url = Files.support.appendingPathComponent("trail-highlights.json")

    init() {
        byId = Files.load([String: [TrailPOI]].self, from: url) ?? [:]
    }

    func pois(for id: String) -> [TrailPOI]? { byId[id] }

    func isLoading(_ id: String) -> Bool { inFlight.contains(id) }

    @discardableResult
    func ensure(for trail: Trail) async -> [TrailPOI] {
        if let p = byId[trail.id] { return p }
        guard !inFlight.contains(trail.id), trail.path.count > 1 else { return [] }
        inFlight.insert(trail.id)
        objectWillChange.send()
        defer {
            inFlight.remove(trail.id)
            objectWillChange.send()
        }
        guard let found = try? await HighlightsFetcher.fetch(for: trail) else { return [] }
        byId[trail.id] = found
        if byId.count > 2000 { byId = Dictionary(uniqueKeysWithValues: byId.suffix(1500).map { ($0.key, $0.value) }) }
        Files.save(byId, to: url)
        return found
    }
}

enum HighlightsFetcher {
    private struct Response: Decodable { let elements: [Element] }

    private struct Element: Decodable {
        let type: String
        let id: Int64
        let lat: Double?
        let lon: Double?
        let center: LatLon?
        let tags: [String: String]?
    }

    private struct LatLon: Decodable {
        let lat: Double
        let lon: Double
    }

    static func fetch(for trail: Trail) async throws -> [TrailPOI] {
        // a lighter copy of the line keeps the query short
        var line = Geo.simplify(trail.path, tolerance: 25)
        if line.count > 120 {
            let step = Double(line.count - 1) / 119
            line = (0..<120).map { line[Int((Double($0) * step).rounded())] }
        }
        let coords = line.map { String(format: "%.5f,%.5f", $0.lat, $0.lon) }.joined(separator: ",")
        let start = String(format: "%.5f,%.5f", trail.start.lat, trail.start.lon)
        let query = """
        [out:json][timeout:25];
        (
          node(around:120,\(coords))["tourism"~"^(viewpoint|alpine_hut|wilderness_hut|camp_site|picnic_site)$"];
          node(around:120,\(coords))["natural"~"^(peak|volcano|spring|cave_entrance)$"];
          node(around:120,\(coords))["waterway"="waterfall"];
          node(around:120,\(coords))["amenity"~"^(drinking_water|water_point|toilets|shelter)$"];
          nwr(around:250,\(start))["amenity"="parking"];
          way(around:60,\(coords))["natural"="water"]["name"];
          relation(around:60,\(coords))["natural"="water"]["name"];
        );
        out center tags;
        """
        let data = try await Overpass.run(query)
        let elements = try JSONDecoder().decode(Response.self, from: data).elements
        let cum = Geo.cumulative(trail.path)

        var out: [TrailPOI] = []
        for e in elements {
            guard let tags = e.tags, let kind = kind(for: tags) else { continue }
            guard let lat = e.lat ?? e.center?.lat, let lon = e.lon ?? e.center?.lon else { continue }
            let c = Coord(lat: lat, lon: lon)
            guard let located = Geo.locate(c, on: trail.path, cumulative: cum) else { continue }
            if kind != .lake && kind != .parking && located.offset > 200 { continue }
            out.append(TrailPOI(id: "\(e.type)\(e.id)", kind: kind, name: tags["name"], lat: lat, lon: lon,
                                along: located.along, elevation: tags["ele"].flatMap { Double($0.split(separator: " ").first ?? "") },
                                commons: tags["wikimedia_commons"], wikidata: tags["wikidata"]))
        }
        // one or two parking spots are plenty
        let parking = out.filter { $0.kind == .parking }.sorted { Geo.distance($0.coord, trail.start) < Geo.distance($1.coord, trail.start) }
        out.removeAll { $0.kind == .parking }
        out.append(contentsOf: parking.prefix(2))
        return out.sorted { $0.along < $1.along }
    }

    private static func kind(for t: [String: String]) -> POIKind? {
        switch t["tourism"] {
        case "viewpoint": return .viewpoint
        case "alpine_hut", "wilderness_hut": return .shelter
        case "camp_site": return .campsite
        case "picnic_site": return .picnic
        default: break
        }
        switch t["natural"] {
        case "peak", "volcano": return .peak
        case "spring": return .water
        case "cave_entrance": return .cave
        case "water": return .lake
        default: break
        }
        if t["waterway"] == "waterfall" { return .waterfall }
        switch t["amenity"] {
        case "drinking_water", "water_point": return .water
        case "toilets": return .toilets
        case "shelter": return .shelter
        case "parking": return .parking
        default: return nil
        }
    }
}
