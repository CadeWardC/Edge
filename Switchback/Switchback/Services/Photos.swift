import CryptoKit
import MapKit
import Photos
import UIKit

/// A photo of (or near) a trail, from Wikimedia Commons.
struct TrailPhoto: Codable, Hashable, Identifiable {
    var id: String
    var thumb: URL
    var page: URL?
    var author: String?
    var license: String?

    var credit: String {
        [author, license].compactMap { $0 }.joined(separator: " · ")
    }
}

/// Free photos from Wikimedia Commons: ones linked from OpenStreetMap or Wikidata first, then ones taken near the
/// trail and its sights.
enum Commons {
    private static let api = "https://commons.wikimedia.org/w/api.php"

    private struct Response: Decodable {
        struct Query: Decodable { let pages: [String: Page]? }
        let query: Query?
    }

    private struct Page: Decodable {
        let title: String
        let imageinfo: [Info]?
    }

    private struct Info: Decodable {
        let thumburl: String?
        let descriptionurl: String?
        let mime: String?
        let width: Int?
        let height: Int?
        let extmetadata: [String: Meta]?
    }

    private struct Meta: Decodable { let value: JSONValue? }

    private static func get(_ items: [URLQueryItem]) async throws -> [TrailPhoto] {
        var c = URLComponents(string: api)!
        c.queryItems = [
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "prop", value: "imageinfo"),
            URLQueryItem(name: "iiprop", value: "url|mime|size|extmetadata"),
            URLQueryItem(name: "iiurlwidth", value: "1000"),
            URLQueryItem(name: "iiextmetadatafilter", value: "Artist|LicenseShortName"),
        ] + items
        guard let url = c.url else { throw URLError(.badURL) }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue(Net.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let pages = try JSONDecoder().decode(Response.self, from: data).query?.pages ?? [:]
        return pages.values.compactMap(photo(from:))
    }

    private static func photo(from page: Page) -> TrailPhoto? {
        guard let info = page.imageinfo?.first, let thumb = info.thumburl.flatMap(URL.init(string:)) else { return nil }
        // real photos only: no maps, diagrams, logos or tiny images
        guard info.mime == "image/jpeg", (info.width ?? 0) >= 640, (info.height ?? 0) >= 400 else { return nil }
        let lower = page.title.lowercased()
        if ["map", "karte", "carte", "diagram", "logo", "sign", "plan", "profile", "locator"].contains(where: { lower.contains($0) }) {
            return nil
        }
        let artist = info.extmetadata?["Artist"]?.value?.text.map(stripHTML)
        let license = info.extmetadata?["LicenseShortName"]?.value?.text
        return TrailPhoto(id: page.title, thumb: thumb, page: info.descriptionurl.flatMap(URL.init(string:)),
                          author: artist.flatMap { $0.isEmpty ? nil : String($0.prefix(60)) }, license: license)
    }

    private static func stripHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Photos by file name ("File:…").
    static func photos(titles: [String]) async -> [TrailPhoto] {
        guard !titles.isEmpty else { return [] }
        let found = (try? await get([URLQueryItem(name: "titles", value: titles.prefix(20).joined(separator: "|"))])) ?? []
        return titles.compactMap { t in found.first { $0.id == t } }
    }

    /// Photos taken within `radius` metres of a point.
    static func photos(near c: Coord, radius: Int, limit: Int = 8) async -> [TrailPhoto] {
        (try? await get([
            URLQueryItem(name: "generator", value: "geosearch"),
            URLQueryItem(name: "ggsnamespace", value: "6"),
            URLQueryItem(name: "ggscoord", value: String(format: "%.5f|%.5f", c.lat, c.lon)),
            URLQueryItem(name: "ggsradius", value: String(min(10_000, radius))),
            URLQueryItem(name: "ggslimit", value: String(limit)),
        ])) ?? []
    }

    /// The main image (P18) of a Wikidata item, as a Commons file name.
    static func wikidataImage(_ id: String) async -> String? {
        guard id.hasPrefix("Q"),
              let url = URL(string: "https://www.wikidata.org/w/api.php?action=wbgetclaims&format=json&property=P18&entity=\(id)")
        else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue(Net.userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let claims = json["claims"] as? [String: Any],
              let p18 = (claims["P18"] as? [[String: Any]])?.first,
              let snak = p18["mainsnak"] as? [String: Any],
              let value = (snak["datavalue"] as? [String: Any])?["value"] as? String else { return nil }
        return "File:" + value
    }
}

/// Photos for each trail, found once and kept.
@MainActor
final class TrailPhotos: ObservableObject {
    static let shared = TrailPhotos()

