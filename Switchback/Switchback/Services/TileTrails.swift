import Foundation

/// Trails read straight from the map's own vector tiles (named paths and tracks), so they appear the moment the map
/// does. They're previews: the pieces are cut at tile edges, so they're shown until the full trail search (Overpass)
/// brings the exact version of the same trail.
enum TileTrails {
    static let previewTag = "switchback:preview"

    /// `pieces` are the lines found for each trail name.
    static func build(_ pieces: [String: [[Coord]]]) -> [Trail] {
        var out: [Trail] = []
        for (name, lines) in pieces {
            for group in cluster(lines.filter { $0.count > 1 }) {
                let measured = group.map { (coords: $0, length: Geo.length($0)) }
                // tiles overlap a little at their edges, so pieces repeat a few metres: trim the total slightly
                let total = measured.reduce(0) { $0 + $1.length } * 0.98
                guard total >= 300, let main = measured.max(by: { $0.length < $1.length }), let first = main.coords.first else { continue }
                out.append(Trail(id: String(format: "t%@-%.2f,%.2f", name, first.lat, first.lon), name: name, source: .osmWay,
                                 osmId: nil, segments: group, path: main.coords, length: total,
                                 tags: [previewTag: "yes"], profile: nil))
            }
        }
        return out
    }

    /// Groups pieces of a name that touch (within ~150 m), so two different paths that share a name stay apart.
    private static func cluster(_ lines: [[Coord]]) -> [[[Coord]]] {
        var groups: [(box: BBox, lines: [[Coord]])] = []
        for line in lines {
            guard let box = BBox(coords: line) else { continue }
            let near = box.expanded(byDegrees: 0.0015)
            var merged = (box: box, lines: [line])
            var rest: [(box: BBox, lines: [[Coord]])] = []
            for g in groups {
                if g.box.intersects(near) {
                    merged.lines += g.lines
                    merged.box = BBox(south: min(merged.box.south, g.box.south), west: min(merged.box.west, g.box.west),
                                      north: max(merged.box.north, g.box.north), east: max(merged.box.east, g.box.east))
                } else {
                    rest.append(g)
                }
            }
            groups = rest + [merged]
        }
        return groups.map(\.lines)
    }
}

extension Trail {
    /// Read from the map tiles, waiting for the exact version.
    var isPreview: Bool { tags[TileTrails.previewTag] == "yes" }
}
