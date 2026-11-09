import Foundation

/// Trails found so far, kept on disk in a grid of small cells: places you've looked at load instantly, and a
/// search only asks the server for cells it doesn't have yet.
actor TrailCache {
    static let shared = TrailCache()
    static let cellSize = 0.05
    static let maxAge: TimeInterval = 14 * 24 * 3600

    struct Cell: Hashable {
        let lat: Int
        let lon: Int

        var box: BBox {
            let s = TrailCache.cellSize
            return BBox(south: Double(lat) * s, west: Double(lon) * s, north: Double(lat + 1) * s, east: Double(lon + 1) * s)
        }

        var fileName: String { "\(lat)_\(lon).json" }
    }

    private struct Entry: Codable {
        var fetched: Date
        var trails: [Trail]
    }

    private var memory: [Cell: Entry] = [:]
    private let dir = Files.caches.appendingPathComponent("TrailCells", isDirectory: true)

    static func cell(at c: Coord) -> Cell {
        Cell(lat: Int(floor(c.lat / cellSize)), lon: Int(floor(c.lon / cellSize)))
    }

    static func cells(in box: BBox) -> [Cell] {
        let sw = cell(at: Coord(lat: box.south, lon: box.west))
        let ne = cell(at: Coord(lat: box.north, lon: box.east))
        guard sw.lat <= ne.lat, sw.lon <= ne.lon else { return [] }
        var out: [Cell] = []
        for la in sw.lat...ne.lat {
            for lo in sw.lon...ne.lon { out.append(Cell(lat: la, lon: lo)) }
        }
        return out
    }

    /// The smallest box holding all the cells.
    static func box(of cells: [Cell]) -> BBox? {
        guard let minLat = cells.map(\.lat).min(), let maxLat = cells.map(\.lat).max(),
              let minLon = cells.map(\.lon).min(), let maxLon = cells.map(\.lon).max() else { return nil }
        let s = cellSize
        return BBox(south: Double(minLat) * s, west: Double(minLon) * s, north: Double(maxLat + 1) * s, east: Double(maxLon + 1) * s)
    }

    private func entry(_ c: Cell) -> Entry? {
        if let e = memory[c] { return e }
        guard let e = Files.load(Entry.self, from: dir.appendingPathComponent(c.fileName)) else { return nil }
        memory[c] = e
        return e
    }

    func trails(in box: BBox) -> [Trail] {
        Self.cells(in: box).flatMap { entry($0)?.trails ?? [] }
    }

    /// Cells in the box that were never fetched, or were fetched too long ago.
    func missing(in box: BBox) -> [Cell] {
        Self.cells(in: box).filter { c in
            guard let e = entry(c) else { return true }
            return Date().timeIntervalSince(e.fetched) > Self.maxAge
        }
    }

    /// Saves a search's trails, each in the cell where it starts.
    func store(_ trails: [Trail], for cells: [Cell]) {
        var byCell: [Cell: [Trail]] = [:]
        for c in cells { byCell[c] = [] }
        for t in trails {
            let c = Self.cell(at: t.start)
            if byCell[c] != nil { byCell[c]?.append(t) }
        }
        if memory.count > 600 { memory.removeAll() }
        for (c, list) in byCell {
            let e = Entry(fetched: Date(), trails: list)
            memory[c] = e
            Files.save(e, to: dir.appendingPathComponent(c.fileName))
        }
    }

    func clear() {
        memory.removeAll()
        try? FileManager.default.removeItem(at: dir)
    }

    func size() -> Int64 { Files.directorySize(dir) }
}
