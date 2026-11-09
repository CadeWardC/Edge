import Foundation

enum MapID: Int, Codable, CaseIterable {
    case crossroads, twinRivers, duneSea, frostbite, highlands, frontier, caldera

    var name: String {
        switch self {
        case .crossroads: return "Crossroads"
        case .twinRivers: return "Twin Rivers"
        case .duneSea: return "Dune Sea"
        case .frostbite: return "Frostbite"
        case .highlands: return "Highlands"
        case .frontier: return "Frontier"
        case .caldera: return "Caldera"
        }
    }
    var maxPlayers: Int {
        switch self {
        case .crossroads, .twinRivers, .duneSea, .frostbite: return 2
        case .highlands, .frontier, .caldera: return 4
        }
    }
    var biome: Biome {
        switch self {
        case .crossroads, .twinRivers, .highlands: return .grass
        case .duneSea, .frontier: return .desert
        case .frostbite: return .snow
        case .caldera: return .volcanic
        }
    }
    var blurb: String {
        switch self {
        case .crossroads: return "1v1 · Grassland. Mains on high ground with one ramp, two watch towers on hills, a rich field on each flank."
        case .twinRivers: return "1v1 · Grassland. A river splits the map; three bridges and the towers beside them decide the game."
        case .duneSea: return "1v1 · Desert. Wide open sand between mesas. Two natural expansions each and a contested rich field."
        case .frostbite: return "1v1 · Snow. Pine forests carve narrow lanes; frozen lakes block the middle. Good for ambushes."
        case .highlands: return "2–4 players, free-for-all. Corner plateaus around a central hill with a tower."
        case .frontier: return "2v2 (west vs east) · Desert. Long front line, shared rich field behind each team."
        case .caldera: return "2–4 players · Volcanic. A lava lake fills the crater; rich fields sit on its rim."
        }
    }
    var size: Int {
        switch self {
        case .crossroads, .twinRivers, .duneSea, .frostbite: return 64
        case .highlands, .frontier, .caldera: return 80
        }
    }
    /// Team for a slot when the player has not picked one: 1v1 and FFA give everyone their own team.
    func defaultTeam(slot: Int) -> Int { self == .frontier ? slot % 2 : slot }
}

/// Builds the maps. Each map is hand-placed in one half (or quarter) and copied by rotation, so every start is
/// identical. Random details (rocks, trees) come from a fixed seed per map, so every device builds the same map.
enum MapGen {
    static func build(_ id: MapID) -> GameMap {
        let b = Builder(id)
        b.layout()
        return b.finish()
    }
}

private final class Builder {
    let id: MapID
    let map: GameMap
    let n: Int
    let m: Double
    let fourWay: Bool
    var rng: Rng
    var sites: [(x: Int, y: Int, bx: Int, by: Int, start: Bool, rich: Bool)] = []
    var beaconPts: [(Double, Double)] = []
    var towerPts: [(Double, Double)] = []
    var keep: [(Double, Double, Double)] = []

    init(_ id: MapID) {
        self.id = id
        n = id.size
        m = Double(n - 1)
        fourWay = id == .highlands || id == .caldera
        map = GameMap(id: id, width: n, height: n, seed: 0xA11CE + UInt64(id.rawValue) * 7919)
        rng = Rng(seed: 1234 + UInt64(id.rawValue) * 101)
    }

    // MARK: symmetry

    func images(_ x: Double, _ y: Double) -> [(Double, Double)] {
        fourWay ? [(x, y), (m - y, x), (m - x, m - y), (y, m - x)] : [(x, y), (m - x, m - y)]
    }

    func dirImages(_ dx: Int, _ dy: Int) -> [(Int, Int)] {
        fourWay ? [(dx, dy), (-dy, dx), (-dx, -dy), (dy, -dx)] : [(dx, dy), (-dx, -dy)]
    }

    /// The part of the map that is hand-made; the rest is a rotated copy.
    func inDomain(_ x: Double, _ y: Double) -> Bool {
        fourWay ? (x < m / 2 && y < m / 2) : (x + y < m)
    }

    // MARK: stamping

    private func set(_ x: Int, _ y: Int, _ t: Terrain) {
        guard map.inBounds(x, y) else { return }
        let i = map.index(x, y)
        let cur = map.terrain[i]
        if cur == .cliff || cur == .ramp { return }
        if map.elevation[i] == 1 && t != .grass && t != .dirt { return }   // keep plateau tops clean
        map.terrain[i] = t
    }

