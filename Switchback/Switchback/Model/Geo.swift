import CoreLocation
import Foundation
import MapKit

/// A latitude/longitude pair that can be saved to disk.
struct Coord: Codable, Hashable {
    var lat: Double
    var lon: Double

    init(lat: Double, lon: Double) {
        self.lat = lat
        self.lon = lon
    }

    init(_ c: CLLocationCoordinate2D) {
        lat = c.latitude
        lon = c.longitude
    }

    var cl: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }
}

/// A latitude/longitude box (south/west/north/east), as Overpass uses them.
struct BBox: Codable, Hashable {
    var south: Double
    var west: Double
    var north: Double
    var east: Double

    init(south: Double, west: Double, north: Double, east: Double) {
        self.south = south
        self.west = west
        self.north = north
        self.east = east
    }

    init?(coords: [Coord]) {
        guard let first = coords.first else { return nil }
        var s = first.lat, n = first.lat, w = first.lon, e = first.lon
        for c in coords {
            s = min(s, c.lat); n = max(n, c.lat)
            w = min(w, c.lon); e = max(e, c.lon)
        }
        self.init(south: s, west: w, north: n, east: e)
    }

    init(region: MKCoordinateRegion) {
        let c = region.center
        let dLat = region.span.latitudeDelta / 2, dLon = region.span.longitudeDelta / 2
        self.init(south: max(-85, c.latitude - dLat), west: max(-180, c.longitude - dLon),
                  north: min(85, c.latitude + dLat), east: min(180, c.longitude + dLon))
    }

    var center: Coord { Coord(lat: (south + north) / 2, lon: (west + east) / 2) }
    var latSpan: Double { north - south }
    var lonSpan: Double { east - west }

    func region(padding: Double = 1.25) -> MKCoordinateRegion {
        MKCoordinateRegion(center: center.cl,
                           span: MKCoordinateSpan(latitudeDelta: max(latSpan * padding, 0.005),
                                                  longitudeDelta: max(lonSpan * padding, 0.005)))
    }

    func contains(_ c: Coord) -> Bool {
        c.lat >= south && c.lat <= north && c.lon >= west && c.lon <= east
    }

    func intersects(_ o: BBox) -> Bool {
        !(o.west > east || o.east < west || o.south > north || o.north < south)
    }

    func expanded(byDegrees d: Double) -> BBox {
        BBox(south: south - d, west: west - d, north: north + d, east: east + d)
    }

    /// The same box, shrunk around its centre so neither side is longer than `maxSpan` degrees.
    func clamped(maxSpan: Double) -> BBox {
        let c = center
        let hLat = min(latSpan, maxSpan) / 2, hLon = min(lonSpan, maxSpan) / 2
        return BBox(south: c.lat - hLat, west: c.lon - hLon, north: c.lat + hLat, east: c.lon + hLon)
    }

    /// Splits the box into cells no bigger than `cell` degrees.
    func tiles(cell: Double) -> [BBox] {
        let rows = max(1, Int((latSpan / cell).rounded(.up)))
        let cols = max(1, Int((lonSpan / cell).rounded(.up)))
        var out: [BBox] = []
        for r in 0..<rows {
            for c in 0..<cols {
                out.append(BBox(south: south + latSpan * Double(r) / Double(rows),
                                west: west + lonSpan * Double(c) / Double(cols),
                                north: south + latSpan * Double(r + 1) / Double(rows),
                                east: west + lonSpan * Double(c + 1) / Double(cols)))
            }
        }
        return out
    }

    var overpass: String {
        String(format: "%.5f,%.5f,%.5f,%.5f", south, west, north, east)
    }
}

enum Geo {
    static let earthRadius = 6_371_000.0
    static let metersPerDegree = 111_320.0

