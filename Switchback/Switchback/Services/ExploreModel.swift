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
    @Published var errorText: String?
    @Published private(set) var searchedBox: BBox?
    @Published private(set) var usedOffline = false
    @Published var filters = TrailFilters()
    @Published var sort: TrailSort = .closest
    @Published var selectedId: String?
    @Published var cameraRequest: CameraRequest?
    @Published private(set) var regionMoved = true

    private(set) var visibleRegion: MKCoordinateRegion?
    private var searchTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    static let maxSpan = 0.3

    init() {
        Profiles.shared.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    var origin: Coord? {
        Recorder.shared.lastLocation.map { Coord($0.coordinate) } ?? searchedBox?.center
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
        guard let id = selectedId, let t = results.first(where: { $0.id == id }) else { return nil }
        return Profiles.shared.withProfile(t)
    }

    var isTooWide: Bool {
        guard let r = visibleRegion else { return false }
        return r.span.latitudeDelta > Self.maxSpan * 1.5 || r.span.longitudeDelta > Self.maxSpan * 1.5
    }

    func regionChanged(_ region: MKCoordinateRegion) {
        visibleRegion = region
        guard let box = searchedBox else {
            regionMoved = true
            return
        }
        let now = BBox(region: region)
        let moved = !box.contains(now.center) || now.latSpan > box.latSpan * 2 || now.latSpan < box.latSpan / 4
        if moved != regionMoved { regionMoved = moved }
    }

    func searchVisibleArea() {
        guard let region = visibleRegion else { return }
        search(BBox(region: region))
    }

    func search(_ box: BBox) {
        let b = box.clamped(maxSpan: Self.maxSpan)
        searchTask?.cancel()
        isLoading = true
        errorText = nil
        regionMoved = false
        searchTask = Task {
            var found: [Trail] = []
            do {
                found = try await Overpass.trails(in: b)
                usedOffline = false
            } catch {
                if Task.isCancelled { return }
                found = OfflineStore.shared.trails(in: b)
                usedOffline = !found.isEmpty
                if found.isEmpty { errorText = "Couldn't load trails: \(error.localizedDescription)" }
            }
            if Task.isCancelled { return }
            let c = b.center
            found.sort { Geo.distance(c, $0.start) < Geo.distance(c, $1.start) }
            results = Array(found.prefix(150))
            searchedBox = b
            isLoading = false
            if let id = selectedId, !results.contains(where: { $0.id == id }) { selectedId = nil }
            if results.isEmpty && errorText == nil { errorText = "No trails mapped here. Try moving the map." }
            await Profiles.shared.enrich(Array(results.prefix(40)))
        }
    }

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
            let region = MKCoordinateRegion(center: c, latitudinalMeters: 16_000, longitudinalMeters: 16_000)
            cameraRequest = CameraRequest(region: region)
            visibleRegion = region
            search(BBox(region: region))
        } catch {
            errorText = "Couldn't find \(q)."
        }
    }

    func center(on location: CLLocation, searchIfEmpty: Bool) {
        let region = MKCoordinateRegion(center: location.coordinate, latitudinalMeters: 16_000, longitudinalMeters: 16_000)
        cameraRequest = CameraRequest(region: region)
        visibleRegion = region
        if searchIfEmpty && results.isEmpty && !isLoading { search(BBox(region: region)) }
    }
}
