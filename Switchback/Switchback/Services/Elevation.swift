import Combine
import Foundation

/// Heights from Open-Meteo's free elevation API (Copernicus 90 m terrain model).
enum Elevation {
    static func profile(for path: [Coord]) async throws -> ElevationProfile {
        let length = Geo.length(path)
        let n = max(2, min(100, Int(length / 40) + 2))
        let samples = Geo.resample(path, count: n)
        let heights = try await fetch(samples.map(\.coord))
        return ElevationProfile(distances: samples.map(\.distance), elevations: heights)
    }

    private struct Response: Decodable { let elevation: [Double?] }

    static func fetch(_ coords: [Coord]) async throws -> [Double] {
        var raw: [Double?] = []
        for start in stride(from: 0, to: coords.count, by: 100) {
            let chunk = Array(coords[start..<min(coords.count, start + 100)])
            var c = URLComponents(string: "https://api.open-meteo.com/v1/elevation")!
            c.queryItems = [
                URLQueryItem(name: "latitude", value: chunk.map { String(format: "%.5f", $0.lat) }.joined(separator: ",")),
                URLQueryItem(name: "longitude", value: chunk.map { String(format: "%.5f", $0.lon) }.joined(separator: ",")),
            ]
            guard let url = c.url else { throw URLError(.badURL) }
            var req = URLRequest(url: url, timeoutInterval: 30)
            req.setValue(Net.userAgent, forHTTPHeaderField: "User-Agent")
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            raw.append(contentsOf: try JSONDecoder().decode(Response.self, from: data).elevation)
        }
        // fill any gaps with the nearest known height
        guard let firstKnown = raw.compactMap({ $0 }).first else { throw URLError(.cannotParseResponse) }
        var last = firstKnown
        return raw.map { v in
            if let v { last = v }
            return last
        }
    }
}

/// Elevation profiles for trails, fetched once and kept on disk.
@MainActor
final class Profiles: ObservableObject {
    static let shared = Profiles()

    @Published private(set) var byId: [String: ElevationProfile] = [:]
    private var inFlight = Set<String>()
    private var saveScheduled = false
    private let url = Files.caches.appendingPathComponent("elevation-profiles.json")

    init() {
        byId = Files.load([String: ElevationProfile].self, from: url) ?? [:]
    }

    func profile(for trail: Trail) -> ElevationProfile? { trail.profile ?? byId[trail.id] }

    func withProfile(_ trail: Trail) -> Trail {
        guard trail.profile == nil, let p = byId[trail.id] else { return trail }
        var t = trail
        t.profile = p
        return t
    }

    func isLoading(_ trail: Trail) -> Bool { inFlight.contains(trail.id) }

    @discardableResult
    func ensureProfile(for trail: Trail) async -> ElevationProfile? {
        if let p = profile(for: trail) { return p }
        guard !inFlight.contains(trail.id), trail.path.count > 1 else { return nil }
        inFlight.insert(trail.id)
        objectWillChange.send()
        defer {
            inFlight.remove(trail.id)
            objectWillChange.send()
        }
        do {
            let p = try await Elevation.profile(for: trail.path)
            byId[trail.id] = p
            Library.shared.updateProfile(p, for: trail.id)
            scheduleSave()
            return p
        } catch {
            return nil
        }
    }

    /// Fetches profiles for many trails, three at a time.
    func enrich(_ trails: [Trail]) async {
        let todo = trails.filter { profile(for: $0) == nil }
        guard !todo.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            var next = 0
            for _ in 0..<min(3, todo.count) {
                let t = todo[next]
                next += 1
                group.addTask { await self.ensureProfile(for: t) }
            }
            while await group.next() != nil {
                if Task.isCancelled { break }
                if next < todo.count {
                    let t = todo[next]
                    next += 1
                    group.addTask { await self.ensureProfile(for: t) }
                }
            }
        }
    }

    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            saveScheduled = false
            // keep the cache from growing forever
            if byId.count > 3000 { byId = Dictionary(uniqueKeysWithValues: byId.suffix(2000).map { ($0.key, $0.value) }) }
            Files.save(byId, to: url)
        }
    }
}