    private func disc(_ cx: Double, _ cy: Double, _ r: Double, _ body: (Int, Int, Double) -> Void) {
        let x0 = Int(cx - r - 1), x1 = Int(cx + r + 1), y0 = Int(cy - r - 1), y1 = Int(cy + r + 1)
        for y in stride(from: max(0, y0), through: min(n - 1, y1), by: 1) {
            for x in stride(from: max(0, x0), through: min(n - 1, x1), by: 1) {
                let dx = Double(x) - cx, dy = Double(y) - cy
                let d = (dx * dx + dy * dy).squareRoot()
                if d <= r + 2.6 { body(x, y, d) }
            }
        }
    }

    func blob(_ x: Double, _ y: Double, _ r: Double, _ t: Terrain) {
        for (ix, iy) in images(x, y) {
            disc(ix, iy, r) { tx, ty, d in if d <= r { set(tx, ty, t) } }
        }
    }

    /// A thick line of terrain (rivers, walls, forest bands), copied by symmetry.
    func line(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double, _ w: Double, _ t: Terrain) {
        let len = ((x1 - x0) * (x1 - x0) + (y1 - y0) * (y1 - y0)).squareRoot()
        let steps = Int(len * 2) + 1
        for i in 0...steps {
            let k = Double(i) / Double(steps)
            blob(x0 + (x1 - x0) * k, y0 + (y1 - y0) * k, w, t)
        }
    }

    /// High ground: a disc raised by one level, ringed by cliffs, with ramps in the given directions.
    func plateau(_ cx: Double, _ cy: Double, _ r: Double, ramps: [(Int, Int)]) {
        let imgs = images(cx, cy)
        for (k, (ix, iy)) in imgs.enumerated() {
            let dirs: [(Double, Double)] = ramps.map { d in
                let (dx, dy) = dirImages(d.0, d.1)[k]
                let l = Double(dx * dx + dy * dy).squareRoot()
                return (Double(dx) / l, Double(dy) / l)
            }
            disc(ix, iy, r) { x, y, d in
                let i = map.index(x, y)
                let dx = Double(x) - ix, dy = Double(y) - iy
                let onRamp = dirs.contains { (ux, uy) in
                    dx * ux + dy * uy > 0 && abs(dx * uy - dy * ux) <= 1.6
                }
                if d <= r {
                    map.elevation[i] = 1
                    if map.terrain[i] != .ramp { map.terrain[i] = .grass }
                } else if d <= r + 1.45 {
                    guard map.elevation[i] == 0 else { return }
                    map.terrain[i] = onRamp ? .ramp : .cliff
                    if onRamp { map.elevation[i] = 1 }
                } else if onRamp && map.terrain[i] != .cliff && map.terrain[i] != .ramp {
                    map.terrain[i] = .dirt   // a clear landing at the foot of the ramp
                }
            }
            keep.append((ix, iy, r + 2))
        }
    }

    func base(_ x: Int, _ y: Int, back: (Int, Int), start: Bool = false, rich: Bool = false) {
        sites.append((x, y, back.0, back.1, start, rich))
        for (ix, iy) in images(Double(x), Double(y)) { keep.append((ix, iy, 8)) }
    }

    func beacon(_ x: Double, _ y: Double) {
        beaconPts.append((x, y))
        for (ix, iy) in images(x, y) { keep.append((ix, iy, 4)) }
    }

    func tower(_ x: Double, _ y: Double) {
        towerPts.append((x, y))
        for (ix, iy) in images(x, y) { keep.append((ix, iy, 3)) }
    }

    /// Random blobs in the hand-made part of the map, away from bases, beacons, towers and plateaus.
    func scatter(_ count: Int, _ t: Terrain, _ rmin: Double, _ rmax: Double, margin: Double = 3) {
        var placed = 0, tries = 0
        while placed < count && tries < count * 30 {
            tries += 1
            let x = rng.range(2, m - 2), y = rng.range(2, m - 2)
            let r = rng.range(rmin, rmax)
            guard inDomain(x, y) else { continue }
            if keep.contains(where: { k in
                let dx = k.0 - x, dy = k.1 - y
                return (dx * dx + dy * dy).squareRoot() < k.2 + r + margin
            }) { continue }
            blob(x, y, r, t)
            placed += 1
        }
    }

    // MARK: the maps

