import Foundation

enum MapID: Int, Codable, CaseIterable {
    case crossroads, twinRivers, highlands, frontier

    var name: String {
        switch self {
        case .crossroads: return "Crossroads"
        case .twinRivers: return "Twin Rivers"
        case .highlands: return "Highlands"
        case .frontier: return "Frontier"
        }
    }
    var maxPlayers: Int {
        switch self {
        case .crossroads, .twinRivers: return 2
        case .highlands, .frontier: return 4
        }
    }
    var blurb: String {
        switch self {
        case .crossroads: return "1v1. Open center, rocky flanks, three beacons."
        case .twinRivers: return "1v1. A river splits the map; hold the three bridges."
        case .highlands: return "Up to 4 players, free-for-all. Corner bases around a walled center."
        case .frontier: return "2v2 (west vs east). Wide front lines and a contested middle."
        }
    }
    var size: Int {
        switch self {
        case .crossroads, .twinRivers: return 64
        case .highlands, .frontier: return 80
        }
    }
    /// Team for a slot when the player has not picked one: 1v1 and FFA give everyone their own team.
    func defaultTeam(slot: Int) -> Int { self == .frontier ? slot % 2 : slot }
}

enum MapGen {
    private enum Shape {
        case rock(Double, Double, Double)        // center x, y, radius (tiles)
        case water(Double, Double, Double)
        case dirt(Double, Double, Double)
    }

