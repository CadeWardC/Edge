import MapKit
import MapLibre
import SwiftUI

/// Picks the map engine: our own map (MapLibre) for the Switchback style, MapKit for Apple, satellite and topo.
struct AppMap: View {
    var baseMap: BaseMap
    var trails: [Trail] = []
    var selectedId: String? = nil
    var track: [[Coord]] = []
    var camera: CameraRequest? = nil
    var initialBox: BBox? = nil
    var showsUserButton = true
    var followUser = false
    var showsRoutes = false
    var pois: [TrailPOI] = []
    var photos: [PhotoPin] = []
    var onSelect: ((String?) -> Void)? = nil
    var onRegionChange: ((MKCoordinateRegion) -> Void)? = nil

    var body: some View {
        if baseMap == .switchback {
            LibreTrailMap(trails: trails, selectedId: selectedId, track: track, camera: camera, initialBox: initialBox,
                          showsUserButton: showsUserButton, followUser: followUser, pois: pois, photos: photos,
                          onSelect: onSelect, onRegionChange: onRegionChange)
        } else {
            TrailMapView(baseMap: baseMap, trails: trails, selectedId: selectedId, track: track, camera: camera,
                         initialBox: initialBox, showsUserButton: showsUserButton, followUser: followUser,
                         showsRoutes: showsRoutes, pois: pois, photos: photos,
                         onSelect: onSelect, onRegionChange: onRegionChange)
        }
    }
}

/// Switchback's own map: MapLibre drawing OpenStreetMap vector tiles (OpenFreeMap) in our own outdoor style, light
/// or dark, with hillshading — and the app's trails, track, highlights and photos on top.
struct LibreTrailMap: UIViewRepresentable {
    var trails: [Trail] = []
    var selectedId: String? = nil
    var track: [[Coord]] = []
    var camera: CameraRequest? = nil
    var initialBox: BBox? = nil
    var showsUserButton = true
    var followUser = false
    var pois: [TrailPOI] = []
    var photos: [PhotoPin] = []
    var onSelect: ((String?) -> Void)? = nil
    var onRegionChange: ((MKCoordinateRegion) -> Void)? = nil

