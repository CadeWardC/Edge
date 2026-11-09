import Foundation

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