    static func build(_ id: MapID) -> GameMap {
        let n = id.size
        let map = GameMap(id: id, width: n, height: n, seed: 0xA11CE + UInt64(id.rawValue) * 7919)
        var rng = Rng(seed: 1234 + UInt64(id.rawValue) * 101)

        // symmetry images of a point (in tile coordinates, continuous)
        let m = Double(n - 1)
        let images: (Double, Double) -> [(Double, Double)]
        if id == .highlands {
            images = { x, y in [(x, y), (m - y, x), (m - x, m - y), (y, m - x)] }
        } else {
            images = { x, y in [(x, y), (m - x, m - y)] }
        }
        let backImages: (Int, Int) -> [(Int, Int)]
        if id == .highlands {
            backImages = { dx, dy in [(dx, dy), (-dy, dx), (-dx, -dy), (dy, -dx)] }
        } else {
            backImages = { dx, dy in [(dx, dy), (-dx, -dy)] }
        }

        // base sites in the fundamental domain: HQ center tile + direction the crystals sit in
        var sites: [(x: Int, y: Int, bx: Int, by: Int, start: Bool)] = []
        var beaconPts: [(Double, Double)] = []
        var shapes: [Shape] = []
        var extraStartsOrder: [Int] = []

        switch id {
        case .crossroads:
            sites = [(9, 9, -1, -1, true), (9, 31, -1, 0, false), (31, 9, 0, -1, false)]
            beaconPts = [(31.5, 31.5), (16, 47)]
            for _ in 0..<26 {
                let x = rng.range(3, 60), y = rng.range(3, Double(n) - 3)
                if x + y < Double(n) - 2 { shapes.append(.rock(x, y, rng.range(1.2, 3.2))) }
            }
            // flank walls that make two wide lanes and a center
            for i in 0..<6 { shapes.append(.rock(20 + Double(i) * 1.6, 40 - Double(i) * 1.6, 1.8)) }
        case .twinRivers:
            sites = [(9, 9, -1, -1, true), (26, 8, 0, -1, false), (8, 26, -1, 0, false)]
            beaconPts = [(31.5, 31.5), (14, 49)]
            for _ in 0..<16 {
                let x = rng.range(3, 60), y = rng.range(3, 60)
                if x + y < Double(n) - 8 { shapes.append(.rock(x, y, rng.range(1.0, 2.6))) }
            }
            for _ in 0..<4 {
                let x = rng.range(14, 40), y = rng.range(14, 40)
                if x + y < Double(n) - 12 { shapes.append(.water(x, y, rng.range(1.5, 2.8))) }
            }
        case .highlands:
            sites = [(9, 9, -1, -1, true), (9, 29, -1, 0, false)]
            beaconPts = [(39.5, 39.5), (39.5, 17)]
            // a broken wall around the center
            for i in 0..<9 {
                let t = Double(i) / 8.0
                shapes.append(.rock(28 + 3 * t, 26 + 0 * t, 1.6))
                shapes.append(.rock(26, 28 + 3 * t, 1.6))
            }
            for _ in 0..<14 {
                let x = rng.range(3, 38), y = rng.range(3, 38)
                shapes.append(.rock(x, y, rng.range(1.0, 2.6)))
            }
            shapes.append(.water(20, 20, 2.2))
        case .frontier:
            sites = [(9, 13, -1, 0, true), (9, 66, -1, 0, true), (26, 39, -1, 0, false)]
            beaconPts = [(39.5, 39.5), (30, 12), (30, 67)]
            extraStartsOrder = []
            for _ in 0..<30 {
                let x = rng.range(3, 39), y = rng.range(3, 77)
                shapes.append(.rock(x, y, rng.range(1.0, 2.8)))
            }
            shapes.append(.water(20, 28, 2.5))
            shapes.append(.water(20, 52, 2.5))
        }
        _ = extraStartsOrder

        // stamp terrain (with symmetry)
        func stamp(_ cx: Double, _ cy: Double, _ r: Double, _ t: Terrain) {
            for (ix, iy) in images(cx, cy) {
                let r2 = r * r
                let x0 = Int(ix - r - 1), x1 = Int(ix + r + 1), y0 = Int(iy - r - 1), y1 = Int(iy + r + 1)
                for y in stride(from: max(0, y0), through: min(n - 1, y1), by: 1) {
                    for x in stride(from: max(0, x0), through: min(n - 1, x1), by: 1) {
                        let dx = Double(x) - ix, dy = Double(y) - iy
                        if dx * dx + dy * dy <= r2 { map.terrain[map.index(x, y)] = t }
                    }
                }
            }
        }
        for s in shapes {
            switch s {
            case let .rock(x, y, r): stamp(x, y, r, .rock)
            case let .water(x, y, r): stamp(x, y, r, .water)
            case let .dirt(x, y, r): stamp(x, y, r, .dirt)
            }
        }
        if id == .twinRivers {
            // the river along the anti-diagonal, with three bridges
            for y in 0..<n {
                for x in 0..<n where abs(x + y - (n - 1)) <= 1 {
                    let fx = Double(x), fy = Double(y)
                    let nearBridge = [(31.5, 31.5), (14.0, 49.0), (49.0, 14.0)].contains { (bx, by) in
                        (fx - bx) * (fx - bx) + (fy - by) * (fy - by) <= 9
                    }
                    map.terrain[map.index(x, y)] = nearBridge ? .dirt : .water
                }
            }
        }

        // clear the bases and beacons, and lay dirt under them
        var siteList: [BaseSite] = []
        for s in sites {
            let imgs = images(Double(s.x), Double(s.y))
            let backs = backImages(s.bx, s.by)
            for (k, img) in imgs.enumerated() {
                let cx = Int(img.0.rounded()), cy = Int(img.1.rounded())
                clear(map, cx, cy, 7, center: .grass)
                clear(map, cx, cy, 4, center: .dirt)
                let crystals = crystalTiles(cx: cx, cy: cy, back: backs[k])
                siteList.append(BaseSite(hqOrigin: TilePoint(x: cx - 1, y: cy - 1), crystals: crystals, isStart: s.start))
            }
        }
        var beaconTiles: [TilePoint] = []
        for b in beaconPts {
            for img in images(b.0, b.1) {
                let t = TilePoint(x: Int(img.0.rounded()), y: Int(img.1.rounded()))
                if !beaconTiles.contains(where: { abs($0.x - t.x) <= 2 && abs($0.y - t.y) <= 2 }) {
                    beaconTiles.append(t)
                    clear(map, t.x, t.y, 3, center: .dirt)
                }
            }
        }

        // order: starts first (in symmetric pairs for fair 1v1 / 2v2 slot order), then expansions
        var starts = siteList.filter { $0.isStart }
        if id == .frontier, starts.count == 4 {
            // images come as [a, rot(a), b, rot(b)]: slots 0,2 west (team 0), 1,3 east (team 1)
            starts = [starts[0], starts[1], starts[2], starts[3]]
        }
        map.bases = starts + siteList.filter { !$0.isStart }
        map.beacons = beaconTiles

        // make sure everything important is reachable from the first start
        let mid = TilePoint(x: n / 2, y: n / 2)
        clear(map, mid.x, mid.y, 2, center: .dirt)
        for _ in 0..<3 {
            let reach = flood(map, from: TilePoint(x: map.bases[0].hqOrigin.x + 1, y: map.bases[0].hqOrigin.y + 1))
            var fixed = false
            let targets = map.bases.map { TilePoint(x: $0.hqOrigin.x + 1, y: $0.hqOrigin.y + 1) } + map.beacons + [mid]
            for t in targets where !reach[map.index(t.x, t.y)] {
                carve(map, from: t, to: mid)
                fixed = true
            }
            if !fixed { break }
        }
        // the map edge is a rock wall
        for i in 0..<n {
            for t in [(i, 0), (i, n - 1), (0, i), (n - 1, i)] where map.terrain[map.index(t.0, t.1)] != .water {
                map.terrain[map.index(t.0, t.1)] = .rock
            }
        }
        return map
    }

