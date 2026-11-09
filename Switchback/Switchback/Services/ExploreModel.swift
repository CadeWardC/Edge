import Combine
import MapKit
import SwiftUI

enum TrailSort: String, CaseIterable, Identifiable {
    case closest, shortest, longest, leastClimb, mostClimb

    var id: String { rawValue }

    var title: String {
        switch self {
        case .closest: return "Closest"
        case .shortest: return "Shortest"
        case .longest: return "Longest"
        case .leastClimb: return "Least climb"
        case .mostClimb: return "Most climb"
        }
    }
}

struct TrailFilters: Equatable {
    var excluded: Set<Difficulty> = []
    var maxLength: Double?
    var maxGain: Double?
    var loopsOnly = false

    var isActive: Bool { self != TrailFilters() }

    func matches(_ t: Trail) -> Bool {
        if excluded.contains(t.difficulty) { return false }
        if let m = maxLength, t.length > m { return false }
        if let m = maxGain, let g = t.profile?.gain, g > m { return false }
        if loopsOnly && !t.isLoop { return false }
        return true
    }
}

/// A one-off instruction to move a map.
struct CameraRequest: Equatable {
    let id = UUID()
    var region: MKCoordinateRegion?
    var box: BBox?

    static func == (a: CameraRequest, b: CameraRequest) -> Bool { a.id == b.id }
}

@MainActor
final class ExploreModel: ObservableObject {
    @Published private(set) var results: [Trail] = []
    @Published private(set) var isLoading = false
    @Published private(set) var loadedOnce = false
    @Published private(set) var isTooWide = false
    @Published private(set) var usedOffline = false
    @Published var errorText: String?
    @Published var filters = TrailFilters()
    @Published var sort: TrailSort = .closest
    @Published var selectedId: String?
    @Published var cameraRequest: CameraRequest?

    /// Where the map was when the app was last closed.
    let initialBox: BBox?
    private(set) var visibleRegion: MKCoordinateRegion?
    private var known: [String: Trail] = [:]
    private var knownBoxes: [String: BBox] = [:]
    private var inFlight = Set<TrailCache.Cell>()
    private var debounce: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    /// Trails are fetched for at most this many degrees around the middle of the map…
    static let fetchSpan = 0.3
    /// …and shown (from what's loaded) up to this zoomed-out span.
    static let showSpan = 0.8
    private static let regionKey = "lastExploreRegion"