    @Published private(set) var byId: [String: [TrailPhoto]] = [:]
    private var inFlight = Set<String>()
    private let url = Files.caches.appendingPathComponent("trail-photos.json")

    init() {
        byId = Files.load([String: [TrailPhoto]].self, from: url) ?? [:]
    }

    func photos(for id: String) -> [TrailPhoto]? { byId[id] }

    func ensure(for trail: Trail, pois: [TrailPOI]) async {
        guard byId[trail.id] == nil, !inFlight.contains(trail.id), trail.source != .recorded else { return }
        inFlight.insert(trail.id)
        defer { inFlight.remove(trail.id) }

        // 1. photos the map data points to
        var titles: [String] = []
        let linked = [trail.tags["wikimedia_commons"], trail.tags["image"].flatMap(commonsTitle)] + pois.map(\.commons)
        for t in linked.compactMap({ $0 }) where t.hasPrefix("File:") { titles.append(t) }
        for q in ([trail.tags["wikidata"]] + pois.filter(\.kind.isSight).map(\.wikidata)).compactMap({ $0 }).prefix(4) {
            if let t = await Commons.wikidataImage(q) { titles.append(t) }
        }
        var unique: [String] = []
        for t in titles where !unique.contains(t) { unique.append(t) }
        var photos = await Commons.photos(titles: unique)

        // 2. photos taken at the sights and along the trail
        var spots = pois.filter(\.kind.isSight).prefix(4).map { (coord: $0.coord, radius: 150) }
        let samples = Geo.resample(trail.path, count: trail.isLoop ? 3 : 4).map(\.coord)
        spots += samples.map { (coord: $0, radius: 300) }
        for s in spots {
            if photos.count >= 14 { break }
            for p in await Commons.photos(near: s.coord, radius: s.radius) where !photos.contains(where: { $0.id == p.id }) {
                photos.append(p)
            }
        }
        // a search cut short (you left the page) isn't saved, so it runs again next time
        if Task.isCancelled { return }
        byId[trail.id] = Array(photos.prefix(14))
        if byId.count > 1500 { byId = Dictionary(uniqueKeysWithValues: byId.suffix(1000).map { ($0.key, $0.value) }) }
        Files.save(byId, to: url)
    }

    /// "https://commons.wikimedia.org/wiki/File:X.jpg" → "File:X.jpg".
    private func commonsTitle(_ s: String) -> String? {
        guard let r = s.range(of: "File:") else { return nil }
        return String(s[r.lowerBound...]).removingPercentEncoding
    }
}

/// Satellite pictures of a trail with its route drawn on, made by MapKit and kept on disk.
@MainActor
final class Snapshots {
    static let shared = Snapshots()