    private static func clear(_ map: GameMap, _ cx: Int, _ cy: Int, _ r: Int, center t: Terrain) {
        for y in (cy - r)...(cy + r) {
            for x in (cx - r)...(cx + r) where map.inBounds(x, y) {
                let dx = x - cx, dy = y - cy
                if dx * dx + dy * dy <= r * r + r { map.terrain[map.index(x, y)] = t }
            }
        }
    }

    private static func crystalTiles(cx: Int, cy: Int, back: (Int, Int)) -> [TilePoint] {
        let (bx, by) = back
        var offs: [(Int, Int)]
        if bx != 0 && by != 0 {
            // an arc around the back corner (pattern for back = (-1, -1))
            offs = [(-5, 1), (-5, 0), (-5, -1), (-4, -3), (-3, -4), (-1, -5), (0, -5), (1, -5)]
            offs = offs.map { (bx < 0 ? $0.0 : -$0.0, by < 0 ? $0.1 : -$0.1) }
        } else {
            // a slightly curved line behind (pattern for back = (-1, 0))
            offs = [(-5, -3), (-5, -2), (-6, -1), (-6, 0), (-6, 1), (-5, 2), (-5, 3), (-4, 4)]
            offs = offs.map { o in
                if bx < 0 { return o }
                if bx > 0 { return (-o.0, -o.1) }
                if by < 0 { return (o.1, o.0) }        // back = (0, -1)
                return (-o.1, -o.0)                     // back = (0, 1)
            }
        }
        return offs.map { TilePoint(x: cx + $0.0, y: cy + $0.1) }
    }

    private static func flood(_ map: GameMap, from s: TilePoint) -> [Bool] {
        var seen = Array(repeating: false, count: map.width * map.height)
        guard map.inBounds(s.x, s.y) else { return seen }
        var stack = [s]
        seen[map.index(s.x, s.y)] = true
        while let t = stack.popLast() {
            for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                let x = t.x + dx, y = t.y + dy
                guard map.inBounds(x, y) else { continue }
                let i = map.index(x, y)
                if !seen[i] && map.terrain[i].passable {
                    seen[i] = true
                    stack.append(TilePoint(x: x, y: y))
                }
            }
        }
        return seen
    }

    private static func carve(_ map: GameMap, from a: TilePoint, to b: TilePoint) {
        let steps = max(abs(b.x - a.x), abs(b.y - a.y)) * 2 + 1
        for i in 0...steps {
            let t = Double(i) / Double(steps)
            let x = Int((Double(a.x) + Double(b.x - a.x) * t).rounded())
            let y = Int((Double(a.y) + Double(b.y - a.y) * t).rounded())
            for dy in -1...1 {
                for dx in -1...1 where map.inBounds(x + dx, y + dy) {
                    let i2 = map.index(x + dx, y + dy)
                    if !map.terrain[i2].passable { map.terrain[i2] = .dirt }
                }
            }
        }
    }
}
