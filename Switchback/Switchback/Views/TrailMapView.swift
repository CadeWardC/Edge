import MapKit
import SwiftUI

/// Trail lines drawn on the map: a white casing under a coloured line, so trails stand out on any base map.
final class TrailLines: MKMultiPolyline {
    enum Role { case casing, line, trackCasing, track }
    var trailId = ""
    var role: Role = .line
    var color: UIColor = .systemGreen
    var selected = false
    var dashed = false
}

/// A highlight along a trail (viewpoint, water, shelter…).
final class POIAnnotation: NSObject, MKAnnotation {
    let poi: TrailPOI
    let coordinate: CLLocationCoordinate2D
    let title: String?

    init(_ poi: TrailPOI) {
        self.poi = poi
        coordinate = poi.coord.cl
        title = poi.displayName
    }
}

/// One of your photos, placed where you took it.
struct PhotoPin: Identifiable, Hashable {
    let id: String
    let coord: Coord
    let image: UIImage
}

final class PhotoAnnotation: NSObject, MKAnnotation {
    let pin: PhotoPin
    let coordinate: CLLocationCoordinate2D

    init(_ pin: PhotoPin) {
        self.pin = pin
        coordinate = pin.coord.cl
    }
}

extension POIKind {
    var mapColor: UIColor {
        switch self {
        case .water, .lake, .waterfall: return UIColor(red: 0.05, green: 0.55, blue: 0.80, alpha: 1)
        case .viewpoint, .peak, .cave: return UIColor(red: 0.55, green: 0.36, blue: 0.20, alpha: 1)
        case .shelter, .campsite, .picnic: return UIColor(red: 0.85, green: 0.50, blue: 0.10, alpha: 1)
        case .toilets, .parking: return UIColor.systemGray
        }
    }
}

/// A pin at the start of a trail.
final class TrailheadAnnotation: NSObject, MKAnnotation {
    let trailId: String
    let coordinate: CLLocationCoordinate2D
    let title: String?
    let color: UIColor
    let selected: Bool

    init(trail: Trail, selected: Bool) {
        trailId = trail.id
        coordinate = trail.start.cl
        title = trail.name
        color = trail.difficulty.mapColor
        self.selected = selected
    }
}

extension Difficulty {
    var mapColor: UIColor {
        switch self {
        case .easy: return UIColor(red: 0.12, green: 0.62, blue: 0.30, alpha: 1)
        case .moderate: return UIColor(red: 0.10, green: 0.45, blue: 0.88, alpha: 1)
        case .hard: return UIColor(red: 0.86, green: 0.20, blue: 0.16, alpha: 1)
        case .veryHard: return UIColor(red: 0.47, green: 0.22, blue: 0.70, alpha: 1)
        }
    }
}