    func layout() {
        switch id {
        case .crossroads:
            plateau(10, 10, 9, ramps: [(1, 1)])
            base(10, 10, back: (-1, -1), start: true)
            base(25, 8, back: (0, -1))
            base(8, 31, back: (-1, 0))
            base(15, 47, back: (-1, 1), rich: true)
            plateau(22, 25, 2.2, ramps: [(1, -1), (-1, 1)])
            tower(22, 25)
            beacon(31.5, 31.5)
            beacon(34, 14)
            scatter(5, .forest, 1.5, 3)
            scatter(12, .rock, 1, 2.4)
            line(30, 40, 36, 46, 1.2, .rock)
        case .twinRivers:
            plateau(9, 9, 9, ramps: [(1, 1)])
            base(9, 9, back: (-1, -1), start: true)
            base(27, 7, back: (0, -1))
            base(7, 27, back: (-1, 0))
            base(30, 20, back: (0, -1), rich: true)
            beacon(31.5, 31.5)
            beacon(14, 49)
            tower(22, 37)
            // the river along the anti-diagonal, with three bridges
            for y in 0..<n {
                for x in 0..<n where abs(x + y - (n - 1)) <= 1 {
                    let fx = Double(x), fy = Double(y)
                    let bridge = [(31.5, 31.5), (14.0, 49.0), (49.0, 14.0)].contains { (bx, by) in
                        (fx - bx) * (fx - bx) + (fy - by) * (fy - by) <= 6.5
                    }
                    set(x, y, bridge ? .dirt : .water)
                }
            }
            scatter(7, .forest, 1.5, 3)
            scatter(8, .rock, 1, 2)
        case .duneSea:
            plateau(9, 31, 8.5, ramps: [(1, 0)])
            base(9, 31, back: (-1, 0), start: true)
            base(12, 11, back: (-1, -1))
            base(12, 51, back: (-1, 1))
            base(31, 7, back: (0, -1), rich: true)
            plateau(24, 20, 3, ramps: [(-1, 0)])
            tower(24, 20)
            beacon(31.5, 31.5)
            beacon(22, 42)
            // mesas: high ground nobody can walk onto (gunships can)
            plateau(36, 18, 2.5, ramps: [])
            plateau(18, 40, 2, ramps: [])
            scatter(10, .rock, 1, 2.2)
            scatter(3, .forest, 1, 1.6)
        case .frostbite:
            plateau(10, 10, 9, ramps: [(1, 0)])
            base(10, 10, back: (-1, -1), start: true)
            base(10, 29, back: (-1, 0))
            base(28, 9, back: (0, -1))
            base(20, 44, back: (-1, 1), rich: true)
            beacon(31.5, 31.5)
            beacon(36, 20)
            tower(26, 28)
            blob(24, 37, 2.8, .water)
            line(18, 22, 22, 18, 1.4, .forest)
            scatter(14, .forest, 1.5, 3.2)
            scatter(5, .rock, 1, 1.8)
        case .highlands:
            plateau(10, 10, 9, ramps: [(1, 1)])
            base(10, 10, back: (-1, -1), start: true)
            base(9, 30, back: (-1, 0))
            base(24, 24, back: (-1, -1), rich: true)
            plateau(39.5, 39.5, 4.5, ramps: [(1, 1), (-1, -1), (1, -1), (-1, 1)])
            tower(39.5, 39.5)
            beacon(39.5, 18)
            scatter(6, .forest, 1.5, 3)
            scatter(8, .rock, 1, 2.4)
            blob(20, 33, 2, .water)
        case .frontier:
            plateau(9, 14, 8, ramps: [(1, 0)])
            base(9, 14, back: (-1, 0), start: true)
            base(9, 65, back: (-1, 0), start: true)
            base(25, 9, back: (0, -1))
            base(25, 70, back: (0, 1))
            base(20, 39, back: (-1, 0), rich: true)
            beacon(39.5, 39.5)
            beacon(33, 22)
            beacon(33, 57)
            tower(33, 39.5)
            plateau(9, 65, 8, ramps: [(1, 0)])
            scatter(12, .rock, 1, 2.4)
            scatter(4, .forest, 1, 2)
        case .caldera:
            blob(39.5, 39.5, 8, .water)
            plateau(10, 10, 9, ramps: [(1, 1)])
            base(10, 10, back: (-1, -1), start: true)
            base(29, 8, back: (0, -1))
            base(27, 27, back: (-1, -1), rich: true)
            beacon(39.5, 22)
            tower(17, 33)
            line(31, 31, 34, 34, 1.5, .water)
            scatter(10, .rock, 1, 2.4)
            scatter(4, .forest, 1, 2)
        }
    }

    // MARK: finishing