    init() {
        if let v = UserDefaults.standard.array(forKey: Self.regionKey) as? [Double], v.count == 4 {
            let region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: v[0], longitude: v[1]),
                                            span: MKCoordinateSpan(latitudeDelta: v[2], longitudeDelta: v[3]))
            initialBox = BBox(region: region)
            visibleRegion = region
        } else {
            initialBox = nil
        }
        Profiles.shared.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    var origin: Coord? {
        Recorder.shared.lastLocation.map { Coord($0.coordinate) } ?? visibleRegion.map { Coord($0.center) }
    }

    func distanceFromUser(_ t: Trail) -> Double? {
        Recorder.shared.lastLocation.map { Geo.distance(Coord($0.coordinate), t.start) }
    }

    var filtered: [Trail] {
        var list = results.map { Profiles.shared.withProfile($0) }.filter { filters.matches($0) }
        switch sort {
        case .closest:
            if let o = origin { list.sort { Geo.distance(o, $0.start) < Geo.distance(o, $1.start) } }
        case .shortest: list.sort { $0.length < $1.length }
        case .longest: list.sort { $0.length > $1.length }
        case .leastClimb: list.sort { ($0.profile?.gain ?? .infinity) < ($1.profile?.gain ?? .infinity) }
        case .mostClimb: list.sort { ($0.profile?.gain ?? -1) > ($1.profile?.gain ?? -1) }
        }
        return list
    }

    var selectedTrail: Trail? {
        guard let id = selectedId, let t = known[id] else { return nil }
        return Profiles.shared.withProfile(t)
    }

    /// Whether to jump to the user's location on launch (not if the last-viewed map already shows it).
    func shouldCenter(on location: CLLocation) -> Bool {
        guard let box = initialBox else { return true }
        return !box.contains(Coord(location.coordinate))
    }

    // MARK: Loading

    func regionChanged(_ region: MKCoordinateRegion) {
        visibleRegion = region
        refreshResults()
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled, let self else { return }
            let c = region.center, sp = region.span
            UserDefaults.standard.set([c.latitude, c.longitude, sp.latitudeDelta, sp.longitudeDelta], forKey: Self.regionKey)
            await self.load(region)
        }
    }

    /// Tries again after an error.
    func reload() {
        guard let r = visibleRegion else { return }
        errorText = nil
        Task { await load(r) }
    }

    private func load(_ region: MKCoordinateRegion) async {
        let view = BBox(region: region)
        let wide = region.span.latitudeDelta > Self.showSpan || region.span.longitudeDelta > Self.showSpan
        if wide != isTooWide { isTooWide = wide }

        // 1. whatever is already on the phone, straight away
        merge(await TrailCache.shared.trails(in: view.clamped(maxSpan: Self.showSpan)))
        refreshResults()
        guard !wide else { return }

        // 2. only the parts of the map not loaded yet
        let missing = await TrailCache.shared.missing(in: view.clamped(maxSpan: Self.fetchSpan))
            .filter { !inFlight.contains($0) }
        if missing.isEmpty {
            loadedOnce = true
            return
        }
        await fetch(missing)
    }

    private func fetch(_ cells: [TrailCache.Cell]) async {
        guard let box = TrailCache.box(of: cells) else { return }
        inFlight.formUnion(cells)
        isLoading = true
        errorText = nil
        do {
            let found = try await Overpass.trails(in: box)
            await TrailCache.shared.store(found, for: cells)
            merge(found)
            usedOffline = false
        } catch {
            let offline = OfflineStore.shared.trails(in: box)
            if offline.isEmpty {
                errorText = "Couldn't load trails: \(error.localizedDescription)"
            } else {
                merge(offline)
                usedOffline = true
            }
        }
        inFlight.subtract(cells)
        isLoading = !inFlight.isEmpty
        loadedOnce = true
        refreshResults()
        let visible = Array(results.prefix(30))
        Task { await Profiles.shared.enrich(visible) }
    }

    private func merge(_ trails: [Trail]) {
        for t in trails {
            if let old = known[t.id], old.length >= t.length { continue }
            known[t.id] = t
            knownBoxes[t.id] = t.bbox
        }
        // don't let a long session hold every trail it ever saw
        if known.count > 4000, let r = visibleRegion {
            let keep = BBox(region: r).expanded(byDegrees: 0.5)
            known = known.filter { knownBoxes[$0.key]?.intersects(keep) ?? false }
            knownBoxes = knownBoxes.filter { known[$0.key] != nil }
        }
    }

    /// The trails in view, closest to the middle first.
    private func refreshResults() {
        guard let r = visibleRegion else { return }
        let view = BBox(region: r).expanded(byDegrees: 0.005)
        let c = view.center
        var list = known.values.filter { knownBoxes[$0.id]?.intersects(view) ?? false }
        list.sort { Geo.distance(c, $0.start) < Geo.distance(c, $1.start) }
        let top = Array(list.prefix(250))
        if top.map(\.id) != results.map(\.id) || top != results { results = top }
    }

    // MARK: Moving the map

    func searchPlace(_ text: String) async {
        let q = text.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        let req = MKLocalSearch.Request()
        req.naturalLanguageQuery = q
        req.resultTypes = [.address, .pointOfInterest]
        if let r = visibleRegion { req.region = r }
        do {
            let response = try await MKLocalSearch(request: req).start()
            guard let item = response.mapItems.first else {
                errorText = "Couldn't find \(q)."
                return
            }
            let c = item.placemark.coordinate
            cameraRequest = CameraRequest(region: MKCoordinateRegion(center: c, latitudinalMeters: 16_000, longitudinalMeters: 16_000))
        } catch {
            errorText = "Couldn't find \(q)."
        }
    }

    func center(on location: CLLocation) {
        cameraRequest = CameraRequest(region: MKCoordinateRegion(center: location.coordinate,
                                                                 latitudinalMeters: 16_000, longitudinalMeters: 16_000))
    }
}
