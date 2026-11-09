import Foundation
import MapKit
import UIKit

/// The map style under the trails.
enum BaseMap: String, CaseIterable, Identifiable {
    case switchback, standard, satellite, topo, usgs, usgsImagery, waymarkedHiking

    /// The styles you can pick as the map underneath (not the see-through layers).
    static var baseStyles: [BaseMap] { allCases.filter { !$0.isOverlay } }
    static let showRoutesKey = "showWaymarkedRoutes"

    static let storageKey = "baseMap"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .switchback: return "Switchback (our own map)"
        case .standard: return "Apple Maps"
        case .satellite: return "Satellite"
        case .topo: return "Topo (OpenTopoMap)"
        case .usgs: return "USGS Topo (US only)"
        case .usgsImagery: return "USGS Satellite (US only)"
        case .waymarkedHiking: return "Waymarked hiking routes"
        }
    }

    var shortTitle: String {
        switch self {
        case .switchback: return "Switchback"
        case .standard: return "Map"
        case .satellite: return "Satellite"
        case .topo: return "Topo"
        case .usgs: return "USGS"
        case .usgsImagery: return "USGS Satellite"
        case .waymarkedHiking: return "Routes"
        }
    }

    var isTiled: Bool { self == .topo || self == .usgs || self == .usgsImagery }

    /// A see-through layer drawn on top of the base map.
    var isOverlay: Bool { self == .waymarkedHiking }

    /// Our own map: vector data drawn on the phone (sharp at any zoom, tiny to download).
    var isVector: Bool { self == .switchback }

    /// Styles that can be saved for offline use.
    var isDownloadable: Bool { isTiled || isVector }

    /// The closest zoom the server has tiles for; closer than that, tiles are enlarged from this level.
    /// (Vector tiles stop at 14 and are drawn sharp beyond it.)
    var maxZoom: Int {
        switch self {
        case .topo: return 17
        case .switchback: return 14
        default: return 16
        }
    }

    /// Rough size of one tile, for download estimates (photos are bigger than drawn maps).
    var averageTileBytes: Int64 {
        switch self {
        case .usgsImagery: return 45_000
        case .switchback: return 32_000   // a vector tile plus its share of the terrain tiles
        default: return 20_000
        }
    }

    var attribution: String? {
        switch self {
        case .topo: return "© OpenStreetMap contributors, SRTM · Map style © OpenTopoMap (CC-BY-SA)"
        case .usgs: return "USGS The National Map"
        case .usgsImagery: return "USGS The National Map: Orthoimagery"
        case .switchback: return "© OpenStreetMap contributors · OpenFreeMap · OpenMapTiles · Terrain: Mapzen/AWS"
        case .waymarkedHiking: return "Routes © waymarkedtrails.org, OpenStreetMap contributors (CC-BY-SA)"
        default: return nil
        }
    }

    /// Offline maps need tiles, so Apple's styles fall back to the closest downloadable one.
    var offlineSource: BaseMap {
        if isDownloadable { return self }
        return self == .satellite ? .usgsImagery : .switchback
    }

    func tileURL(z: Int, x: Int, y: Int) -> URL? {
        switch self {
        case .topo:
            let s = ["a", "b", "c"][abs(x + y) % 3]
            return URL(string: "https://\(s).tile.opentopomap.org/\(z)/\(x)/\(y).png")
        case .usgs:
            return URL(string: "https://basemap.nationalmap.gov/arcgis/rest/services/USGSTopo/MapServer/tile/\(z)/\(y)/\(x)")
        case .usgsImagery:
            return URL(string: "https://basemap.nationalmap.gov/arcgis/rest/services/USGSImageryOnly/MapServer/tile/\(z)/\(y)/\(x)")
        case .waymarkedHiking:
            return URL(string: "https://tile.waymarkedtrails.org/hiking/\(z)/\(x)/\(y).png")
        default:
            return nil
        }
    }

    static var current: BaseMap {
        UserDefaults.standard.string(forKey: storageKey).flatMap(BaseMap.init(rawValue:)) ?? .switchback
    }
}

/// Map tiles on disk: offline areas (kept) and a cache of tiles you've looked at (may be cleared by iOS).
final class TileStore: @unchecked Sendable {
    static let shared = TileStore()

    private let lock = NSLock()
    private var offlineRoots: [URL] = []
    let cacheRoot = Files.caches.appendingPathComponent("Tiles", isDirectory: true)

    func setOfflineRoots(_ roots: [URL]) {
        lock.lock()
        offlineRoots = roots
        lock.unlock()
    }

    static func relativePath(_ source: BaseMap, z: Int, x: Int, y: Int) -> String {
        "\(source.rawValue)/\(z)/\(x)/\(y)"
    }

    func data(_ source: BaseMap, z: Int, x: Int, y: Int) -> Data? {
        lock.lock()
        let roots = offlineRoots
        lock.unlock()
        let rel = Self.relativePath(source, z: z, x: x, y: y)
        for root in roots + [cacheRoot] {
            if let d = try? Data(contentsOf: root.appendingPathComponent(rel)) { return d }
        }
        return nil
    }

