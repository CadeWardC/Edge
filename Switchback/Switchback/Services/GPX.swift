import Foundation
import UniformTypeIdentifiers

extension UTType {
    static let gpx = UTType(importedAs: "com.topografix.gpx", conformingTo: .xml)
}

enum GPXError: LocalizedError {
    case noPoints

    var errorDescription: String? { "The file has no track or route points." }
}

struct GPXPoint {
    var lat: Double
    var lon: Double
    var ele: Double?
    var time: Date?
}

/// Reads and writes GPX 1.1 tracks.
enum GPX {
    static func parse(_ data: Data) throws -> (name: String?, segments: [[GPXPoint]]) {
        let reader = GPXReader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        guard parser.parse() || !reader.segments.isEmpty else {
            throw parser.parserError ?? GPXError.noPoints
        }
        let segs = reader.segments.filter { $0.count > 1 }
        guard !segs.isEmpty else { throw GPXError.noPoints }
        return (name: reader.name, segments: segs)
    }

    static func trail(from data: Data, fallbackName: String) throws -> Trail {
        let file = try parse(data)
        let segments = file.segments.map { $0.map { Coord(lat: $0.lat, lon: $0.lon) } }
        let points = file.segments.flatMap { $0 }
        let path = points.map { Coord(lat: $0.lat, lon: $0.lon) }

        var profile: ElevationProfile?
        if points.allSatisfy({ $0.ele != nil }) {
            let cum = Geo.cumulative(path)
            let step = max(1, points.count / 400)
            let idx = Array(stride(from: 0, to: points.count, by: step))
            profile = ElevationProfile(distances: idx.map { cum[$0] }, elevations: idx.map { points[$0].ele ?? 0 }, threshold: 3)
        }
        let name = (file.name?.isEmpty == false ? file.name : nil) ?? fallbackName
        return Trail(id: "gpx-\(UUID().uuidString)", name: name, source: .imported, osmId: nil,
                     segments: segments, path: path, length: Geo.length(path), tags: [:], profile: profile)
    }

    // MARK: - Writing

    private static let timeFormatter = ISO8601DateFormatter()

    static func document(name: String, segments: [[(coord: Coord, ele: Double?, time: Date?)]]) -> String {
        var s = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="Switchback" xmlns="http://www.topografix.com/GPX/1/1">
          <metadata><name>\(escape(name))</name></metadata>
          <trk>
            <name>\(escape(name))</name>

        """
        for seg in segments {
            s += "    <trkseg>\n"
            for p in seg {
                s += String(format: "      <trkpt lat=\"%.7f\" lon=\"%.7f\">", p.coord.lat, p.coord.lon)
                if let e = p.ele { s += String(format: "<ele>%.1f</ele>", e) }
                if let t = p.time { s += "<time>\(timeFormatter.string(from: t))</time>" }
                s += "</trkpt>\n"
            }
            s += "    </trkseg>\n"
        }
        s += "  </trk>\n</gpx>\n"
        return s
    }

    static func document(for trail: Trail) -> String {
        document(name: trail.name, segments: trail.segments.map { $0.map { (coord: $0, ele: Double?.none, time: Date?.none) } })
    }

    static func document(for activity: Activity) -> String {
        document(name: activity.name, segments: activity.segments.map { $0.map { (coord: $0.coord, ele: $0.alt, time: $0.time) } })
    }

    /// Writes the GPX to a temporary file named after the trail, ready to share.
    static func file(named name: String, contents: String) throws -> URL {
        let safe = name.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined(separator: "-")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gpx", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent((safe.isEmpty ? "Track" : safe) + ".gpx")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

private final class GPXReader: NSObject, XMLParserDelegate {
    var name: String?
    var segments: [[GPXPoint]] = []
    private var current: [GPXPoint] = []
    private var point: GPXPoint?
    private var text = ""
    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plain = ISO8601DateFormatter()

    private func local(_ name: String) -> String {
        (name.split(separator: ":").last.map(String.init) ?? name).lowercased()
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        text = ""
        switch local(elementName) {
        case "trkseg", "rte":
            current = []
        case "trkpt", "rtept":
            if let lat = attributeDict["lat"].flatMap(Double.init), let lon = attributeDict["lon"].flatMap(Double.init) {
                point = GPXPoint(lat: lat, lon: lon)
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch local(elementName) {
        case "ele":
            point?.ele = Double(value)
        case "time":
            point?.time = Self.fractional.date(from: value) ?? Self.plain.date(from: value)
        case "name":
            if point == nil, name == nil, !value.isEmpty { name = value }
        case "trkpt", "rtept":
            if let p = point { current.append(p) }
            point = nil
        case "trkseg", "rte":
            if !current.isEmpty { segments.append(current) }
            current = []
        default:
            break
        }
        text = ""
    }
}
