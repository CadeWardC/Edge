import Foundation

/// Lightweight trail packs: each state's trails, pre-built weekly from OpenStreetMap (scripts/build_trail_pack.py) and
/// split into small compressed files per 0.25° cell (about 25 km). The app downloads only the cells around where you
/// look, once, and keeps them; wherever a pack exists, trails load instantly and need no live search.
actor TrailPacks {
    static let shared = TrailPacks()

    /// Used until the list of regions has been downloaded once.
    private static let fallbackRegions: [String: BBox] = [
        "missouri": BBox(south: 35.99, west: -95.78, north: 40.62, east: -89.09),
    ]

    private struct RegionList: Codable {
        struct Region: Codable { let bbox: [Double] }
        let regions: [String: Region]
    }

    private struct StampedRegions: Codable {
        let checked: Date
        let regions: [String: BBox]
    }

    private var regionBoxes: [String: BBox]?
    private var regionsFailedUntil = Date.distantPast

    /// Which states have packs, and where (the release "trails-index", re-checked every few days).
    private func regions() async -> [String: BBox] {
        let file = dir.appendingPathComponent("regions.json")
        let saved = Files.load(StampedRegions.self, from: file)
        if let r = regionBoxes, let saved, Date().timeIntervalSince(saved.checked) < 3 * 86400 { return r }
        if let saved, Date().timeIntervalSince(saved.checked) < 3 * 86400 {
            regionBoxes = saved.regions
            return saved.regions
        }
        if regionsFailedUntil > Date() { return regionBoxes ?? saved?.regions ?? Self.fallbackRegions }
        do {
            let data = try await Self.get("https://github.com/CadeWardC/Edge/releases/download/trails-index/regions.json")
            let list = try JSONDecoder().decode(RegionList.self, from: data)
            var boxes: [String: BBox] = [:]
            for (name, r) in list.regions where r.bbox.count == 4 {
                boxes[name] = BBox(south: r.bbox[0], west: r.bbox[1], north: r.bbox[2], east: r.bbox[3]).expanded(byDegrees: 0.05)
            }
            if !boxes.isEmpty {
                Files.save(StampedRegions(checked: Date(), regions: boxes), to: file)
                regionBoxes = boxes
                return boxes
            }
        } catch {
            regionsFailedUntil = Date().addingTimeInterval(10 * 60)
        }
        let r = regionBoxes ?? saved?.regions ?? Self.fallbackRegions
        regionBoxes = r
        return r
    }

    private struct Index: Codable {
        let version: String
        let region: String
        let cell: Double
        let cells: [String: Int]
    }

    private struct Stamped: Codable {
        let checked: Date
        let index: Index
    }

    private var indexes: [String: Index] = [:]
    private var memory: [String: [Trail]] = [:]
    private var failedUntil: [String: Date] = [:]
    private let dir = Files.caches.appendingPathComponent("TrailPacks", isDirectory: true)

    private static func base(_ region: String) -> String {
        "https://github.com/CadeWardC/Edge/releases/download/trails-\(region)/"
    }

    struct Result {
        let trails: [Trail]
        /// Every cell of the box is covered by a pack (so no live search is needed there).
        let complete: Bool
    }

    /// Trails from the packs for the box, or nil if no pack covers any of it.
    func trails(in box: BBox) async -> Result? {
        let all = await regions()
        let regions = all.filter { $0.value.intersects(box) }.map(\.key)
        guard !regions.isEmpty else { return nil }
        var trails: [Trail] = []
        var wanted = 0, covered = 0, loaded = 0
        for region in regions {
            guard let index = await index(for: region) else { continue }
            loaded += 1
            for key in Self.cells(box, size: index.cell) {
                wanted += 1
                guard index.cells[key] != nil else { continue }
                if let ts = await cell(key, region: region, index: index) {
                    trails += ts
                    covered += 1
                }
            }
        }
        guard loaded > 0 else { return nil }
        // inside a state that has packs, a cell without a file simply has no trails
        let inside = all.values.contains { $0.contains(box.center) }
        return Result(trails: trails, complete: loaded == regions.count && (covered == wanted || inside))
    }

    static func cells(_ box: BBox, size: Double) -> [String] {
        let r0 = Int(floor(box.south / size)), r1 = Int(floor(box.north / size))
        let c0 = Int(floor(box.west / size)), c1 = Int(floor(box.east / size))
        guard r0 <= r1, c0 <= c1 else { return [] }
        var out: [String] = []
        for r in r0...r1 {
            for c in c0...c1 { out.append("\(r)_\(c)") }
        }
        return out
    }

    // MARK: Index (a tiny list of which cells exist; re-checked every few days)

    private func index(for region: String) async -> Index? {
        let file = dir.appendingPathComponent(region).appendingPathComponent("index.json")
        let saved = Files.load(Stamped.self, from: file)
        if let i = indexes[region], let saved, Date().timeIntervalSince(saved.checked) < 3 * 86400 { return i }
        if let saved, Date().timeIntervalSince(saved.checked) < 3 * 86400 {
            indexes[region] = saved.index
            return saved.index
        }
        if let until = failedUntil[region], until > Date() { return saved?.index }
        do {
            let data = try await Self.get(Self.base(region) + "index.json")
            let fresh = try JSONDecoder().decode(Index.self, from: data)
            Files.save(Stamped(checked: Date(), index: fresh), to: file)
            if let old = saved?.index, old.version != fresh.version { clearCells(region: region) }
            indexes[region] = fresh
            return fresh
        } catch {
            // no signal or no pack yet: use what's saved, and don't ask again for a while
            failedUntil[region] = Date().addingTimeInterval(10 * 60)
            if let saved { indexes[region] = saved.index }
            return saved?.index
        }
    }

    // MARK: Cells

    private func cell(_ key: String, region: String, index: Index) async -> [Trail]? {
        let memKey = "\(region)/\(key)"
        if let ts = memory[memKey] { return ts }
        let file = dir.appendingPathComponent(region).appendingPathComponent("\(index.version)_\(key).z")
        var data = try? Data(contentsOf: file)
        if data == nil {
            data = try? await Self.get(Self.base(region) + "c_\(key).z")
            if let data {
                try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: file)
            }
        }
        guard let data,
              let json = try? (data as NSData).decompressed(using: .zlib) as Data,
              let trails = try? JSONDecoder().decode([Trail].self, from: json) else { return nil }
        if memory.count > 80 { memory.removeAll() }
        memory[memKey] = trails
        return trails
    }

    private func clearCells(region: String) {
        let folder = dir.appendingPathComponent(region)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for f in files where f.pathExtension == "z" { try? FileManager.default.removeItem(at: f) }
        memory = memory.filter { !$0.key.hasPrefix(region + "/") }
    }

    private static func get(_ string: String) async throws -> Data {
        guard let url = URL(string: string) else { throw URLError(.badURL) }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue(Net.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }

    func size() -> Int64 { Files.directorySize(dir) }

    func clear() {
        memory.removeAll()
        indexes.removeAll()
        try? FileManager.default.removeItem(at: dir)
    }
}