    static func styleURL(dark: Bool) -> URL? {
        Bundle.main.url(forResource: dark ? "switchback-style-dark" : "switchback-style", withExtension: "json")
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MLNMapView {
        let dark = context.environment.colorScheme == .dark
        let map = MLNMapView(frame: .zero, styleURL: Self.styleURL(dark: dark))
        context.coordinator.dark = dark
        map.delegate = context.coordinator
        map.showsUserLocation = true
        map.logoView.isHidden = true
        map.attributionButton.isHidden = true   // the credit line is drawn by the app (MapAttribution)
        map.compassViewPosition = .topRight
        map.compassViewMargins = CGPoint(x: 12, y: showsUserButton ? 112 : 12)
        map.maximumZoomLevel = 19
        map.minimumPitch = 0
        map.maximumPitch = 60

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        for g in map.gestureRecognizers ?? [] {
            if let t = g as? UITapGestureRecognizer, t.numberOfTapsRequired == 2 { tap.require(toFail: t) }
        }
        map.addGestureRecognizer(tap)

        if showsUserButton {
            let locate = UIButton(type: .system)
            locate.setImage(UIImage(systemName: "location"), for: .normal)
            locate.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.92)
            locate.layer.cornerRadius = 8
            locate.translatesAutoresizingMaskIntoConstraints = false
            locate.addTarget(context.coordinator, action: #selector(Coordinator.locate(_:)), for: .touchUpInside)
            map.addSubview(locate)
            NSLayoutConstraint.activate([
                locate.widthAnchor.constraint(equalToConstant: 44),
                locate.heightAnchor.constraint(equalToConstant: 44),
                locate.trailingAnchor.constraint(equalTo: map.safeAreaLayoutGuide.trailingAnchor, constant: -10),
                locate.topAnchor.constraint(equalTo: map.safeAreaLayoutGuide.topAnchor, constant: 60),
            ])
            context.coordinator.locateButton = locate
        }

        context.coordinator.parent = self
        context.coordinator.pendingFit = initialBox
        return map
    }

    func updateUIView(_ map: MLNMapView, context: Context) {
        let dark = context.environment.colorScheme == .dark
        if dark != context.coordinator.dark {
            context.coordinator.dark = dark
            context.coordinator.styleReady = false
            map.styleURL = Self.styleURL(dark: dark)
        }
        context.coordinator.apply(self, to: map)
    }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency MLNMapViewDelegate {
        var parent: LibreTrailMap?
        var pendingFit: BBox?
        var dark = false
        var styleReady = false
        weak var locateButton: UIButton?
        private var sources: [String: MLNShapeSource] = [:]
        private var shownTrails = ""
        private var shownSelected: String?? = .none
        private var shownTrack = -1
        private var shownPOIs = ""
        private var shownPhotos = ""
        private var lastCamera: UUID?
        private var wasFollowing = false

        static let trailColors: [Difficulty: UIColor] = [
            .easy: UIColor(red: 0.12, green: 0.62, blue: 0.30, alpha: 1),
            .moderate: UIColor(red: 0.10, green: 0.45, blue: 0.88, alpha: 1),
            .hard: UIColor(red: 0.86, green: 0.20, blue: 0.16, alpha: 1),
            .veryHard: UIColor(red: 0.47, green: 0.22, blue: 0.70, alpha: 1),
        ]
        private static let lineLayers = Difficulty.allCases.map { "sb-trail-\($0.rawValue)" } + ["sb-trail-unnamed"]
        private static let tapLayers: Set<String> = Set(lineLayers + Difficulty.allCases.map { "sb-head-\($0.rawValue)" } + ["sb-selected"])

        // MARK: Style

        func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            MapIcons.install(in: style)
            sources = [:]
            for id in ["sb-trails", "sb-heads", "sb-track", "sb-pois", "sb-photos"] {
                let s = MLNShapeSource(identifier: id, shape: nil, options: nil)
                style.addSource(s)
                sources[id] = s
            }
            addTrailLayers(style)
            addTrackLayers(style)
            addPinLayers(style)

            // peak heights in the app's units
            let imperial = Units.current == .imperial
            style.layer(withIdentifier: "peak-label-imperial")?.isVisible = imperial
            style.layer(withIdentifier: "peak-label-metric")?.isVisible = !imperial

            styleReady = true
            shownTrails = ""
            shownSelected = .none
            shownTrack = -1
            shownPOIs = ""
            shownPhotos = ""
            if let p = parent { apply(p, to: mapView) }
        }

        func mapView(_ mapView: MLNMapView, didFailToLoadImage imageName: String) -> UIImage? {
            MapIcons.fallback
        }

        private func line(_ id: String, _ source: MLNShapeSource, color: UIColor, width: Double,
                          predicate: NSPredicate? = nil, in style: MLNStyle) -> MLNLineStyleLayer {
            let l = MLNLineStyleLayer(identifier: id, source: source)
            l.predicate = predicate
            l.lineColor = NSExpression(forConstantValue: color)
            l.lineWidth = NSExpression(forConstantValue: width)
            l.lineCap = NSExpression(forConstantValue: "round")
            l.lineJoin = NSExpression(forConstantValue: "round")
            style.addLayer(l)
            return l
        }

        private func addTrailLayers(_ style: MLNStyle) {
            guard let trails = sources["sb-trails"], let heads = sources["sb-heads"] else { return }
            let casing = line("sb-casing", trails, color: dark ? UIColor(white: 0.1, alpha: 1) : .white, width: 6.5,
                              predicate: NSPredicate(format: "kind == 'named'"), in: style)
            casing.lineOpacity = NSExpression(forConstantValue: 0.9)
            for d in Difficulty.allCases {
                _ = line("sb-trail-\(d.rawValue)", trails, color: Self.trailColors[d] ?? .systemGreen, width: 3.4,
                         predicate: NSPredicate(format: "difficulty == %@ AND kind == 'named'", d.rawValue), in: style)
            }
            let unnamed = line("sb-trail-unnamed", trails, color: UIColor(red: 0.62, green: 0.42, blue: 0.22, alpha: 1),
                               width: 2.4, predicate: NSPredicate(format: "kind == 'unnamed'"), in: style)
            unnamed.lineDashPattern = NSExpression(forConstantValue: [2, 1.5])
            _ = line("sb-selected-casing", trails, color: .white, width: 12, predicate: NSPredicate(format: "id == ''"), in: style)
            _ = line("sb-selected", trails, color: Self.trailColors[.easy] ?? .systemGreen, width: 6.5,
                     predicate: NSPredicate(format: "id == ''"), in: style)

            let names = MLNSymbolStyleLayer(identifier: "sb-names", source: trails)
            names.predicate = NSPredicate(format: "kind == 'named'")
            names.minimumZoomLevel = 11.5
            names.text = NSExpression(forKeyPath: "name")
            names.textFontNames = NSExpression(forConstantValue: ["Noto Sans Bold"])
            names.textFontSize = NSExpression(forConstantValue: 12.5)
            names.symbolPlacement = NSExpression(forConstantValue: "line")
            names.symbolSpacing = NSExpression(forConstantValue: 320)
            names.textColor = NSExpression(forConstantValue: dark ? UIColor(red: 0.75, green: 0.92, blue: 0.78, alpha: 1)
                                                                  : UIColor(red: 0.10, green: 0.30, blue: 0.17, alpha: 1))
            names.textHaloColor = NSExpression(forConstantValue: dark ? UIColor(white: 0.08, alpha: 0.95) : UIColor.white)
            names.textHaloWidth = NSExpression(forConstantValue: 1.8)
            style.addLayer(names)

            for d in Difficulty.allCases {
                let c = MLNCircleStyleLayer(identifier: "sb-head-\(d.rawValue)", source: heads)
                c.predicate = NSPredicate(format: "difficulty == %@", d.rawValue)
                c.minimumZoomLevel = 9
                c.circleColor = NSExpression(forConstantValue: Self.trailColors[d] ?? .systemGreen)
                c.circleRadius = NSExpression(forConstantValue: 6.5)
                c.circleStrokeColor = NSExpression(forConstantValue: UIColor.white)
                c.circleStrokeWidth = NSExpression(forConstantValue: 2.2)
                style.addLayer(c)
            }
        }

        private func addTrackLayers(_ style: MLNStyle) {
            guard let track = sources["sb-track"] else { return }
            _ = line("sb-track-casing", track, color: .white, width: 8.5, in: style)
            _ = line("sb-track", track, color: .systemBlue, width: 5, in: style)
        }

        private func addPinLayers(_ style: MLNStyle) {
            guard let pois = sources["sb-pois"], let photos = sources["sb-photos"] else { return }
            let p = MLNSymbolStyleLayer(identifier: "sb-poi", source: pois)
            p.iconImageName = NSExpression(forKeyPath: "icon")
            p.iconScale = NSExpression(forConstantValue: 0.55)
            p.iconAllowsOverlap = NSExpression(forConstantValue: true)
            p.text = NSExpression(forKeyPath: "name")
            p.textFontNames = NSExpression(forConstantValue: ["Noto Sans Bold"])
            p.textFontSize = NSExpression(forConstantValue: 11)
            p.textOffset = NSExpression(forConstantValue: NSValue(cgVector: CGVector(dx: 0, dy: 1.4)))
            p.textAnchor = NSExpression(forConstantValue: "top")
            p.textOptional = NSExpression(forConstantValue: true)
            p.textColor = NSExpression(forConstantValue: dark ? UIColor(white: 0.9, alpha: 1) : UIColor(white: 0.2, alpha: 1))
            p.textHaloColor = NSExpression(forConstantValue: dark ? UIColor(white: 0.08, alpha: 0.95) : UIColor.white)
            p.textHaloWidth = NSExpression(forConstantValue: 1.5)
            style.addLayer(p)
            let ph = MLNSymbolStyleLayer(identifier: "sb-photo", source: photos)
            ph.iconImageName = NSExpression(forKeyPath: "icon")
            ph.iconAllowsOverlap = NSExpression(forConstantValue: true)
            ph.iconScale = NSExpression(forConstantValue: 0.5)
            style.addLayer(ph)
        }

        // MARK: Updating

        func apply(_ p: LibreTrailMap, to map: MLNMapView) {
            parent = p
            if let c = p.camera, c.id != lastCamera {
                lastCamera = c.id
                if let r = c.region {
                    map.setVisibleCoordinateBounds(Self.bounds(BBox(region: r)), edgePadding: .zero, animated: true, completionHandler: nil)
                } else if let b = c.box {
                    map.setVisibleCoordinateBounds(Self.bounds(b), edgePadding: UIEdgeInsets(top: 50, left: 30, bottom: 50, right: 30),
                                                   animated: true, completionHandler: nil)
                }
            }
            applyPendingFit(map, attempts: 10)
            if p.followUser && !wasFollowing { map.setUserTrackingMode(.follow, animated: true, completionHandler: nil) }
            wasFollowing = p.followUser
            guard styleReady, let style = map.style else { return }

            let trailSig = p.trails.map { "\($0.id)\($0.difficulty.rawValue)\($0.segments.count)" }.joined(separator: "|")
            if trailSig != shownTrails {
                shownTrails = trailSig
                let lines: [MLNShape & MLNFeature] = p.trails.map { Self.lineFeature($0) }
                let heads: [MLNShape & MLNFeature] = p.trails.filter { !$0.isUnnamed }.map { Self.headFeature($0) }
                sources["sb-trails"]?.shape = MLNShapeCollectionFeature(shapes: lines)
                sources["sb-heads"]?.shape = MLNShapeCollectionFeature(shapes: heads)
            }
            if shownSelected != .some(p.selectedId) {
                shownSelected = .some(p.selectedId)
                let pred = NSPredicate(format: "id == %@", p.selectedId ?? "")
                (style.layer(withIdentifier: "sb-selected") as? MLNLineStyleLayer)?.predicate = pred
                (style.layer(withIdentifier: "sb-selected-casing") as? MLNLineStyleLayer)?.predicate = pred
                if let id = p.selectedId, let t = p.trails.first(where: { $0.id == id }) {
                    (style.layer(withIdentifier: "sb-selected") as? MLNLineStyleLayer)?.lineColor =
                        NSExpression(forConstantValue: Self.trailColors[t.difficulty] ?? .systemGreen)
                }
                // fade the others while one is selected (not when it's the only trail, as on a trail page)
                let fade = p.selectedId != nil && p.trails.count > 1
                let opacity = NSExpression(forConstantValue: fade ? 0.35 : 1)
                for id in Self.lineLayers + ["sb-casing"] {
                    (style.layer(withIdentifier: id) as? MLNLineStyleLayer)?.lineOpacity = opacity
                }
            }

            let trackCount = p.track.reduce(0) { $0 + $1.count }
            if trackCount != shownTrack {
                shownTrack = trackCount
                let lines = p.track.filter { $0.count > 1 }.map { seg -> MLNPolyline in
                    var c = seg.map(\.cl)
                    return MLNPolyline(coordinates: &c, count: UInt(c.count))
                }
                sources["sb-track"]?.shape = lines.isEmpty ? nil : MLNMultiPolylineFeature(polylines: lines)
            }

            let poiSig = p.pois.map(\.id).joined(separator: "|")
            if poiSig != shownPOIs {
                shownPOIs = poiSig
                let feats: [MLNShape & MLNFeature] = p.pois.map { poi in
                    let f = MLNPointFeature()
                    f.coordinate = poi.coord.cl
                    f.attributes = ["icon": MapIcons.poiImageName(poi.kind), "name": poi.name ?? ""]
                    return f
                }
                sources["sb-pois"]?.shape = MLNShapeCollectionFeature(shapes: feats)
            }

            let photoSig = p.photos.map(\.id).joined(separator: "|")
            if photoSig != shownPhotos {
                shownPhotos = photoSig
                let feats: [MLNShape & MLNFeature] = p.photos.map { pin in
                    let name = "sb-photo-\(pin.id)"
                    if style.image(forName: name) == nil { style.setImage(MapIcons.photoPin(pin.image), forName: name) }
                    let f = MLNPointFeature()
                    f.coordinate = pin.coord.cl
                    f.attributes = ["icon": name]
                    return f
                }
                sources["sb-photos"]?.shape = MLNShapeCollectionFeature(shapes: feats)
            }
        }

        private static func lineFeature(_ t: Trail) -> MLNMultiPolylineFeature {
            let lines = t.segments.map { seg -> MLNPolyline in
                var coords = seg.map(\.cl)
                return MLNPolyline(coordinates: &coords, count: UInt(coords.count))
            }
            let f = MLNMultiPolylineFeature(polylines: lines)
            f.identifier = t.id
            f.attributes = ["id": t.id, "name": t.isUnnamed ? "" : t.name,
                            "difficulty": t.difficulty.rawValue, "kind": t.isUnnamed ? "unnamed" : "named"]
            return f
        }

        private static func headFeature(_ t: Trail) -> MLNPointFeature {
            let f = MLNPointFeature()
            f.coordinate = t.start.cl
            f.identifier = t.id
            f.attributes = ["id": t.id, "name": t.name, "difficulty": t.difficulty.rawValue]
            return f
        }

        static func bounds(_ b: BBox) -> MLNCoordinateBounds {
            MLNCoordinateBounds(sw: CLLocationCoordinate2D(latitude: b.south, longitude: b.west),
                                ne: CLLocationCoordinate2D(latitude: b.north, longitude: b.east))
        }

        private func applyPendingFit(_ map: MLNMapView, attempts: Int) {
            guard let box = pendingFit else { return }
            if map.bounds.width > 0 && map.bounds.height > 0 {
                pendingFit = nil
                map.setVisibleCoordinateBounds(Self.bounds(box), edgePadding: UIEdgeInsets(top: 40, left: 20, bottom: 40, right: 20),
                                               animated: false, completionHandler: nil)
            } else if attempts > 0 {
                Task { @MainActor [weak self, weak map] in
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    guard let self, let map else { return }
                    self.applyPendingFit(map, attempts: attempts - 1)
                }
            }
        }

        // MARK: Interaction

        func mapView(_ mapView: MLNMapView, regionDidChangeAnimated animated: Bool) {
            let b = mapView.visibleCoordinateBounds
            let region = MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: (b.sw.latitude + b.ne.latitude) / 2,
                                               longitude: (b.sw.longitude + b.ne.longitude) / 2),
                span: MKCoordinateSpan(latitudeDelta: abs(b.ne.latitude - b.sw.latitude),
                                       longitudeDelta: abs(b.ne.longitude - b.sw.longitude)))
            Task { @MainActor [weak self] in self?.parent?.onRegionChange?(region) }
        }

        func mapView(_ mapView: MLNMapView, didChange mode: MLNUserTrackingMode, animated: Bool) {
            let name: String
            switch mode {
            case .follow: name = "location.fill"
            case .followWithHeading, .followWithCourse: name = "location.north.line.fill"
            default: name = "location"
            }
            locateButton?.setImage(UIImage(systemName: name), for: .normal)
        }

        @objc func tapped(_ g: UITapGestureRecognizer) {
            guard let map = g.view as? MLNMapView, let onSelect = parent?.onSelect else { return }
            let p = g.location(in: map)
            let rect = CGRect(x: p.x - 22, y: p.y - 22, width: 44, height: 44)
            let hit = map.visibleFeatures(in: rect, styleLayerIdentifiers: Self.tapLayers)
            let id = hit.compactMap { $0.attribute(forKey: "id") as? String }.first
            onSelect(id)
        }

        @objc func locate(_ sender: UIButton) {
            guard let map = sender.superview as? MLNMapView else { return }
            if map.userTrackingMode == .follow {
                map.setUserTrackingMode(.followWithHeading, animated: true, completionHandler: nil)
            } else {
                map.setUserTrackingMode(.follow, animated: true, completionHandler: nil)
            }
        }
    }
}

