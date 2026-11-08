import Foundation

/// Buckets entities by position so "who is near me" is cheap.
final class SpatialGrid {
    let cell: Double = 64
    let cols: Int
    let rows: Int
    private var buckets: [[Entity]]

    init(width: Double, height: Double) {
        cols = Int(width / cell) + 1
        rows = Int(height / cell) + 1
        buckets = Array(repeating: [], count: cols * rows)
    }

    func rebuild(_ entities: [Entity]) {
        for i in 0..<buckets.count { buckets[i].removeAll(keepingCapacity: true) }
        for e in entities where e.alive {
            buckets[index(e.pos)].append(e)
        }
    }

    private func index(_ p: Vec2) -> Int {
        let cx = min(cols - 1, max(0, Int(p.x / cell)))
        let cy = min(rows - 1, max(0, Int(p.y / cell)))
        return cy * cols + cx
    }

    /// Calls `body` for every entity whose body overlaps the circle. Order is deterministic (cell by cell, then
    /// insertion order, which follows entity id).
    func query(_ c: Vec2, _ r: Double, _ body: (Entity) -> Void) {
        let reach = r + 50   // largest entity radius
        let x0 = max(0, Int((c.x - reach) / cell)), x1 = min(cols - 1, Int(max(0, c.x + reach) / cell))
        let y0 = max(0, Int((c.y - reach) / cell)), y1 = min(rows - 1, Int(max(0, c.y + reach) / cell))
        if x0 > x1 || y0 > y1 { return }
        for cy in y0...y1 {
            for cx in x0...x1 {
                for e in buckets[cy * cols + cx] where e.alive {
                    let rr = r + e.st.radius
                    if e.pos.distSq(c) <= rr * rr { body(e) }
                }
            }
        }
    }
}

/// What each team can see. 0 = never seen, 1 = seen before, 2 = in sight now. One cell per map tile.
final class Fog {
    let width: Int
    let height: Int
    private(set) var cells: [[UInt8]]    // per team
    /// Bumped on every update so the renderer knows when to redraw.
    private(set) var version = 0

    init(width: Int, height: Int, teams: Int) {
        self.width = width
        self.height = height
        cells = Array(repeating: Array(repeating: 0, count: width * height), count: max(1, teams))
    }

    func update(_ world: World) {
        for t in 0..<cells.count {
            for i in 0..<cells[t].count where cells[t][i] == 2 { cells[t][i] = 1 }
        }
        for e in world.entities where e.alive && e.team >= 0 && e.team < cells.count {
            if e.isBuilding && e.progress < 0.05 && e.type != .hq { continue }
            reveal(team: e.team, at: e.pos, radius: e.st.sight)
        }
        version += 1
    }

    private func reveal(team: Int, at p: Vec2, radius: Double) {
        let rt = radius / Defs.tile
        let cx = p.x / Defs.tile, cy = p.y / Defs.tile
        let x0 = max(0, Int(cx - rt)), x1 = min(width - 1, Int(cx + rt))
        let y0 = max(0, Int(cy - rt)), y1 = min(height - 1, Int(cy + rt))
        if x0 > x1 || y0 > y1 { return }
        let r2 = rt * rt
        for y in y0...y1 {
            let dy = Double(y) + 0.5 - cy
            for x in x0...x1 {
                let dx = Double(x) + 0.5 - cx
                if dx * dx + dy * dy <= r2 { cells[team][y * width + x] = 2 }
            }
        }
    }

    func state(team: Int, x: Int, y: Int) -> UInt8 {
        guard team >= 0 else { return 2 }
        guard team < cells.count, x >= 0, y >= 0, x < width, y < height else { return 0 }
        return cells[team][y * width + x]
    }

    func visible(team: Int, _ p: Vec2) -> Bool {
        state(team: team, x: Int(p.x / Defs.tile), y: Int(p.y / Defs.tile)) == 2
    }

    func explored(team: Int, _ p: Vec2) -> Bool {
        state(team: team, x: Int(p.x / Defs.tile), y: Int(p.y / Defs.tile)) >= 1
    }
}