    func finish() -> GameMap {
        var siteList: [BaseSite] = []
        for s in sites {
            let imgs = images(Double(s.x), Double(s.y))
            let backs = dirImages(s.bx, s.by)
            for (k, img) in imgs.enumerated() {
                let cx = Int(img.0.rounded()), cy = Int(img.1.rounded())
                clear(cx, cy, 6, .grass)
                clear(cx, cy, 3, .dirt)
                var crystals = MapGen.crystalTiles(cx: cx, cy: cy, back: backs[k])
                if s.rich { crystals = Array(crystals.prefix(6)) }
                for c in crystals { clear(c.x, c.y, 0, .grass) }
                siteList.append(BaseSite(hqOrigin: TilePoint(x: cx - 1, y: cy - 1), crystals: crystals, isStart: s.start, rich: s.rich))
            }
        }
        var beaconTiles: [TilePoint] = []
        for b in beaconPts {
            for img in images(b.0, b.1) {
                let t = TilePoint(x: Int(img.0.rounded()), y: Int(img.1.rounded()))
                if !beaconTiles.contains(where: { abs($0.x - t.x) <= 2 && abs($0.y - t.y) <= 2 }) {
                    beaconTiles.append(t)
                    clear(t.x, t.y, 3, .dirt)
                }
            }
        }
        var towerTiles: [TilePoint] = []
        for b in towerPts {
            for img in images(b.0, b.1) {
                let t = TilePoint(x: Int(img.0.rounded()), y: Int(img.1.rounded()))
                if !towerTiles.contains(where: { abs($0.x - t.x) <= 2 && abs($0.y - t.y) <= 2 }) {
                    towerTiles.append(t)
                    clear(t.x, t.y, 1, .dirt)
                }
            }
        }
        let starts = siteList.filter { $0.isStart }
        map.bases = starts + siteList.filter { !$0.isStart }
        map.beacons = beaconTiles
        map.towers = towerTiles

        // the map edge is a wall
        for i in 0..<n {
            for t in [(i, 0), (i, n - 1), (0, i), (n - 1, i)] {
                let k = map.index(t.0, t.1)
                if map.terrain[k] != .water { map.terrain[k] = .rock }
            }
        }
        // make sure everything that matters is reachable from the first start
        let mid = TilePoint(x: n / 2, y: n / 2)
        var targets = map.bases.map { TilePoint(x: $0.hqOrigin.x + 1, y: $0.hqOrigin.y - 1) }
        targets += map.beacons
        targets += map.towers.map { TilePoint(x: $0.x, y: $0.y + 1) }
        for pass in 0..<4 {
            let reach = flood(from: TilePoint(x: map.bases[0].hqOrigin.x + 1, y: map.bases[0].hqOrigin.y + 3))
            let missing = targets.filter { map.inBounds($0.x, $0.y) && !reach[map.index($0.x, $0.y)] }
            if missing.isEmpty { break }
            for t in missing { carve(from: t, to: mid, throughCliffs: pass >= 2) }
        }
        return map
    }

    private func clear(_ cx: Int, _ cy: Int, _ r: Int, _ t: Terrain) {
        for y in (cy - r)...(cy + r) {
            for x in (cx - r)...(cx + r) where map.inBounds(x, y) {
                let dx = x - cx, dy = y - cy
                guard dx * dx + dy * dy <= r * r + r else { continue }
                let i = map.index(x, y)
                if map.terrain[i] == .cliff || map.terrain[i] == .ramp { continue }
                map.terrain[i] = t
            }
        }
    }

    private func flood(from s: TilePoint) -> [Bool] {
        var seen = Array(repeating: false, count: n * n)
        guard map.inBounds(s.x, s.y), map.terrain[map.index(s.x, s.y)].passable else { return seen }
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

    private func carve(from a: TilePoint, to b: TilePoint, throughCliffs: Bool) {
        let steps = max(abs(b.x - a.x), abs(b.y - a.y)) * 2 + 1
        for i in 0...steps {
            let t = Double(i) / Double(steps)
            let x = Int((Double(a.x) + Double(b.x - a.x) * t).rounded())
            let y = Int((Double(a.y) + Double(b.y - a.y) * t).rounded())
            for dy in -1...1 {
                for dx in -1...1 where map.inBounds(x + dx, y + dy) {
                    let k = map.index(x + dx, y + dy)
                    switch map.terrain[k] {
                    case .rock, .water, .forest: map.terrain[k] = .dirt
                    case .cliff where throughCliffs: map.terrain[k] = .ramp; map.elevation[k] = 1
                    default: break
                    }
                }
            }
        }
    }
}

extension MapGen {
    static func crystalTiles(cx: Int, cy: Int, back: (Int, Int)) -> [TilePoint] {
        let (bx, by) = back
        var offs: [(Int, Int)]
        if bx != 0 && by != 0 {
            offs = [(-5, 1), (-5, 0), (-5, -1), (-4, -3), (-3, -4), (-1, -5), (0, -5), (1, -5)]
            offs = offs.map { (bx < 0 ? $0.0 : -$0.0, by < 0 ? $0.1 : -$0.1) }
        } else {
            offs = [(-5, -3), (-5, -2), (-6, -1), (-6, 0), (-6, 1), (-5, 2), (-5, 3), (-4, 4)]
            offs = offs.map { o in
                if bx < 0 { return o }
                if bx > 0 { return (-o.0, -o.1) }
                if by < 0 { return (o.1, o.0) }
                return (-o.1, -o.0)
            }
        }
        return offs.map { TilePoint(x: cx + $0.0, y: cy + $0.1) }
    }
}
