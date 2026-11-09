import Foundation
import MapLibre

struct OfflineArea: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var bbox: BBox
    var source: String
    var minZoom: Int
    var maxZoom: Int
    var tileCount: Int
    var downloaded = 0
    var failed = 0
    var bytes: Int64 = 0
    var trailCount = 0
    var created = Date()
    var complete = false

    var baseMap: BaseMap { BaseMap(rawValue: source) ?? .topo }
    var isVector: Bool { baseMap.isVector }
}

/// Map areas downloaded for use without signal: their topo tiles and the trails in them.
@MainActor
final class OfflineStore: ObservableObject {
    static let shared = OfflineStore()
    static let maxTiles = 12_000

    @Published private(set) var areas: [OfflineArea] = []
    @Published private(set) var progress: [UUID: Double] = [:]

    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var trailCache: [UUID: [Trail]] = [:]
    private let root = Files.support.appendingPathComponent("Offline", isDirectory: true)
    private var listURL: URL { root.appendingPathComponent("areas.json") }

    init() {
        areas = Files.load([OfflineArea].self, from: listURL) ?? []
        updateTileRoots()
        // downloads that were cut off when the app quit carry on
        for area in areas where !area.complete { resume(area) }
    }

    func dir(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }

    private func updateTileRoots() {
        TileStore.shared.setOfflineRoots(areas.map { dir($0.id) })
    }

    func isDownloading(_ id: UUID) -> Bool { tasks[id] != nil }

    /// A downloaded (or downloading) area that holds the whole box.
    func area(covering box: BBox) -> OfflineArea? {
        areas.first {
            $0.bbox.contains(Coord(lat: box.south, lon: box.west)) && $0.bbox.contains(Coord(lat: box.north, lon: box.east))
        }
    }

    /// Downloads the map around a trail (about a kilometre of margin), as detailed as the size limit allows.
    func download(trail: Trail, source: BaseMap) {
        let box = trail.bbox.expanded(byDegrees: 0.01)
        var zoom = source.maxZoom
        while zoom > 12 && TileStore.tileCount(box, minZoom: 6, maxZoom: zoom) > Self.maxTiles { zoom -= 1 }
        download(name: trail.name, bbox: box, source: source, maxZoom: zoom)
    }

    func download(name: String, bbox: BBox, source: BaseMap, maxZoom: Int) {
        let minZoom = 6
        let top = min(maxZoom, source.maxZoom)
        let area = OfflineArea(name: name.isEmpty ? "Offline area" : name, bbox: bbox, source: source.rawValue,
                               minZoom: minZoom, maxZoom: top,
                               tileCount: TileStore.tileCount(bbox, minZoom: minZoom, maxZoom: top))
        areas.insert(area, at: 0)
        persist()
        updateTileRoots()
        resume(area)
    }

    private func resume(_ area: OfflineArea) {
        guard tasks[area.id] == nil else { return }
        let id = area.id
        let folder = dir(id)
        progress[id] = Double(area.downloaded) / Double(max(1, area.tileCount))
        tasks[id] = Task { [weak self] in
            // the trails first, so they're there even if the tiles take a while
            if area.trailCount == 0 {
                var found: [String: Trail] = [:]
                for cell in area.bbox.tiles(cell: 0.25).prefix(16) {
                    if Task.isCancelled { break }
                    if let trails = try? await TrailSources.trails(in: cell) {
                        for t in trails { found[t.id] = t }
                    }
                }
                let trails = Array(found.values)
                await Profiles.shared.enrich(Array(trails.prefix(80)))
                let withProfiles = trails.map { Profiles.shared.withProfile($0) }
                Files.save(withProfiles, to: folder.appendingPathComponent("trails.json"))
                self?.trailCache[id] = withProfiles
                self?.update(id) { $0.trailCount = withProfiles.count }
            }

            if area.isVector {
                await self?.downloadVector(area)
                return
            }
            let all = TileStore.tiles(area.bbox, minZoom: area.minZoom, maxZoom: area.maxZoom)
            let source = area.baseMap
            var done = 0, failed = 0
            var bytes: Int64 = 0
            await withTaskGroup(of: Int64?.self) { group in
                var next = 0
                while next < min(3, all.count) {
                    let t = all[next]
                    next += 1
                    group.addTask { await OfflineStore.fetchTile(source, t.z, t.x, t.y, into: folder) }
                }
                while let r = await group.next() {
                    done += 1
                    if let r { bytes += r } else { failed += 1 }
                    if done % 25 == 0 || done == all.count {
                        let d = done, f = failed, b = bytes
                        self?.update(id) { $0.downloaded = d; $0.failed = f; $0.bytes = b }
                        self?.progress[id] = Double(d) / Double(max(1, all.count))
                    }
                    if Task.isCancelled { group.cancelAll(); break }
                    if next < all.count {
                        let t = all[next]
                        next += 1
                        group.addTask { await OfflineStore.fetchTile(source, t.z, t.x, t.y, into: folder) }
                    }
                }
            }
            guard let self else { return }
            self.tasks[id] = nil
            self.progress[id] = nil
            if !Task.isCancelled {
                self.update(id) { $0.complete = true; $0.bytes = Files.directorySize(folder) }
            }
        }
    }

