import Foundation

enum Terrain: UInt8 {
    case grass, dirt, rock, water

    var passable: Bool { self == .grass || self == .dirt }
}

struct TilePoint: Equatable, Hashable, Codable {
    var x: Int
    var y: Int
}

/// A place to build a Command Center, with its crystal field.
struct BaseSite {
    var hqOrigin: TilePoint          // bottom-left tile of the 3x3 footprint
    var crystals: [TilePoint]
    var isStart: Bool

    var center: Vec2 { Vec2(Double(hqOrigin.x) * Defs.tile + 1.5 * Defs.tile, Double(hqOrigin.y) * Defs.tile + 1.5 * Defs.tile) }
}

final class GameMap {
    let id: MapID
    let width: Int
    let height: Int
    var terrain: [Terrain]
    /// Buildings and crystals currently standing on each tile (entity id, 0 = none).
    var occupant: [Int]
    var bases: [BaseSite] = []
    var beacons: [TilePoint] = []
    /// Decoration seed per tile for the renderer.
    let decoSeed: UInt64

    var worldWidth: Double { Double(width) * Defs.tile }
    var worldHeight: Double { Double(height) * Defs.tile }
    var starts: [BaseSite] { bases.filter { $0.isStart } }

    init(id: MapID, width: Int, height: Int, seed: UInt64) {
        self.id = id
        self.width = width
        self.height = height
        terrain = Array(repeating: .grass, count: width * height)
        occupant = Array(repeating: 0, count: width * height)
        decoSeed = seed
    }

    @inline(__always) func inBounds(_ x: Int, _ y: Int) -> Bool { x >= 0 && y >= 0 && x < width && y < height }
    @inline(__always) func index(_ x: Int, _ y: Int) -> Int { y * width + x }

    func terrainAt(_ x: Int, _ y: Int) -> Terrain { inBounds(x, y) ? terrain[index(x, y)] : .rock }

    /// Ground units can stand here.
    @inline(__always) func walkable(_ x: Int, _ y: Int) -> Bool {
        guard inBounds(x, y) else { return false }
        let i = index(x, y)
        return terrain[i].passable && occupant[i] == 0
    }

    func tile(of p: Vec2) -> TilePoint {
        var tx = Int(p.x / Defs.tile)
        var ty = Int(p.y / Defs.tile)
        if p.x < 0 { tx = -1 }
        if p.y < 0 { ty = -1 }
        return TilePoint(x: tx, y: ty)
    }

    func center(_ t: TilePoint) -> Vec2 { Vec2((Double(t.x) + 0.5) * Defs.tile, (Double(t.y) + 0.5) * Defs.tile) }

    func walkable(at p: Vec2) -> Bool {
        let t = tile(of: p)
        return walkable(t.x, t.y)
    }

    /// True when a straight walk from a to b (with some body width) only crosses walkable tiles.
    func lineClear(_ a: Vec2, _ b: Vec2, halfWidth: Double = 8) -> Bool {
        let d = b - a
        let len = d.length
        if len < 1 { return walkable(at: b) }
        let dir = d / len
        let side = dir.perp * halfWidth
        let steps = Int(len / 10) + 1
        for i in 0...steps {
            let p = a + d * (Double(i) / Double(steps))
            if !walkable(at: p) || !walkable(at: p + side) || !walkable(at: p - side) { return false }
        }
        return true
    }

    /// The walkable tile closest to `t` (breadth-first), or nil if none within the limit.
    func nearestWalkable(_ t: TilePoint, maxRadius: Int = 12) -> TilePoint? {
        if walkable(t.x, t.y) { return t }
        for r in 1...maxRadius {
            var best: TilePoint?
            var bestD = Int.max
            for dy in -r...r {
                for dx in -r...r where abs(dx) == r || abs(dy) == r {
                    let x = t.x + dx, y = t.y + dy
                    if walkable(x, y) {
                        let d = dx * dx + dy * dy
                        if d < bestD { bestD = d; best = TilePoint(x: x, y: y) }
                    }
                }
            }
            if let best { return best }
        }
        return nil
    }

    /// Can a building with this footprint go at this origin (terrain only; units are checked by the world)?
    func canPlace(origin: TilePoint, size: Int) -> Bool {
        for y in origin.y..<(origin.y + size) {
            for x in origin.x..<(origin.x + size) {
                if !walkable(x, y) { return false }
            }
        }
        return true
    }

    func setOccupant(origin: TilePoint, size: Int, id: Int) {
        for y in origin.y..<(origin.y + size) {
            for x in origin.x..<(origin.x + size) where inBounds(x, y) {
                occupant[index(x, y)] = id
            }
        }
    }
}