/// Icons for the map, drawn from SF Symbols: point-of-interest classes used by the style ("sb-<class>"),
/// peaks, airports, trail highlights and photo pins.
enum MapIcons {
    private static let food = UIColor(red: 0.91, green: 0.51, blue: 0.23, alpha: 1)
    private static let nature = UIColor(red: 0.24, green: 0.55, blue: 0.27, alpha: 1)
    private static let grey = UIColor(red: 0.42, green: 0.45, blue: 0.50, alpha: 1)
    private static let civic = UIColor(red: 0.55, green: 0.42, blue: 0.27, alpha: 1)
    private static let health = UIColor(red: 0.82, green: 0.29, blue: 0.29, alpha: 1)

    private static let poiClasses: [(classes: [String], symbol: String, color: UIColor)] = [
        (["restaurant", "fast_food"], "fork.knife", food),
        (["cafe"], "cup.and.saucer.fill", food),
        (["bar", "pub"], "wineglass.fill", food),
        (["ice_cream", "bakery"], "birthday.cake.fill", food),
        (["shop", "grocery", "supermarket", "convenience", "clothing_store", "outdoor"], "bag.fill",
         UIColor(red: 0.25, green: 0.50, blue: 0.85, alpha: 1)),
        (["lodging", "hotel", "hostel", "motel"], "bed.double.fill", UIColor(red: 0.54, green: 0.38, blue: 0.79, alpha: 1)),
        (["campsite"], "tent.fill", nature),
        (["picnic_site"], "fork.knife", nature),
        (["shelter"], "house.fill", nature),
        (["viewpoint"], "binoculars.fill", nature),
        (["attraction"], "star.fill", nature),
        (["park"], "leaf.fill", nature),
        (["information"], "info", nature),
        (["drinking_water"], "drop.fill", UIColor(red: 0.05, green: 0.55, blue: 0.80, alpha: 1)),
        (["toilets"], "toilet.fill", grey),
        (["hospital", "doctors"], "cross.fill", health),
        (["pharmacy"], "pills.fill", health),
        (["fuel"], "fuelpump.fill", grey),
        (["parking"], "parkingsign", grey),
        (["bus"], "bus.fill", grey),
        (["railway"], "tram.fill", grey),
        (["school", "college"], "graduationcap.fill", civic),
        (["library"], "books.vertical.fill", civic),
        (["museum", "town_hall"], "building.columns.fill", civic),
        (["place_of_worship"], "building.fill", civic),
    ]

