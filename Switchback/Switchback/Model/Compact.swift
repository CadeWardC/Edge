import Foundation

/// Lines stored as encoded polylines (Google's format, 1e-5° ≈ 1 m): about 6 characters a point instead of ~40
/// for a pair of JSON numbers.
enum Polyline {
    static func encode(_ coords: [Coord]) -> String {
        var out = [UInt8]()
        out.reserveCapacity(coords.count * 8)
        var pLat = 0, pLon = 0
        for c in coords {
            let lat = Int((c.lat * 1e5).rounded()), lon = Int((c.lon * 1e5).rounded())
            append(lat - pLat, to: &out)
            append(lon - pLon, to: &out)
            pLat = lat
            pLon = lon
        }
        return String(decoding: out, as: UTF8.self)
    }

    private static func append(_ v: Int, to out: inout [UInt8]) {
        var x = v < 0 ? ~(v << 1) : (v << 1)
        while x >= 0x20 {
            out.append(UInt8((0x20 | (x & 0x1f)) + 63))
            x >>= 5
        }
        out.append(UInt8(x + 63))
    }

    /// Plain integers written in the same alphabet (the elevation charts in trail packs).
    static func decodeInts(_ s: String) -> [Int] {
        let bytes = Array(s.utf8)
        var i = 0
        var out: [Int] = []
        while i < bytes.count {
            var result = 0, shift = 0
            while i < bytes.count {
                let b = Int(bytes[i]) - 63
                i += 1
                result |= (b & 0x1f) << shift
                shift += 5
                if b < 0x20 { break }
            }
            out.append((result & 1) != 0 ? ~(result >> 1) : (result >> 1))
        }
        return out
    }

    static func decode(_ s: String) -> [Coord] {
        let bytes = Array(s.utf8)
        var i = 0
        var lat = 0, lon = 0
        var out: [Coord] = []
        out.reserveCapacity(bytes.count / 6)
        func next() -> Int? {
            var result = 0, shift = 0
            while i < bytes.count {
                let b = Int(bytes[i]) - 63
                i += 1
                result |= (b & 0x1f) << shift
                shift += 5
                if b < 0x20 { return (result & 1) != 0 ? ~(result >> 1) : (result >> 1) }
            }
            return nil
        }
        while i < bytes.count {
            guard let dLat = next(), let dLon = next() else { break }
            lat += dLat
            lon += dLon
            out.append(Coord(lat: Double(lat) / 1e5, lon: Double(lon) / 1e5))
        }
        return out
    }
}

/// Files are written compressed (LZFSE, Apple's fast compressor) behind a small marker, and read either way,
/// so files from earlier versions still load.
enum Compression {
    private static let magic = Data("SBZ1".utf8)

    static func pack(_ data: Data) -> Data {
        guard data.count > 512, let z = try? (data as NSData).compressed(using: .lzfse) as Data, z.count < data.count else {
            return data
        }
        return magic + z
    }

    static func unpack(_ data: Data) -> Data {
        guard data.count > magic.count, data.prefix(magic.count) == magic else { return data }
        let body = data.dropFirst(magic.count)
        return (try? (Data(body) as NSData).decompressed(using: .lzfse) as Data) ?? data
    }
}

extension Trail {
    private enum CodingKeys: String, CodingKey {
        case id, name, source, osmId, segments, path, pathIndex, length, tags, profile, elev
    }

    /// Elevation as trail packs store it: totals from the full 10 m samples, and only the chart points that
    /// matter, as (steps, metres) deltas.
    private struct PackedElevation: Decodable {
        let s: Double
        let p: String
        let g: Double
        let l: Double
        let mn: Double
        let mx: Double

        var profile: ElevationProfile? {
            let ints = Polyline.decodeInts(p)
            guard ints.count >= 4 else { return nil }
            var distances: [Double] = [], elevations: [Double] = []
            var step = 0, height = 0
            var i = 0
            while i + 1 < ints.count {
                step += ints[i]
                height += ints[i + 1]
                distances.append(Double(step) * s)
                elevations.append(Double(height))
                i += 2
            }
            var profile = ElevationProfile(distances: distances, elevations: elevations)
            profile.gain = g
            profile.loss = l
            profile.minElevation = mn
            profile.maxElevation = mx
            return profile
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let segments: [[Coord]]
        if let encoded = try? c.decode([String].self, forKey: .segments) {
            segments = encoded.map(Polyline.decode)
        } else {
            segments = try c.decode([[Coord]].self, forKey: .segments)
        }
        let path: [Coord]
        if let i = try c.decodeIfPresent(Int.self, forKey: .pathIndex), segments.indices.contains(i) {
            path = segments[i]
        } else if let encoded = try? c.decode(String.self, forKey: .path) {
            path = Polyline.decode(encoded)
        } else {
            path = try c.decode([Coord].self, forKey: .path)
        }
        self.init(id: try c.decode(String.self, forKey: .id),
                  name: try c.decode(String.self, forKey: .name),
                  source: try c.decode(Source.self, forKey: .source),
                  osmId: try c.decodeIfPresent(Int64.self, forKey: .osmId),
                  segments: segments, path: path,
                  length: try c.decode(Double.self, forKey: .length),
                  tags: try c.decodeIfPresent([String: String].self, forKey: .tags) ?? [:],
                  profile: try c.decodeIfPresent(ElevationProfile.self, forKey: .profile)
                      ?? (try? c.decodeIfPresent(PackedElevation.self, forKey: .elev))?.profile)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(source, forKey: .source)
        try c.encodeIfPresent(osmId, forKey: .osmId)
        try c.encode(segments.map(Polyline.encode), forKey: .segments)
        // the main line is usually one of the segments: store just which one
        if let i = segments.firstIndex(of: path) {
            try c.encode(i, forKey: .pathIndex)
        } else {
            try c.encode(Polyline.encode(path), forKey: .path)
        }
        try c.encode((length * 10).rounded() / 10, forKey: .length)
        if !tags.isEmpty { try c.encode(tags, forKey: .tags) }
        try c.encodeIfPresent(profile, forKey: .profile)
    }
}

extension ElevationProfile {
    private enum CodingKeys: String, CodingKey {
        case distances, elevations, gain, loss, minElevation, maxElevation
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(distances: try c.decode([Double].self, forKey: .distances),
                  elevations: try c.decode([Double].self, forKey: .elevations))
        // keep the stored totals (they may have been worked out with a different threshold)
        if let g = try c.decodeIfPresent(Double.self, forKey: .gain) { gain = g }
        if let l = try c.decodeIfPresent(Double.self, forKey: .loss) { loss = l }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        // a metre is plenty for a chart
        try c.encode(distances.map { $0.rounded() }, forKey: .distances)
        try c.encode(elevations.map { ($0 * 10).rounded() / 10 }, forKey: .elevations)
        try c.encode(gain.rounded(), forKey: .gain)
        try c.encode(loss.rounded(), forKey: .loss)
        try c.encode(minElevation, forKey: .minElevation)
        try c.encode(maxElevation, forKey: .maxElevation)
    }
}
