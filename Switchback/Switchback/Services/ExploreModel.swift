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
        guard let id = selectedId, let t = known[id] ?? previews[id] else { return nil }
        return Profiles.shared.withProfile(t)
    }

    /// Whether to jump to the user's location on launch (not if the last-viewed map already shows it).
    /// The map starts on your last view (instantly), then moves to where you are once the GPS answers.
    func shouldCenter(on location: CLLocation) -> Bool { true }

    /// Trails read from the map's own data: shown at once, until the full search brings the exact version.
    private var previews: [String: Trail] = [:]

    func tilePreviews(_ trails: [Trail]) {
        var changed = false
        for t in trails where previews[t.id] == nil || previews[t.id]!.length < t.length {
            previews[t.id] = t
            changed = true
        }
        if previews.count > 1500, let r = visibleRegion {
            let keep = BBox(region: r).expanded(byDegrees: 0.3)
            previews = previews.filter { $0.value.bbox.intersects(keep) }
        }
        if changed {
            refreshResults()
            loadedOnce = true
        }
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
        // what's on screen first (small and quick), then the surroundings
        let visible = Set(TrailCache.cells(in: view.clamped(maxSpan: 0.12)))
        let near = missing.filter { visible.contains($0) }
        let far = missing.filter { !visible.contains($0) }
        // a separate task: moving the map again must not cancel a download that's under way
        // (it's saved for those cells either way, so it's never wasted)
        inFlight.formUnion(missing)
        Task {
            var done: [(cells: [TrailCache.Cell], main: [Trail])] = []
            for group in [near, far] where !group.isEmpty {
                if let main = await self.fetch(group) { done.append((cells: group, main: main)) }
            }
            // then, quietly, the unnamed paths and Forest Service trails
            for d in done {
                guard let box = TrailCache.box(of: d.cells) else { continue }
                let all = await TrailSources.withExtras(in: box, main: d.main)
                guard all.count != d.main.count || all != d.main else { continue }
                await TrailCache.shared.store(all, for: d.cells)
                self.merge(all)
                self.refreshResults()
            }
        }
    }

    /// Fetches the main trails for some cells; returns them, or nil if it failed.
    private func fetch(_ cells: [TrailCache.Cell]) async -> [Trail]? {
        guard let box = TrailCache.box(of: cells) else {
            inFlight.subtract(cells)
            return nil
        }
        isLoading = true
        errorText = nil
        var result: [Trail]?
        do {
            let found = try await TrailSources.main(in: box)
            await TrailCache.shared.store(found, for: cells)
            merge(found)
            usedOffline = false
            result = found
        } catch {
            let offline = OfflineStore.shared.trails(in: box)
            if Self.isCancellation(error) {
                // not a real failure; the next map move asks again
            } else if offline.isEmpty {
                errorText = Self.message(for: error)
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
        return result
    }

    private static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    private static func message(for error: Error) -> String {
        if let e = error as? URLError {
            switch e.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                return "No signal, so no new trails here. Tap to try again."
            case .timedOut:
                return "The trail server is slow right now. Tap to try again."
            default:
                break
            }
        }
        if let e = error as? OverpassError, let text = e.errorDescription {
            return text + " Tap to try again."
        }
        return "Couldn't load trails. Tap to try again."
    }

    private func merge(_ trails: [Trail]) {
        for t in trails {
            // a newer copy of the same trail (e.g. with Forest Service details added) replaces the old one,
            // unless it's a shorter, clipped piece of it
            if let old = known[t.id], old.length > t.length + 1 { continue }
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
        // add the quick versions read from the map, unless the exact version of that trail is already here
        if !previews.isEmpty {
            var exact: [String: [BBox]] = [:]
            for t in list { exact[USFS.normalized(t.name), default: []].append(t.bbox.expanded(byDegrees: 0.003)) }
            for p in previews.values {
                let box = p.bbox
                guard box.intersects(view) else { continue }
                if exact[USFS.normalized(p.name)]?.contains(where: { $0.intersects(box) }) == true { continue }
                list.append(p)
            }
        }
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
        // results near you first (or near the map when your location isn't known)
        if let loc = Recorder.shared.lastLocation {
            req.region = MKCoordinateRegion(center: loc.coordinate, latitudinalMeters: 120_000, longitudinalMeters: 120_000)
        } else if let r = visibleRegion {
            req.region = r
        }
        do {
            let response = try await MKLocalSearch(request: req).start()
            guard let item = response.mapItems.first else {
                errorText = "Couldn't find \(q)."
                return
            }
            let c = item.placemark.coordinate
            cameraRequest = CameraRequest(region: MKCoordinateRegion(center: c, latitudinalMeters: 8_000, longitudinalMeters: 8_000))
        } catch {
            errorText = "Couldn't find \(q)."
        }
    }

    func center(on location: CLLocation) {
        cameraRequest = CameraRequest(region: MKCoordinateRegion(center: location.coordinate,
                                                                 latitudinalMeters: 8_000, longitudinalMeters: 8_000))
    }
}