    /// Great-circle distance in metres.
    static func distance(_ a: Coord, _ b: Coord) -> Double {
        let dLat = (b.lat - a.lat) * .pi / 180
        let dLon = (b.lon - a.lon) * .pi / 180
        let la1 = a.lat * .pi / 180, la2 = b.lat * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(la1) * cos(la2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * earthRadius * asin(min(1, sqrt(h)))
    }

    static func length(_ pts: [Coord]) -> Double {
        guard pts.count > 1 else { return 0 }
        var total = 0.0
        for i in 1..<pts.count { total += distance(pts[i - 1], pts[i]) }
        return total
    }

    /// Distance from the start to each point.
    static func cumulative(_ pts: [Coord]) -> [Double] {
        var out: [Double] = []
        out.reserveCapacity(pts.count)
        var total = 0.0
        for i in pts.indices {
            if i > 0 { total += distance(pts[i - 1], pts[i]) }
            out.append(total)
        }
        return out
    }

    /// `count` points spread evenly along the line, with their distance from the start.
    static func resample(_ pts: [Coord], count: Int) -> [(coord: Coord, distance: Double)] {
        guard pts.count > 1, count > 1 else { return pts.map { (coord: $0, distance: 0) } }
        let cum = cumulative(pts)
        let total = cum[cum.count - 1]
        guard total > 0 else { return [(coord: pts[0], distance: 0)] }
        var out: [(coord: Coord, distance: Double)] = []
        var j = 0
        for i in 0..<count {
            let d = total * Double(i) / Double(count - 1)
            while j < pts.count - 2 && cum[j + 1] < d { j += 1 }
            let seg = cum[j + 1] - cum[j]
            let t = seg > 0 ? min(1, max(0, (d - cum[j]) / seg)) : 0
            let c = Coord(lat: pts[j].lat + (pts[j + 1].lat - pts[j].lat) * t,
                          lon: pts[j].lon + (pts[j + 1].lon - pts[j].lon) * t)
            out.append((coord: c, distance: d))
        }
        return out
    }

    /// Distance in metres from `p` to the segment a–b, and where along it (0…1) the closest point is.
    static func project(_ p: Coord, _ a: Coord, _ b: Coord) -> (distance: Double, t: Double) {
        let k = cos(p.lat * .pi / 180) * metersPerDegree
        let ax = (a.lon - p.lon) * k, ay = (a.lat - p.lat) * metersPerDegree
        let bx = (b.lon - p.lon) * k, by = (b.lat - p.lat) * metersPerDegree
        let dx = bx - ax, dy = by - ay
        let len2 = dx * dx + dy * dy
        let t = len2 > 0 ? max(0, min(1, -(ax * dx + ay * dy) / len2)) : 0
        let x = ax + t * dx, y = ay + t * dy
        return (distance: sqrt(x * x + y * y), t: t)
    }

    /// Shortest distance in metres from `p` to any of the lines.
    static func distanceToPath(_ p: Coord, segments: [[Coord]]) -> Double {
        var best = Double.infinity
        for seg in segments {
            if seg.count == 1 { best = min(best, distance(p, seg[0])) }
            guard seg.count > 1 else { continue }
            for i in 1..<seg.count {
                best = min(best, project(p, seg[i - 1], seg[i]).distance)
            }
        }
        return best
    }

    /// How far along the line the point closest to `p` is, and how far `p` is from the line.
    static func locate(_ p: Coord, on path: [Coord], cumulative cum: [Double]) -> (along: Double, offset: Double)? {
        guard path.count > 1, cum.count == path.count else { return nil }
        var best: (along: Double, offset: Double)?
        for i in 1..<path.count {
            let r = project(p, path[i - 1], path[i])
            if best == nil || r.distance < best!.offset {
                best = (along: cum[i - 1] + (cum[i] - cum[i - 1]) * r.t, offset: r.distance)
            }
        }
        return best
    }
}

/// Joins line pieces that share end points into the longest continuous lines.
enum Chains {
    static func build(_ pieces: [[Coord]]) -> [[Coord]] {
        var remaining = pieces.filter { $0.count >= 2 }
        var chains: [[Coord]] = []
        while !remaining.isEmpty {
            var chain = remaining.removeFirst()
            var extended = true
            while extended {
                extended = false
                for i in remaining.indices {
                    let p = remaining[i]
                    guard let cFirst = chain.first, let cLast = chain.last,
                          let pFirst = p.first, let pLast = p.last else { continue }
                    if near(cLast, pFirst) {
                        chain.append(contentsOf: p.dropFirst())
                    } else if near(cLast, pLast) {
                        chain.append(contentsOf: Array(p.reversed()).dropFirst())
                    } else if near(cFirst, pLast) {
                        chain = p + Array(chain.dropFirst())
                    } else if near(cFirst, pFirst) {
                        chain = Array(p.reversed()) + Array(chain.dropFirst())
                    } else {
                        continue
                    }
                    remaining.remove(at: i)
                    extended = true
                    break
                }
            }
            chains.append(chain)
        }
        return chains
    }

    static func near(_ a: Coord, _ b: Coord) -> Bool {
        abs(a.lat - b.lat) < 0.00002 && abs(a.lon - b.lon) < 0.00003
    }
}
