import Foundation

enum Net {
    static let userAgent = "Switchback/1.0 (iOS hiking app; https://github.com/cadewardc/edge)"
}

enum Files {
    static var support: URL {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    static var caches: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    }

    static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static func save<T: Encodable>(_ value: T, to url: URL) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(value).write(to: url, options: .atomic)
        } catch {
            print("Couldn't save \(url.lastPathComponent): \(error)")
        }
    }

    static func directorySize(_ url: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in e {
            total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}

enum OverpassError: LocalizedError {
    case status(Int)

    var errorDescription: String? {
        switch self {
        case .status(429): return "The trail server is busy. Try again in a minute."
        case .status(let code): return "The trail server answered with error \(code)."
        }
    }
}

/// Finds hiking trails in OpenStreetMap through the Overpass API.
enum Overpass {
    static let endpoints = [
        "https://overpass-api.de/api/interpreter",
        "https://overpass.private.coffee/api/interpreter",
        "https://maps.mail.ru/osm/tools/overpass/api/interpreter",
    ].compactMap(URL.init(string:))

    static func trails(in box: BBox) async throws -> [Trail] {
        let b = box.overpass
        let query = """
        [out:json][timeout:30];
        (
          relation["type"="route"]["route"~"^(hiking|foot|walking)$"](\(b));
          way["highway"~"^(path|footway|bridleway)$"]["name"]["footway"!~"^(sidewalk|crossing)$"]["access"!~"^(private|no)$"](\(b));
        );
        out geom(\(b));
        """
        let body = "data=" + (query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")
        var lastError: Error = URLError(.cannotConnectToHost)
        for url in endpoints {
            do {
                var req = URLRequest(url: url, timeoutInterval: 45)
                req.httpMethod = "POST"
                req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                req.setValue(Net.userAgent, forHTTPHeaderField: "User-Agent")
                req.httpBody = body.data(using: .utf8)
                let (data, resp) = try await URLSession.shared.data(for: req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                guard code == 200 else { throw OverpassError.status(code) }
                return try await Task.detached(priority: .userInitiated) { try Overpass.parse(data) }.value
            } catch {
                if error is CancellationError || (error as? URLError)?.code == .cancelled { throw error }
                lastError = error
            }
        }
        throw lastError
    }

    // MARK: - Parsing

    private struct Response: Decodable { let elements: [Element] }

    private struct Element: Decodable {
        let type: String
        let id: Int64
        let tags: [String: String]?
        let geometry: [LatLon?]?
        let members: [Member]?
    }

    private struct Member: Decodable {
        let type: String
        let role: String?
        let geometry: [LatLon?]?
    }

    private struct LatLon: Decodable {
        let lat: Double
        let lon: Double
    }

    /// Breaks a way's points into runs, splitting where points outside the search box were left out.
    private static func runs(_ geometry: [LatLon?]?) -> [[Coord]] {
        var out: [[Coord]] = []
        var current: [Coord] = []
        for p in geometry ?? [] {
            if let p {
                current.append(Coord(lat: p.lat, lon: p.lon))
            } else if !current.isEmpty {
                out.append(current)
                current = []
            }
        }
        if !current.isEmpty { out.append(current) }
        return out.filter { $0.count > 1 }
    }

    private static let skippedRoles: Set<String> = ["alternative", "excursion", "approach", "connection", "link"]

    static func parse(_ data: Data) throws -> [Trail] {
        let response = try JSONDecoder().decode(Response.self, from: data)
        var trails: [Trail] = []
        var relationNames = Set<String>()

        for e in response.elements where e.type == "relation" {
            let tags = e.tags ?? [:]
            var pieces: [[Coord]] = []
            for m in e.members ?? [] where m.type == "way" && !skippedRoles.contains(m.role ?? "") {
                pieces.append(contentsOf: runs(m.geometry))
            }
            let name = tags["name"] ?? tags["name:en"] ?? tags["ref"].map { "Route \($0)" } ?? "Unnamed route"
            if let trail = makeTrail(id: "r\(e.id)", osmId: e.id, source: .osmRelation, name: name,
                                     chains: Chains.build(pieces), tags: tags, minLength: 300) {
                trails.append(trail)
                relationNames.insert(name.lowercased())
            }
        }

        // Named paths that aren't part of a route: join the pieces that share a name.
        var byName: [String: [(id: Int64, coords: [Coord], tags: [String: String])]] = [:]
        for e in response.elements where e.type == "way" {
            guard let tags = e.tags, let name = tags["name"], !relationNames.contains(name.lowercased()) else { continue }
            for run in runs(e.geometry) {
                byName[name, default: []].append((id: e.id, coords: run, tags: tags))
            }
        }
        for (name, ways) in byName {
            let chains = Chains.build(ways.map(\.coords))
            for chain in chains {
                guard let first = chain.first else { continue }
                let id = String(format: "w%@-%.3f,%.3f", name, first.lat, first.lon)
                let owner = ways.first { w in w.coords.contains { Chains.near($0, first) } } ?? ways[0]
                if let trail = makeTrail(id: id, osmId: owner.id, source: .osmWay, name: name,
                                         chains: [chain], tags: owner.tags, minLength: 400) {
                    trails.append(trail)
                }
            }
        }
        return trails
    }

    private static func makeTrail(id: String, osmId: Int64, source: Trail.Source, name: String,
                                  chains: [[Coord]], tags: [String: String], minLength: Double) -> Trail? {
        let measured = chains.map { (coords: $0, length: Geo.length($0)) }
        guard let main = measured.max(by: { $0.length < $1.length }), main.length >= minLength else { return nil }
        let segments = measured.filter { $0.length >= 30 }.map(\.coords)
        return Trail(id: id, name: name, source: source, osmId: osmId, segments: segments,
                     path: main.coords, length: main.length, tags: tags, profile: nil)
    }
}
