import Foundation

/// Trail packs: one compact file per US state, pre-built weekly from OpenStreetMap (scripts/build_trail_pack.py) and
/// published in the release "trails-us". The app downloads a state's file once, the first time the map shows it, and
/// keeps it: every trail in the state is then on the phone, instantly and offline. The file starts with a table of
/// contents, so only the cells (0.25°, about 25 km) around the map are unpacked.
actor TrailPacks {
    static let shared = TrailPacks()

    private static let release = "https://github.com/CadeWardC/Edge/releases/download/trails-us/"
    private static let magic = Data("SBTP1".utf8)

    private struct Region: Codable {
        let region: String
        let version: String
        let bbox: [Double]
        let bytes: Int?

        var box: BBox { BBox(south: bbox[0], west: bbox[1], north: bbox[2], east: bbox[3]).expanded(byDegrees: 0.05) }
    }

    private struct RegionList: Codable { let regions: [String: Region] }
    private struct Stamped: Codable {
        let checked: Date
        let list: RegionList
    }

    private struct Header: Codable {
        let version: String
        let cell: Double
        let cells: [String: [Int]]
    }

    /// An opened state file: its table of contents and where the cells start.
    private struct Pack {
        let url: URL
        let header: Header
        let bodyStart: UInt64
    }

    /// One trail that may fail to decode without taking its neighbours with it.
    private struct Lenient: Decodable {
        let trail: Trail?
        init(from decoder: Decoder) throws { trail = try? Trail(from: decoder) }
    }

    /// What happened, for Settings (and for sending a screenshot when something's wrong).
    private(set) var status: [String] = []

    private func note(_ line: String) {
        status.append("\(Date().formatted(date: .omitted, time: .shortened)) \(line)")
        if status.count > 12 { status.removeFirst(status.count - 12) }
    }

    func statusLines() -> [String] {
        var lines = packs.map { "\($0.key): v\($0.value.header.version), \($0.value.header.cells.count) cells, on the phone" }.sorted()
        lines += status
        return lines
    }

    private var list: RegionList?
    private var listFailedUntil = Date.distantPast
    private var packs: [String: Pack] = [:]
    private var downloading: [String: Task<Pack?, Never>] = [:]
    private var memory: [String: [Trail]] = [:]
    private let dir = Files.support.appendingPathComponent("TrailPacks", isDirectory: true)

    struct Result {
        let trails: [Trail]
        /// The packs cover the whole box (so no live search is needed there).
        let complete: Bool
    }

    /// Trails from the packs for the box, or nil if no pack covers it.
    func trails(in box: BBox) async -> Result? {
        guard let regions = await regionList()?.regions.values.filter({ $0.bbox.count == 4 && $0.box.intersects(box) }),
              !regions.isEmpty else { return nil }
        var trails: [Trail] = []
        var loaded = 0
        for r in regions {
            guard let pack = await pack(for: r) else { continue }
            loaded += 1
            for key in Self.cells(box, size: pack.header.cell) where pack.header.cells[key] != nil {
                trails += cell(key, region: r.region, pack: pack)
            }
        }
        guard loaded > 0 else { return nil }
        let inside = regions.contains { $0.box.contains(box.center) }
        return Result(trails: trails, complete: loaded == regions.count && inside)
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

    // MARK: The list of states (re-checked every few days)

    /// The list of states that came with the app (so the first launch works without signal).
    private static var bundledList: RegionList? {
        guard let url = Bundle.main.url(forResource: "regions", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(RegionList.self, from: data)
    }

    /// A state's trail file that came with the app, if any.
    private static func bundledFile(_ region: String) -> URL? {
        Bundle.main.url(forResource: region, withExtension: "trails")
    }

    private func regionList(force: Bool = false) async -> RegionList? {
        let file = dir.appendingPathComponent("regions.json")
        let saved = Files.load(Stamped.self, from: file)
        if !force, let saved, Date().timeIntervalSince(saved.checked) < 3 * 86400 {
            list = saved.list
            return saved.list
        }
        if !force, listFailedUntil > Date() { return list ?? saved?.list ?? Self.bundledList }
        do {
            let fresh = try JSONDecoder().decode(RegionList.self, from: try await Self.get(Self.release + "regions.json"))
            Files.save(Stamped(checked: Date(), list: fresh), to: file)
            list = fresh
            note("list of states: \(fresh.regions.count)")
            return fresh
        } catch {
            note("list of states failed: \(error.localizedDescription)")
            listFailedUntil = Date().addingTimeInterval(10 * 60)
            list = list ?? saved?.list ?? Self.bundledList
            return list
        }
    }

    // MARK: State files

    private func pack(for r: Region) async -> Pack? {
        if let p = packs[r.region], p.header.version == r.version { return p }
        let url = dir.appendingPathComponent("\(r.region)-\(r.version).trails")
        if let p = open(url) {
            packs[r.region] = p
            return p
        }
        // the copy that came with the app: use it right away (instant, offline), and fetch the newer week's
        // file in the background if there is one
        if let bundled = Self.bundledFile(r.region), let p = open(bundled) {
            if packs[r.region] == nil { packs[r.region] = p }
            if p.header.version != r.version, downloading[r.region] == nil {
                Task { _ = await self.download(r, to: url) }
            }
            return packs[r.region]
        }
        return await download(r, to: url)
    }

    /// Downloads a state's file once (shared by everyone asking for it at the same time).
    private func download(_ r: Region, to url: URL) async -> Pack? {
        if let running = downloading[r.region] { return await running.value }
        let task = Task<Pack?, Never> {
            let data: Data
            do {
                data = try await Self.get(Self.release + "\(r.region).trails")
            } catch {
                await self.note("\(r.region) download failed: \(error.localizedDescription)")
                return nil
            }
            await self.note("\(r.region) downloaded (\(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)))")
            try? FileManager.default.createDirectory(at: self.dir, withIntermediateDirectories: true)
            guard (try? data.write(to: url, options: .atomic)) != nil else { return nil }
            return await self.opened(url, region: r.region)
        }
        downloading[r.region] = task
        let p = await task.value
        downloading[r.region] = nil
        return p
    }

    private func opened(_ url: URL, region: String) -> Pack? {
        guard let p = open(url) else {
            note("\(region) file couldn't be read")
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        packs[region] = p
        memory = memory.filter { !$0.key.hasPrefix(region + "/") }
        // older versions of this state's file aren't needed any more
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for f in files where f.lastPathComponent.hasPrefix(region + "-") && f != url { try? FileManager.default.removeItem(at: f) }
        return p
    }

    private func open(_ url: URL) -> Pack? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let start = try? handle.read(upToCount: 9), start.count == 9, start.prefix(5) == Self.magic else { return nil }
        let length = start.suffix(4).reduce(0) { ($0 << 8) | Int($1) }
        guard length > 0, length < 50_000_000, let headerData = try? handle.read(upToCount: length), headerData.count == length,
              let header = try? JSONDecoder().decode(Header.self, from: headerData) else { return nil }
        return Pack(url: url, header: header, bodyStart: UInt64(9 + length))
    }

    private func cell(_ key: String, region: String, pack: Pack) -> [Trail] {
        let memKey = "\(region)/\(key)"
        if let ts = memory[memKey] { return ts }
        guard let range = pack.header.cells[key], range.count == 2,
              let handle = try? FileHandle(forReadingFrom: pack.url) else { return [] }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: pack.bodyStart + UInt64(range[0]))) != nil,
              let blob = try? handle.read(upToCount: range[1]) else {
            note("\(region) \(key): couldn't read")
            return []
        }
        guard let json = try? (blob as NSData).decompressed(using: .zlib) as Data else {
            note("\(region) \(key): couldn't unpack")
            return []
        }
        guard let items = try? JSONDecoder().decode([Lenient].self, from: json) else {
            note("\(region) \(key): couldn't decode")
            return []
        }
        let trails = items.compactMap(\.trail)
        if trails.count < items.count { note("\(region) \(key): skipped \(items.count - trails.count) bad trails") }
        if memory.count > 120 { memory.removeAll() }
        memory[memKey] = trails
        return trails
    }

    private static func get(_ string: String) async throws -> Data {
        guard let url = URL(string: string) else { throw URLError(.badURL) }
        var req = URLRequest(url: url, timeoutInterval: 60)
        req.setValue(Net.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }

    /// Checks for newer weekly trail files now, and updates every state already on the phone (downloaded or
    /// built in). Returns a short summary.
    func checkForUpdates() async -> String {
        listFailedUntil = .distantPast
        guard let list = await regionList(force: true) else { return "Couldn't reach the trail files. Check your signal." }
        var updated: [String] = [], current = 0, failed = 0
        // states you've looked at (or downloaded): built-in states you've never opened stay as they are, so a check
        // doesn't fetch the whole country
        let onPhone = Set(packs.keys).union(Self.downloadedRegions(in: dir))
        for name in onPhone.sorted() {
            guard let r = list.regions[name], r.bbox.count == 4 else { continue }
            if let p = packs[name], p.header.version == r.version {
                current += 1
                continue
            }
            let url = dir.appendingPathComponent("\(r.region)-\(r.version).trails")
            if let p = open(url) {
                packs[name] = p
                current += 1
            } else if await download(r, to: url) != nil {
                updated.append(name.replacingOccurrences(of: "-", with: " ").capitalized)
            } else {
                failed += 1
            }
        }
        if !updated.isEmpty { return "Updated \(updated.joined(separator: ", "))." + (failed > 0 ? " \(failed) couldn't download." : "") }
        if failed > 0 { return "\(failed) state\(failed == 1 ? "" : "s") couldn't download. Check your signal." }
        return current == 0 ? "No state trail files on the phone yet." : "Trails are up to date (\(list.regions.first?.value.version ?? ""))."
    }

    private static func downloadedRegions(in dir: URL) -> Set<String> {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return Set(files.filter { $0.pathExtension == "trails" }.compactMap { f -> String? in
            let base = f.deletingPathExtension().lastPathComponent
            guard let dash = base.lastIndex(of: "-") else { return nil }
            return String(base[..<dash])
        })
    }

    // MARK: Settings

    func size() -> Int64 { Files.directorySize(dir) }

    func clear() {
        memory.removeAll()
        packs.removeAll()
        list = nil
        try? FileManager.default.removeItem(at: dir)
    }
}