/// A MapKit map with a choice of base map (Apple or tiles), trails, trailheads, a recorded track and your location.
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
    /// Draw the Waymarked Trails hiking-routes layer on top of the base map.
    var showsRoutes = false
    /// Highlights along the selected trail.
    var pois: [TrailPOI] = []
    /// Your photos from a hike.
    var photos: [PhotoPin] = []
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
        private struct Shown {
            let signature: String
            let casing: TrailLines
            let line: TrailLines
            let head: TrailheadAnnotation
        }

        var parent: TrailMapView?
        private var base: BaseMap?
        private var tileOverlay: CachedTileOverlay?
        private var routesOverlay: CachedTileOverlay?
        private var shown: [String: Shown] = [:]
        private var lastSelected: String?
        private var trackOverlays: [TrailLines] = []
        private var poiAnnotations: [POIAnnotation] = []
        private var photoAnnotations: [PhotoAnnotation] = []
        private var trackCount = -1
        private var lastCamera: UUID?
        private var wasFollowing = false
        var pendingFit: BBox?

        func apply(_ p: TrailMapView, to map: MKMapView) {
            parent = p
            applyBase(p, map)
            applyRoutes(p, map)
            applyTrails(p, map)
            applyTrack(p, map)
            applyPins(p, map)

            if p.followUser && !wasFollowing { map.setUserTrackingMode(.follow, animated: true) }
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

        private func applyBase(_ p: TrailMapView, _ map: MKMapView) {
            guard base != p.baseMap else { return }
            base = p.baseMap
            if let t = tileOverlay {
                map.removeOverlay(t)
                tileOverlay = nil
            }
            switch p.baseMap {
            case .standard, .waymarkedHiking, .switchback:   // routes is an overlay; our own map is drawn by MapLibre
                map.preferredConfiguration = MKStandardMapConfiguration(elevationStyle: .realistic, emphasisStyle: .muted)
            case .satellite:
                map.preferredConfiguration = MKHybridMapConfiguration(elevationStyle: .realistic)
            case .topo, .usgs, .usgsImagery:
                map.preferredConfiguration = MKStandardMapConfiguration()
                let o = CachedTileOverlay(source: p.baseMap)
                map.insertOverlay(o, at: 0, level: .aboveLabels)
                tileOverlay = o
            }
            map.cameraZoomRange = MKMapView.CameraZoomRange(minCenterCoordinateDistance: p.baseMap.isTiled ? 250 : 80)
        }

        private func applyRoutes(_ p: TrailMapView, _ map: MKMapView) {
            if p.showsRoutes, routesOverlay == nil {
                let o = CachedTileOverlay(source: .waymarkedHiking)
                if let base = tileOverlay {
                    map.insertOverlay(o, above: base)
                } else {
                    map.insertOverlay(o, at: 0, level: .aboveLabels)
                }
                routesOverlay = o
            } else if !p.showsRoutes, let o = routesOverlay {
                map.removeOverlay(o)
                routesOverlay = nil
            }
        }

        private func signature(_ t: Trail, selected: Bool) -> String {
            "\(t.difficulty.rawValue)|\(selected)|\(t.segments.count)|\(t.path.count)"
        }

        /// Adds and removes only the trails that changed, so panning and selecting don't redraw everything.
        private func applyTrails(_ p: TrailMapView, _ map: MKMapView) {
            var wanted: [String: Trail] = [:]
            for t in p.trails where wanted[t.id] == nil { wanted[t.id] = t }

            var oldOverlays: [MKOverlay] = []
            var oldHeads: [MKAnnotation] = []
            for (id, s) in shown {
                if let t = wanted[id], signature(t, selected: id == p.selectedId) == s.signature { continue }
                oldOverlays.append(s.casing)
                oldOverlays.append(s.line)
                oldHeads.append(s.head)
                shown[id] = nil
            }
            if !oldOverlays.isEmpty { map.removeOverlays(oldOverlays) }
            if !oldHeads.isEmpty { map.removeAnnotations(oldHeads) }

            var newOverlays: [MKOverlay] = []
            var newHeads: [MKAnnotation] = []
            var selectedOverlays: [MKOverlay] = []
            for t in p.trails where shown[t.id] == nil {
                let isSelected = t.id == p.selectedId
                let casing = TrailLines(Self.polylines(t.segments))
                casing.role = .casing
                casing.trailId = t.id
                casing.selected = isSelected
                let line = TrailLines(Self.polylines(t.segments))
                line.role = .line
                line.trailId = t.id
                line.selected = isSelected
                line.color = t.difficulty.mapColor
                line.dashed = t.isUnnamed
                casing.dashed = t.isUnnamed
                let head = TrailheadAnnotation(trail: t, selected: isSelected)
                shown[t.id] = Shown(signature: signature(t, selected: isSelected), casing: casing, line: line, head: head)
                if isSelected {
                    selectedOverlays = [casing, line]
                } else {
                    newOverlays.append(casing)
                    newOverlays.append(line)
                }
                // unnamed paths get no pin, to keep the map calm (except when selected)
                if !t.isUnnamed || isSelected { newHeads.append(head) }
            }
            // keep the selected trail on top of anything just added
            if selectedOverlays.isEmpty, !newOverlays.isEmpty, let id = p.selectedId, let s = shown[id] {
                map.removeOverlays([s.casing, s.line])
                selectedOverlays = [s.casing, s.line]
            }
            if !newOverlays.isEmpty || !selectedOverlays.isEmpty {
                map.addOverlays(newOverlays + selectedOverlays, level: .aboveLabels)
            }
            if !newHeads.isEmpty { map.addAnnotations(newHeads) }

            // fade the other trails while one is selected
            if p.selectedId != lastSelected {
                lastSelected = p.selectedId
                for s in shown.values {
                    for o in [s.casing, s.line] {
                        if let r = map.renderer(for: o) {
                            r.alpha = alpha(for: o)
                            r.setNeedsDisplay()
                        }
                    }
                }
            }
        }

        private func applyTrack(_ p: TrailMapView, _ map: MKMapView) {
            let count = p.track.reduce(0) { $0 + $1.count }
            guard count != trackCount else { return }
            trackCount = count
            if !trackOverlays.isEmpty { map.removeOverlays(trackOverlays) }
            trackOverlays = []
            let segs = p.track.filter { $0.count > 1 }
            guard !segs.isEmpty else { return }
            let casing = TrailLines(Self.polylines(segs))
            casing.role = .trackCasing
            let line = TrailLines(Self.polylines(segs))
            line.role = .track
            trackOverlays = [casing, line]
            map.addOverlays(trackOverlays, level: .aboveLabels)
        }

        private func applyPins(_ p: TrailMapView, _ map: MKMapView) {
            if p.pois.map(\.id) != poiAnnotations.map(\.poi.id) {
                map.removeAnnotations(poiAnnotations)
                poiAnnotations = p.pois.map(POIAnnotation.init)
                map.addAnnotations(poiAnnotations)
            }
            if p.photos.map(\.id) != photoAnnotations.map(\.pin.id) {
                map.removeAnnotations(photoAnnotations)
                photoAnnotations = p.photos.map(PhotoAnnotation.init)
                map.addAnnotations(photoAnnotations)
            }
        }

        private static func polylines(_ segments: [[Coord]]) -> [MKPolyline] {
            segments.map { seg in
                var coords = seg.map(\.cl)
                return MKPolyline(coordinates: &coords, count: coords.count)
            }
        }

        private func alpha(for overlay: MKOverlay) -> CGFloat {
            guard let lines = overlay as? TrailLines, lines.role == .casing || lines.role == .line,
                  let selected = parent?.selectedId else { return 1 }
            return lines.trailId == selected ? 1 : 0.35
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
            if let t = overlay as? CachedTileOverlay, t.source.isOverlay {
                let r = MKTileOverlayRenderer(tileOverlay: t)
                r.alpha = 0.85
                return r
            }
            if let t = overlay as? MKTileOverlay {
                return MKTileOverlayRenderer(tileOverlay: t)
            }
            if let lines = overlay as? TrailLines {
                let r = MKMultiPolylineRenderer(multiPolyline: lines)
                r.lineCap = .round
                r.lineJoin = .round
                switch lines.role {
                case .casing:
                    r.strokeColor = UIColor.white.withAlphaComponent(lines.dashed && !lines.selected ? 0.7 : 0.95)
                    r.lineWidth = lines.selected ? 10 : (lines.dashed ? 4.5 : 6)
                case .line:
                    r.strokeColor = lines.color
                    r.lineWidth = lines.selected ? 6 : (lines.dashed ? 2.4 : 3.2)
                    if lines.dashed && !lines.selected { r.lineDashPattern = [6, 5] }
                case .trackCasing:
                    r.strokeColor = UIColor.white
                    r.lineWidth = 8
                case .track:
                    r.strokeColor = UIColor.systemBlue
                    r.lineWidth = 5
                }
                r.alpha = alpha(for: lines)
                return r
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if let head = annotation as? TrailheadAnnotation {
                let view = (mapView.dequeueReusableAnnotationView(withIdentifier: "trailhead") as? MKMarkerAnnotationView)
                    ?? MKMarkerAnnotationView(annotation: head, reuseIdentifier: "trailhead")
                view.annotation = head
                view.markerTintColor = head.color
                view.glyphImage = UIImage(systemName: "figure.hiking")
                view.clusteringIdentifier = head.selected ? nil : "trailheads"
                view.displayPriority = head.selected ? .required : .defaultHigh
                view.titleVisibility = .adaptive
                view.subtitleVisibility = .hidden
                return view
            }
            if let poi = annotation as? POIAnnotation {
                let view = (mapView.dequeueReusableAnnotationView(withIdentifier: "poi") as? MKMarkerAnnotationView)
                    ?? MKMarkerAnnotationView(annotation: poi, reuseIdentifier: "poi")
                view.annotation = poi
                view.markerTintColor = poi.poi.kind.mapColor
                view.glyphImage = UIImage(systemName: poi.poi.kind.symbol)
                view.clusteringIdentifier = nil
                view.displayPriority = poi.poi.kind.isSight || poi.poi.kind == .water ? .defaultHigh : .defaultLow
                view.titleVisibility = .adaptive
                view.canShowCallout = true
                return view
            }
            if let photo = annotation as? PhotoAnnotation {
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: "photo")
                    ?? MKAnnotationView(annotation: photo, reuseIdentifier: "photo")
                view.annotation = photo
                let side: CGFloat = 44
                let renderer = UIGraphicsImageRenderer(size: CGSize(width: side + 4, height: side + 4))
                view.image = renderer.image { _ in
                    UIColor.white.setFill()
                    UIBezierPath(roundedRect: CGRect(x: 0, y: 0, width: side + 4, height: side + 4), cornerRadius: 10).fill()
                    let clip = UIBezierPath(roundedRect: CGRect(x: 2, y: 2, width: side, height: side), cornerRadius: 8)
                    clip.addClip()
                    photo.pin.image.draw(in: CGRect(x: 2, y: 2, width: side, height: side))
                }
                view.layer.shadowColor = UIColor.black.cgColor
                view.layer.shadowOpacity = 0.3
                view.layer.shadowRadius = 3
                view.layer.shadowOffset = CGSize(width: 0, height: 1)
                view.displayPriority = .required
                return view
            }
            if let cluster = annotation as? MKClusterAnnotation {
                let view = (mapView.dequeueReusableAnnotationView(withIdentifier: "trailheads") as? MKMarkerAnnotationView)
                    ?? MKMarkerAnnotationView(annotation: cluster, reuseIdentifier: "trailheads")
                view.annotation = cluster
                view.markerTintColor = UIColor(red: 0.13, green: 0.42, blue: 0.27, alpha: 1)
                view.glyphText = "\(cluster.memberAnnotations.count)"
                view.titleVisibility = .hidden
                view.subtitleVisibility = .hidden
                view.displayPriority = .defaultHigh
                return view
            }
            return nil
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            if let head = view.annotation as? TrailheadAnnotation {
                mapView.deselectAnnotation(head, animated: false)
                let id = head.trailId
                Task { @MainActor [weak self] in self?.parent?.onSelect?(id) }
            } else if let cluster = view.annotation as? MKClusterAnnotation {
                mapView.deselectAnnotation(cluster, animated: false)
                mapView.showAnnotations(cluster.memberAnnotations, animated: true)
            }
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
            // let taps on the map's own buttons and on pins through
            var hit = map.hitTest(point, with: nil)
            while let v = hit {
                if v is UIControl || v is MKAnnotationView { return }
                if v === map { break }
                hit = v.superview
            }
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