    // MARK: Vector packs (our own map)

    /// Saves our own map for the area as a MapLibre offline pack: vector tiles to zoom 14 (drawn sharp at any zoom),
    /// the terrain for hillshading, and the fonts. Much smaller than pictures of the map.
    private func downloadVector(_ area: OfflineArea) async {
        let id = area.id
        defer {
            tasks[id] = nil
            progress[id] = nil
        }
        guard let styleURL = LibreTrailMap.styleURL(dark: false) else { return }
        // MapLibre loads its list of packs in the background at launch
        var waited = 0
        while MLNOfflineStorage.shared.packs == nil && waited < 50 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            waited += 1
        }
        var pack = Self.pack(for: id)
        if pack == nil {
            let region = MLNTilePyramidOfflineRegion(styleURL: styleURL, bounds: LibreTrailMap.Coordinator.bounds(area.bbox),
                                                     fromZoomLevel: Double(area.minZoom), toZoomLevel: Double(area.maxZoom))
            pack = await withCheckedContinuation { (cont: CheckedContinuation<MLNOfflinePack?, Never>) in
                MLNOfflineStorage.shared.addPack(for: region, withContext: Data(id.uuidString.utf8)) { pack, _ in
                    cont.resume(returning: pack)
                }
            }
        }
        guard let pack else { return }
        pack.resume()
        var lastDone: UInt64 = 0
        var stalled = 0
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 700_000_000)
            pack.requestProgress()
            let p = pack.progress
            let expected = max(p.countOfResourcesExpected, 1)
            progress[id] = min(1, Double(p.countOfResourcesCompleted) / Double(expected))
            update(id) {
                $0.downloaded = Int(p.countOfResourcesCompleted)
                $0.tileCount = Int(expected)
                $0.bytes = Int64(p.countOfBytesCompleted)
            }
            if pack.state == .complete || (p.countOfResourcesExpected > 0 && p.countOfResourcesCompleted >= p.countOfResourcesExpected) {
                update(id) { $0.complete = true }
                return
            }
            // no progress for a minute (no signal): stop, it can be retried
            if p.countOfResourcesCompleted == lastDone { stalled += 1 } else { stalled = 0 }
            lastDone = p.countOfResourcesCompleted
            if stalled > 85 {
                pack.suspend()
                return
            }
        }
        pack.suspend()
    }

    private static func pack(for id: UUID) -> MLNOfflinePack? {
        MLNOfflineStorage.shared.packs?.first { String(data: $0.context, encoding: .utf8) == id.uuidString }
    }

    /// Downloads one tile into the area's folder; returns its size, or nil if it failed.
    nonisolated static func fetchTile(_ source: BaseMap, _ z: Int, _ x: Int, _ y: Int, into folder: URL) async -> Int64? {
        let url = folder.appendingPathComponent(TileStore.relativePath(source, z: z, x: x, y: y))
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize { return Int64(size) }
        let data: Data
        if let cached = TileStore.shared.data(source, z: z, x: x, y: y) {
            data = cached
        } else {
            guard let fetched = try? await TileStore.fetch(source, z: z, x: x, y: y) else { return nil }
            data = fetched
        }
        TileStore.shared.store(data, source, z: z, x: x, y: y, in: folder)
        return Int64(data.count)
    }

    private func update(_ id: UUID, _ change: (inout OfflineArea) -> Void) {
        guard let i = areas.firstIndex(where: { $0.id == id }) else { return }
        change(&areas[i])
        persist()
    }

    func delete(_ area: OfflineArea) {
        tasks[area.id]?.cancel()
        tasks[area.id] = nil
        progress[area.id] = nil
        areas.removeAll { $0.id == area.id }
        trailCache[area.id] = nil
        try? FileManager.default.removeItem(at: dir(area.id))
        if let pack = Self.pack(for: area.id) {
            MLNOfflineStorage.shared.removePack(pack, withCompletionHandler: nil)
        }
        persist()
        updateTileRoots()
    }

    func delete(at offsets: IndexSet) {
        for i in offsets.sorted(by: >) where i < areas.count { delete(areas[i]) }
    }

    func retry(_ area: OfflineArea) {
        update(area.id) { $0.complete = false }
        if let a = areas.first(where: { $0.id == area.id }) { resume(a) }
    }

    /// Trails saved with offline areas that overlap the box (for searching without signal).
    func trails(in box: BBox) -> [Trail] {
        var out: [String: Trail] = [:]
        for area in areas where area.bbox.intersects(box) {
            if trailCache[area.id] == nil {
                trailCache[area.id] = Files.load([Trail].self, from: dir(area.id).appendingPathComponent("trails.json")) ?? []
            }
            for t in trailCache[area.id] ?? [] where t.bbox.intersects(box) { out[t.id] = t }
        }
        return Array(out.values)
    }

    private func persist() { Files.save(areas, to: listURL) }
}
