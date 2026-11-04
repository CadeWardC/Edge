import MapKit
import SwiftUI

/// Trail lines drawn on the map.
final class TrailLines: MKMultiPolyline {
    enum Role { case trail, selected, track }
    var trailId = ""
    var role: Role = .trail
}

/// A MapKit map with a choice of base map (Apple or topo tiles), trails, a recorded track and your location.
struct TrailMapView: UIViewRepresentable {
    var baseMap: BaseMap
    var trails: [Trail] = []
    var selectedId: String? = nil
    var track: [[Coord]] = []
    var camera: CameraRequest? = nil
    /// Fit the map to this box when it first appears.
    var initialBox: BBox? = nil
    var showsUserButton = true
    var followUser = false
    var onSelect: ((String?) -> Void)? = nil
    var onRegionChange: ((MKCoordinateRegion) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsUserLocation = true
        map.showsScale = true
        map.showsCompass = true
        map.pointOfInterestFilter = MKPointOfInterestFilter(including: [.park, .nationalPark, .campground, .parking, .beach])
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        map.addGestureRecognizer(tap)
        if showsUserButton {
            let button = MKUserTrackingButton(mapView: map)
            button.translatesAutoresizingMaskIntoConstraints = false
            button.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.92)
            button.layer.cornerRadius = 8
            button.clipsToBounds = true
            map.addSubview(button)
            NSLayoutConstraint.activate([
                button.trailingAnchor.constraint(equalTo: map.safeAreaLayoutGuide.trailingAnchor, constant: -10),
                button.topAnchor.constraint(equalTo: map.safeAreaLayoutGuide.topAnchor, constant: 60),
            ])
        }
        context.coordinator.pendingFit = initialBox
        context.coordinator.apply(self, to: map)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.apply(self, to: map)
    }

    @MainActor
    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: TrailMapView?
        private var base: BaseMap?
        private var tileOverlay: CachedTileOverlay?
        private var trailOverlays: [TrailLines] = []
        private var shownTrailIds: [String] = []
        private var shownSelected: String?
        private var trackOverlay: TrailLines?
        private var trackCount = -1
        private var lastCamera: UUID?
        private var startPin: MKPointAnnotation?
        private var wasFollowing = false
        var pendingFit: BBox?

        func apply(_ p: TrailMapView, to map: MKMapView) {
            parent = p

            if base != p.baseMap {
                base = p.baseMap
                if let t = tileOverlay {
                    map.removeOverlay(t)
                    tileOverlay = nil
                }
                switch p.baseMap {
                case .standard:
                    map.preferredConfiguration = MKStandardMapConfiguration(elevationStyle: .realistic, emphasisStyle: .default)
                case .satellite:
                    map.preferredConfiguration = MKHybridMapConfiguration(elevationStyle: .realistic)
                case .topo, .usgs:
                    map.preferredConfiguration = MKStandardMapConfiguration()
                    let o = CachedTileOverlay(source: p.baseMap)
                    map.insertOverlay(o, at: 0, level: .aboveLabels)
                    tileOverlay = o
                }
                map.cameraZoomRange = MKMapView.CameraZoomRange(minCenterCoordinateDistance: p.baseMap.isTiled ? (p.baseMap == .topo ? 700 : 1400) : 80)
            }

            let ids = p.trails.map(\.id)
            if ids != shownTrailIds || p.selectedId != shownSelected {
                map.removeOverlays(trailOverlays)
                trailOverlays = []
                var selected: TrailLines?
                for t in p.trails {
                    let lines = TrailLines(t.segments.map { seg in
                        var coords = seg.map(\.cl)
                        return MKPolyline(coordinates: &coords, count: coords.count)
                    })
                    lines.trailId = t.id
                    if t.id == p.selectedId {
                        lines.role = .selected
                        selected = lines
                    } else {
                        trailOverlays.append(lines)
                    }
                }
                if let selected { trailOverlays.append(selected) }   // drawn on top
                map.addOverlays(trailOverlays, level: .aboveLabels)
                shownTrailIds = ids
                shownSelected = p.selectedId

                if let pin = startPin { map.removeAnnotation(pin) }
                startPin = nil
                if let id = p.selectedId, let t = p.trails.first(where: { $0.id == id }) {
                    let pin = MKPointAnnotation()
                    pin.coordinate = t.start.cl
                    pin.title = "Trailhead"
                    map.addAnnotation(pin)
                    startPin = pin
                }
            }

            let count = p.track.reduce(0) { $0 + $1.count }
            if count != trackCount {
                trackCount = count
                if let old = trackOverlay { map.removeOverlay(old) }
                trackOverlay = nil
                let segs = p.track.filter { $0.count > 1 }
                if !segs.isEmpty {
                    let lines = TrailLines(segs.map { seg in
                        var coords = seg.map(\.cl)
                        return MKPolyline(coordinates: &coords, count: coords.count)
                    })
                    lines.role = .track
                    map.addOverlay(lines, level: .aboveLabels)
                    trackOverlay = lines
                }
            }

            if p.followUser && !wasFollowing {
                map.setUserTrackingMode(.follow, animated: true)
            }
            wasFollowing = p.followUser

            if let c = p.camera, c.id != lastCamera {
                lastCamera = c.id
                if let r = c.region {
                    map.setRegion(r, animated: true)
                } else if let b = c.box {
                    fit(map, to: b, animated: true)
                }
            }
            applyPendingFit(map, attempts: 10)
        }

        private func applyPendingFit(_ map: MKMapView, attempts: Int) {
            guard let box = pendingFit else { return }
            if map.bounds.width > 0 && map.bounds.height > 0 {
                pendingFit = nil
                fit(map, to: box, animated: false)
            } else if attempts > 0 {
                Task { @MainActor [weak self, weak map] in
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    guard let self, let map else { return }
                    self.applyPendingFit(map, attempts: attempts - 1)
                }
            } else {
                pendingFit = nil
                map.setRegion(box.region(), animated: false)
            }
        }

        private func fit(_ map: MKMapView, to b: BBox, animated: Bool) {
            let p1 = MKMapPoint(CLLocationCoordinate2D(latitude: b.north, longitude: b.west))
            let p2 = MKMapPoint(CLLocationCoordinate2D(latitude: b.south, longitude: b.east))
            let rect = MKMapRect(x: min(p1.x, p2.x), y: min(p1.y, p2.y), width: abs(p2.x - p1.x), height: abs(p2.y - p1.y))
            if rect.size.width < 1 || rect.size.height < 1 {
                map.setRegion(b.region(), animated: animated)
            } else {
                map.setVisibleMapRect(rect, edgePadding: UIEdgeInsets(top: 50, left: 30, bottom: 50, right: 30), animated: animated)
            }
        }

        // MARK: MKMapViewDelegate

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let t = overlay as? MKTileOverlay {
                return MKTileOverlayRenderer(tileOverlay: t)
            }
            if let lines = overlay as? TrailLines {
                let r = MKMultiPolylineRenderer(multiPolyline: lines)
                r.lineCap = .round
                r.lineJoin = .round
                switch lines.role {
                case .trail:
                    r.strokeColor = UIColor(red: 0.85, green: 0.38, blue: 0.12, alpha: 0.9)
                    r.lineWidth = 3
                case .selected:
                    r.strokeColor = UIColor(red: 0.10, green: 0.55, blue: 0.30, alpha: 1)
                    r.lineWidth = 6
                case .track:
                    r.strokeColor = UIColor.systemBlue
                    r.lineWidth = 5
                }
                return r
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            let region = mapView.region
            Task { @MainActor [weak self] in
                self?.parent?.onRegionChange?(region)
            }
        }

        @objc func tapped(_ g: UITapGestureRecognizer) {
            guard let map = g.view as? MKMapView, let p = parent, let onSelect = p.onSelect else { return }
            let point = g.location(in: map)
            // let taps on the map's own buttons and pins through
            if let hit = map.hitTest(point, with: nil), hit is UIControl || hit is MKAnnotationView { return }
            let coord = Coord(map.convert(point, toCoordinateFrom: map))
            let metersPerPoint = map.region.span.latitudeDelta * Geo.metersPerDegree / max(1, Double(map.bounds.height))
            let threshold = 22 * metersPerPoint
            let pad = threshold / Geo.metersPerDegree * 2
            var best: (id: String, d: Double)?
            for t in p.trails where t.bbox.expanded(byDegrees: pad).contains(coord) {
                let d = Geo.distanceToPath(coord, segments: t.segments)
                if d < threshold && d < (best?.d ?? .infinity) { best = (id: t.id, d: d) }
            }
            onSelect(best?.id)
        }
    }
}

/// The small credit line a tiled map needs.
struct MapAttribution: View {
    let baseMap: BaseMap

    var body: some View {
        if let text = baseMap.attribution {
            Text(text)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.thinMaterial, in: Capsule())
                .padding(6)
        }
    }
}