    static let fallback: UIImage = badge(symbol: nil, color: grey, size: 24)

    static func poiImageName(_ kind: POIKind) -> String { "sb-hl-\(kind.rawValue)" }

    static func install(in style: MLNStyle) {
        for entry in poiClasses {
            let img = badge(symbol: entry.symbol, color: entry.color, size: 40)
            for c in entry.classes { style.setImage(img, forName: "sb-\(c)") }
        }
        style.setImage(peak(), forName: "sb-peak")
        style.setImage(badge(symbol: "airplane", color: grey, size: 40), forName: "sb-airport")
        for kind in POIKind.allCases {
            style.setImage(badge(symbol: kind.symbol, color: kind.mapColor, size: 48), forName: poiImageName(kind))
        }
    }

    /// A white symbol on a coloured disc with a white rim.
    static func badge(symbol: String?, color: UIColor, size: CGFloat) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: size, height: size)).image { _ in
            let rect = CGRect(x: 0, y: 0, width: size, height: size)
            UIColor.white.setFill()
            UIBezierPath(ovalIn: rect).fill()
            color.setFill()
            UIBezierPath(ovalIn: rect.insetBy(dx: size * 0.08, dy: size * 0.08)).fill()
            if let symbol,
               let s = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: size * 0.42, weight: .semibold)) {
                let tinted = s.withTintColor(.white, renderingMode: .alwaysOriginal)
                let sz = tinted.size
                tinted.draw(in: CGRect(x: (size - sz.width) / 2, y: (size - sz.height) / 2, width: sz.width, height: sz.height))
            }
        }
    }

    private static func peak() -> UIImage {
        let size: CGFloat = 32
        return UIGraphicsImageRenderer(size: CGSize(width: size, height: size)).image { _ in
            let p = UIBezierPath()
            p.move(to: CGPoint(x: size / 2, y: 4))
            p.addLine(to: CGPoint(x: size - 4, y: size - 6))
            p.addLine(to: CGPoint(x: 4, y: size - 6))
            p.close()
            UIColor.white.setStroke()
            p.lineWidth = 4
            p.stroke()
            UIColor(red: 0.45, green: 0.30, blue: 0.16, alpha: 1).setFill()
            p.fill()
        }
    }

    static func photoPin(_ image: UIImage) -> UIImage {
        let side: CGFloat = 88
        return UIGraphicsImageRenderer(size: CGSize(width: side + 8, height: side + 8)).image { _ in
            UIColor.white.setFill()
            UIBezierPath(roundedRect: CGRect(x: 0, y: 0, width: side + 8, height: side + 8), cornerRadius: 18).fill()
            UIBezierPath(roundedRect: CGRect(x: 4, y: 4, width: side, height: side), cornerRadius: 15).addClip()
            image.draw(in: CGRect(x: 4, y: 4, width: side, height: side))
        }
    }
}