    private let memory = NSCache<NSString, UIImage>()
    private let dir = Files.caches.appendingPathComponent("Snapshots", isDirectory: true)
    private var active = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    private func key(_ trail: Trail, _ size: CGSize) -> String {
        let raw = "\(trail.id)|\(Int(size.width))x\(Int(size.height))|\(trail.path.count)"
        return SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func cached(for trail: Trail, size: CGSize) -> UIImage? {
        memory.object(forKey: key(trail, size) as NSString)
    }

    func image(for trail: Trail, size: CGSize) async -> UIImage? {
        let k = key(trail, size)
        if let img = memory.object(forKey: k as NSString) { return img }
        let file = dir.appendingPathComponent(k + ".jpg")
        if let data = try? Data(contentsOf: file), let img = UIImage(data: data) {
            memory.setObject(img, forKey: k as NSString)
            return img
        }
        // two at a time, so a scrolling list doesn't start dozens
        if active >= 2 {
            await withCheckedContinuation { waiting.append($0) }
        }
        active += 1
        defer {
            active -= 1
            if !waiting.isEmpty { waiting.removeFirst().resume() }
        }
        if Task.isCancelled { return nil }
        guard let img = await render(trail, size: size) else { return nil }
        memory.setObject(img, forKey: k as NSString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? img.jpegData(compressionQuality: 0.82)?.write(to: file)
        return img
    }

    private func render(_ trail: Trail, size: CGSize) async -> UIImage? {
        let options = MKMapSnapshotter.Options()
        let box = trail.bbox
        // square-ish framing around the route, with some room
        let span = max(box.latSpan, box.lonSpan * cos(box.center.lat * .pi / 180), 0.004) * 1.35
        let aspect = Double(size.width / max(1, size.height))
        options.region = MKCoordinateRegion(center: box.center.cl,
                                            span: MKCoordinateSpan(latitudeDelta: span / min(1, aspect),
                                                                   longitudeDelta: span * max(1, aspect) / cos(box.center.lat * .pi / 180)))
        options.size = size
        options.preferredConfiguration = MKImageryMapConfiguration(elevationStyle: .flat)
        guard let snapshot = try? await MKMapSnapshotter(options: options).start() else { return nil }
        let renderer = UIGraphicsImageRenderer(size: size)
        let color = trail.difficulty.mapColor
        return renderer.image { ctx in
            snapshot.image.draw(at: .zero)
            let path = UIBezierPath()
            for seg in trail.segments {
                for (i, c) in seg.enumerated() {
                    let p = snapshot.point(for: c.cl)
                    if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
                }
            }
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            let base = max(2, min(size.width, size.height) / 60)
            UIColor.white.setStroke()
            path.lineWidth = base * 2
            path.stroke()
            color.setStroke()
            path.lineWidth = base
            path.stroke()
            let s = snapshot.point(for: trail.start.cl)
            let r = base * 1.8
            UIColor.white.setFill()
            UIBezierPath(ovalIn: CGRect(x: s.x - r - 1.5, y: s.y - r - 1.5, width: 2 * r + 3, height: 2 * r + 3)).fill()
            color.setFill()
            UIBezierPath(ovalIn: CGRect(x: s.x - r, y: s.y - r, width: 2 * r, height: 2 * r)).fill()
            _ = ctx
        }
    }
}

/// Your own photos taken during a hike, from the photo library (they never leave the phone).
struct HikePhoto: Identifiable, Hashable {
    let id: String
    let asset: PHAsset
    let coord: Coord?
    let date: Date
}

enum HikePhotos {
    static var isAuthorized: Bool {
        let s = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        return s == .authorized || s == .limited
    }

    static func requestAccess() async -> Bool {
        let s = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return s == .authorized || s == .limited
    }

    static func photos(for activity: Activity) -> [HikePhoto] {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d AND creationDate >= %@ AND creationDate <= %@",
                                        PHAssetMediaType.image.rawValue,
                                        activity.start.addingTimeInterval(-60) as NSDate,
                                        activity.end.addingTimeInterval(60) as NSDate)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        let result = PHAsset.fetchAssets(with: options)
        let points = activity.segments.flatMap { $0 }
        var out: [HikePhoto] = []
        result.enumerateObjects { asset, _, _ in
            let date = asset.creationDate ?? activity.start
            let coord = asset.location.map { Coord($0.coordinate) } ?? position(at: date, in: points)
            out.append(HikePhoto(id: asset.localIdentifier, asset: asset, coord: coord, date: date))
        }
        return out
    }

    /// Where you were at a time, from the recorded track (for photos without a location).
    private static func position(at date: Date, in points: [TrackPoint]) -> Coord? {
        guard let first = points.first else { return nil }
        if date <= first.time { return first.coord }
        for i in 1..<max(1, points.count) {
            let a = points[i - 1], b = points[i]
            if date <= b.time {
                let span = b.time.timeIntervalSince(a.time)
                let t = span > 0 ? date.timeIntervalSince(a.time) / span : 0
                return Coord(lat: a.lat + (b.lat - a.lat) * t, lon: a.lon + (b.lon - a.lon) * t)
            }
        }
        return points.last?.coord
    }

    static func image(_ asset: PHAsset, size: CGSize) async -> UIImage? {
        await withCheckedContinuation { cont in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true
            options.resizeMode = .fast
            PHImageManager.default().requestImage(for: asset, targetSize: size, contentMode: .aspectFill, options: options) { img, _ in
                cont.resume(returning: img)
            }
        }
    }
}
