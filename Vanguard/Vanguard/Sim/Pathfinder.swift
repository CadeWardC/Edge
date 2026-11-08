import Foundation

/// A* on the tile grid (8 directions, no corner cutting), then string-pulled into a few straight legs.
final class Pathfinder {
    private let map: GameMap
    private var g: [Double]
    private var parent: [Int32]
    private var stamp: [UInt32]
    private var closed: [UInt32]
    private var generation: UInt32 = 0
    private var heap: [(f: Double, i: Int32)] = []
    /// Same-tick cache: many units ordered to the same place usually share start tiles.
    private var cache: [Int: [Vec2]] = [:]
    private var cacheTick = -1
    var searches = 0

    init(map: GameMap) {
        self.map = map
        let n = map.width * map.height
        g = Array(repeating: 0, count: n)
        parent = Array(repeating: -1, count: n)
        stamp = Array(repeating: 0, count: n)
        closed = Array(repeating: 0, count: n)
    }

    func path(from a: Vec2, to b: Vec2, tick: Int, halfWidth: Double) -> [Vec2] {
        if tick != cacheTick { cache.removeAll(keepingCapacity: true); cacheTick = tick }
        if map.lineClear(a, b, halfWidth: halfWidth) { return [b] }
        var st = map.tile(of: a)
        if !map.walkable(st.x, st.y), let w = map.nearestWalkable(st, maxRadius: 3) { st = w }
        guard var gt = map.nearestWalkable(map.tile(of: b), maxRadius: 14) else { return [b] }
        if !map.walkable(st.x, st.y) { return [b] }
        let goalIsExact = map.tile(of: b) == gt
        if st == gt { return [goalIsExact ? b : map.center(gt)] }
        let key = (map.index(st.x, st.y) << 16) ^ map.index(gt.x, gt.y)
        if let c = cache[key] {
            var p = c
            if goalIsExact, !p.isEmpty { p[p.count - 1] = b }
            return p
        }
        guard let tiles = search(st, &gt) else { return [b] }
        var pts = tiles.map { map.center($0) }
        if goalIsExact, !pts.isEmpty { pts[pts.count - 1] = b }
        let smooth = smoothPath(from: a, pts, halfWidth: halfWidth)
        cache[key] = smooth
        return smooth
    }

    private func search(_ s: TilePoint, _ goal: inout TilePoint) -> [TilePoint]? {
        searches += 1
        generation &+= 1
        if generation == 0 {
            for i in 0..<stamp.count { stamp[i] = 0; closed[i] = 0 }
            generation = 1
        }
        let w = map.width
        let si = map.index(s.x, s.y), gi = map.index(goal.x, goal.y)
        heap.removeAll(keepingCapacity: true)
        g[si] = 0
        parent[si] = -1
        stamp[si] = generation
        push(h(si, gi, w), Int32(si))
        var best = si
        var bestH = h(si, gi, w)
        var expanded = 0
        let dirs: [(Int, Int, Double)] = [(1, 0, 1), (-1, 0, 1), (0, 1, 1), (0, -1, 1),
                                          (1, 1, 1.41421356), (-1, 1, 1.41421356), (1, -1, 1.41421356), (-1, -1, 1.41421356)]
        while let top = pop() {
            let ci = Int(top.i)
            if closed[ci] == generation { continue }
            closed[ci] = generation
            if ci == gi { best = ci; break }
            expanded += 1
            if expanded > 9000 { break }
            let hh = h(ci, gi, w)
            if hh < bestH { bestH = hh; best = ci }
            let cx = ci % w, cy = ci / w
            for (dx, dy, cost) in dirs {
                let nx = cx + dx, ny = cy + dy
                guard map.walkable(nx, ny) else { continue }
                if dx != 0 && dy != 0 && (!map.walkable(cx + dx, cy) || !map.walkable(cx, cy + dy)) { continue }
                let ni = ny * w + nx
                if closed[ni] == generation { continue }
                let ng = g[ci] + cost
                if stamp[ni] != generation || ng < g[ni] {
                    stamp[ni] = generation
                    g[ni] = ng
                    parent[ni] = Int32(ci)
                    push(ng + h(ni, gi, w), Int32(ni))
                }
            }
        }
        if best != gi { goal = TilePoint(x: best % w, y: best / w) }
        var out: [TilePoint] = []
        var c = best
        while c != -1 && c != si {
            out.append(TilePoint(x: c % w, y: c / w))
            c = Int(parent[c])
        }
        if out.isEmpty { return nil }
        return out.reversed()
    }

    private func smoothPath(from a: Vec2, _ pts: [Vec2], halfWidth: Double) -> [Vec2] {
        var out: [Vec2] = []
        var cur = a
        var i = 0
        while i < pts.count {
            var j = pts.count - 1
            while j > i && !map.lineClear(cur, pts[j], halfWidth: halfWidth) { j -= 1 }
            out.append(pts[j])
            cur = pts[j]
            i = j + 1
        }
        return out
    }

    @inline(__always) private func h(_ a: Int, _ b: Int, _ w: Int) -> Double {
        let dx = Double(abs(a % w - b % w)), dy = Double(abs(a / w - b / w))
        return dx + dy + (1.41421356 - 2) * min(dx, dy)
    }

    // binary min-heap (ties broken by tile index so the result never depends on insertion details)
    private func less(_ a: (f: Double, i: Int32), _ b: (f: Double, i: Int32)) -> Bool {
        a.f < b.f || (a.f == b.f && a.i < b.i)
    }
    private func push(_ f: Double, _ i: Int32) {
        heap.append((f, i))
        var c = heap.count - 1
        while c > 0 {
            let p = (c - 1) / 2
            if less(heap[c], heap[p]) { heap.swapAt(c, p); c = p } else { break }
        }
    }
    private func pop() -> (f: Double, i: Int32)? {
        guard !heap.isEmpty else { return nil }
        let top = heap[0]
        let last = heap.removeLast()
        if !heap.isEmpty {
            heap[0] = last
            var c = 0
            while true {
                let l = 2 * c + 1, r = l + 1
                var m = c
                if l < heap.count && less(heap[l], heap[m]) { m = l }
                if r < heap.count && less(heap[r], heap[m]) { m = r }
                if m == c { break }
                heap.swapAt(c, m)
                c = m
            }
        }
        return top
    }
}