    func store(_ data: Data, _ source: BaseMap, z: Int, x: Int, y: Int, in root: URL? = nil) {
        let url = (root ?? cacheRoot).appendingPathComponent(Self.relativePath(source, z: z, x: x, y: y))
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url)
    }

    func cacheSize() -> Int64 { Files.directorySize(cacheRoot) }

    func clearCache() { try? FileManager.default.removeItem(at: cacheRoot) }

    static func fetch(_ source: BaseMap, z: Int, x: Int, y: Int) async throws -> Data {
        guard let url = source.tileURL(z: z, x: x, y: y) else { throw URLError(.badURL) }
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.setValue(Net.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else { throw URLError(.badServerResponse) }
        return data
    }

    /// Makes a tile by enlarging part of a lower-zoom tile: lets you zoom past the server's last level, and past
    /// what an offline area downloaded. Without network, only tiles already on the phone are used.
    static func overzoom(_ source: BaseMap, z: Int, x: Int, y: Int, from base: Int, network: Bool) async throws -> Data {
        let dz = z - base
        guard dz > 0, dz <= 6, base >= 0 else { throw URLError(.fileDoesNotExist) }
        let ax = x >> dz, ay = y >> dz
        let data: Data
        if let d = shared.data(source, z: base, x: ax, y: ay) {
            data = d
        } else if network {
            data = try await fetch(source, z: base, x: ax, y: ay)
            shared.store(data, source, z: base, x: ax, y: ay)
        } else {
            throw URLError(.fileDoesNotExist)
        }
        guard let image = UIImage(data: data), let cg = image.cgImage else { throw URLError(.cannotDecodeContentData) }
        let n = 1 << dz
        let side = Double(cg.width) / Double(n)
        let rect = CGRect(x: Double(x - (ax << dz)) * side, y: Double(y - (ay << dz)) * side, width: side, height: side)
        guard let part = cg.cropping(to: rect.integral) else { throw URLError(.cannotDecodeContentData) }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 256, height: 256), format: format)
        let draw: (UIGraphicsImageRendererContext) -> Void = { _ in
            UIImage(cgImage: part).draw(in: CGRect(x: 0, y: 0, width: 256, height: 256))
        }
        // see-through layers keep their transparency
        return source.isOverlay ? renderer.pngData(actions: draw) : renderer.jpegData(withCompressionQuality: 0.9, actions: draw)
    }

    // Web Mercator tile maths
    static func tileX(_ lon: Double, _ z: Int) -> Int {
        let n = 1 << z
        return min(n - 1, max(0, Int(floor((lon + 180) / 360 * Double(n)))))
    }

    static func tileY(_ lat: Double, _ z: Int) -> Int {
        let n = 1 << z
        let r = max(-85.05, min(85.05, lat)) * .pi / 180
        return min(n - 1, max(0, Int(floor((1 - log(tan(r) + 1 / cos(r)) / .pi) / 2 * Double(n)))))
    }

    static func tileCount(_ box: BBox, minZoom: Int, maxZoom: Int) -> Int {
        guard minZoom <= maxZoom else { return 0 }
        var total = 0
        for z in minZoom...maxZoom {
            let xs = tileX(box.east, z) - tileX(box.west, z) + 1
            let ys = tileY(box.south, z) - tileY(box.north, z) + 1
            total += xs * ys
        }
        return total
    }

    static func tiles(_ box: BBox, minZoom: Int, maxZoom: Int) -> [(z: Int, x: Int, y: Int)] {
        guard minZoom <= maxZoom else { return [] }
        var out: [(z: Int, x: Int, y: Int)] = []
        for z in minZoom...maxZoom {
            for x in tileX(box.west, z)...tileX(box.east, z) {
                for y in tileY(box.north, z)...tileY(box.south, z) {
                    out.append((z: z, x: x, y: y))
                }
            }
        }
        return out
    }
}

/// Draws map tiles from disk when they're there, from the network otherwise, and enlarged from a lower zoom
/// when neither has them (zooming in past the server's last level, or past an offline area's detail).
final class CachedTileOverlay: MKTileOverlay {
    let source: BaseMap

    init(source: BaseMap) {
        self.source = source
        super.init(urlTemplate: nil)
        canReplaceMapContent = !source.isOverlay
        minimumZ = 1
        maximumZ = 19
        tileSize = CGSize(width: 256, height: 256)
    }

    override func url(forTilePath path: MKTileOverlayPath) -> URL {
        source.tileURL(z: path.z, x: path.x, y: path.y) ?? URL(fileURLWithPath: "/dev/null")
    }

    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, Error?) -> Void) {
        let source = self.source
        let z = path.z, x = path.x, y = path.y
        Task.detached(priority: .userInitiated) {
            do {
                result(try await CachedTileOverlay.tile(source, z: z, x: x, y: y), nil)
            } catch {
                result(nil, error)
            }
        }
    }

    static func tile(_ source: BaseMap, z: Int, x: Int, y: Int) async throws -> Data {
        if z > source.maxZoom {
            if let d = try? await TileStore.overzoom(source, z: z, x: x, y: y, from: source.maxZoom, network: false) { return d }
        }
        if z <= source.maxZoom, let d = TileStore.shared.data(source, z: z, x: x, y: y) { return d }
        do {
            if z > source.maxZoom {
                return try await TileStore.overzoom(source, z: z, x: x, y: y, from: source.maxZoom, network: true)
            }
            let d = try await TileStore.fetch(source, z: z, x: x, y: y)
            TileStore.shared.store(d, source, z: z, x: x, y: y)
            return d
        } catch {
            // no signal: enlarge the closest lower zoom already on the phone
            let top = min(z - 1, source.maxZoom)
            if top >= 1 {
                for base in stride(from: top, through: max(1, z - 6), by: -1) {
                    if let d = try? await TileStore.overzoom(source, z: z, x: x, y: y, from: base, network: false) { return d }
                }
            }
            throw error
        }
    }
}
