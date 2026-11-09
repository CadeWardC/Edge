import MapKit
import MapLibre
import SwiftUI

/// Switchback's own map: MapLibre drawing OpenStreetMap data (OpenFreeMap) in our own style, with hillshading,
/// and the app's trails on top — coloured by difficulty, with their names written along them.
struct LibreTrailMap: UIViewRepresentable {
    var trails: [Trail] = []
    var selectedId: String? = nil
    var camera: CameraRequest? = nil
    var initialBox: BBox? = nil
    var onSelect: ((String?) -> Void)? = nil
    var onRegionChange: ((MKCoordinateRegion) -> Void)? = nil

    static var styleURL: URL? { Bundle.main.url(forResource: "switchback-style", withExtension: "json") }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MLNMapView {
        let map = MLNMapView(frame: .zero, styleURL: Self.styleURL)
        map.delegate = context.coordinator
        map.showsUserLocation = true
        map.logoView.isHidden = true
        map.attributionButton.isHidden = true   // the credit line is drawn by the app (MapAttribution)
        map.compassViewPosition = .topRight
        map.compassViewMargins = CGPoint(x: 12, y: 112)
        map.maximumZoomLevel = 18

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        for g in map.gestureRecognizers ?? [] {
            if let t = g as? UITapGestureRecognizer, t.numberOfTapsRequired == 2 { tap.require(toFail: t) }
        }
        map.addGestureRecognizer(tap)

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

        context.coordinator.parent = self
        context.coordinator.pendingFit = initialBox
        return map
    }

    func updateUIView(_ map: MLNMapView, context: Context) {
        context.coordinator.apply(self, to: map)
    }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency MLNMapViewDelegate {
        var parent: LibreTrailMap?
        var pendingFit: BBox?
        private var styleReady = false
        private var trailsSource: MLNShapeSource?
        private var headsSource: MLNShapeSource?
        private var shownSignature = ""
        private var shownSelected: String?? = .none
        private var lastCamera: UUID?

        private static let colors: [Difficulty: UIColor] = [
            .easy: UIColor(red: 0.12, green: 0.62, blue: 0.30, alpha: 1),
            .moderate: UIColor(red: 0.10, green: 0.45, blue: 0.88, alpha: 1),
            .hard: UIColor(red: 0.86, green: 0.20, blue: 0.16, alpha: 1),
            .veryHard: UIColor(red: 0.47, green: 0.22, blue: 0.70, alpha: 1),
        ]
        private static let lineLayers = Difficulty.allCases.map { "sb-trail-\($0.rawValue)" } + ["sb-trail-unnamed"]
        private static let tapLayers: Set<String> = Set(lineLayers + Difficulty.allCases.map { "sb-head-\($0.rawValue)" } + ["sb-selected"])

        // MARK: Style

        func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            let trails = MLNShapeSource(identifier: "sb-trails", shape: nil, options: nil)
            let heads = MLNShapeSource(identifier: "sb-heads", shape: nil, options: nil)
            style.addSource(trails)
            style.addSource(heads)
            trailsSource = trails
            headsSource = heads

            let casing = MLNLineStyleLayer(identifier: "sb-casing", source: trails)
            casing.lineColor = NSExpression(forConstantValue: UIColor.white)
            casing.lineWidth = NSExpression(forConstantValue: 6)
            casing.lineOpacity = NSExpression(forConstantValue: 0.9)
            round(casing)
            style.addLayer(casing)

            for d in Difficulty.allCases {
                let l = MLNLineStyleLayer(identifier: "sb-trail-\(d.rawValue)", source: trails)
                l.predicate = NSPredicate(format: "difficulty == %@ AND kind == 'named'", d.rawValue)
                l.lineColor = NSExpression(forConstantValue: Self.colors[d] ?? .systemGreen)
                l.lineWidth = NSExpression(forConstantValue: 3.2)
                round(l)
                style.addLayer(l)
            }
            let unnamed = MLNLineStyleLayer(identifier: "sb-trail-unnamed", source: trails)
            unnamed.predicate = NSPredicate(format: "kind == 'unnamed'")
            unnamed.lineColor = NSExpression(forConstantValue: UIColor(red: 0.55, green: 0.38, blue: 0.20, alpha: 1))
            unnamed.lineWidth = NSExpression(forConstantValue: 2.4)
            unnamed.lineDashPattern = NSExpression(forConstantValue: [2, 1.5])
            style.addLayer(unnamed)

            let selCasing = MLNLineStyleLayer(identifier: "sb-selected-casing", source: trails)
            selCasing.predicate = NSPredicate(format: "id == ''")
            selCasing.lineColor = NSExpression(forConstantValue: UIColor.white)
            selCasing.lineWidth = NSExpression(forConstantValue: 11)
            round(selCasing)
            style.addLayer(selCasing)
            let sel = MLNLineStyleLayer(identifier: "sb-selected", source: trails)
            sel.predicate = NSPredicate(format: "id == ''")
            sel.lineColor = NSExpression(forConstantValue: UIColor(red: 0.10, green: 0.55, blue: 0.30, alpha: 1))
            sel.lineWidth = NSExpression(forConstantValue: 6)
            round(sel)
            style.addLayer(sel)

            let names = MLNSymbolStyleLayer(identifier: "sb-names", source: trails)
            names.predicate = NSPredicate(format: "kind == 'named'")
            names.minimumZoomLevel = 12
            names.text = NSExpression(forKeyPath: "name")
            names.textFontNames = NSExpression(forConstantValue: ["Noto Sans Bold"])
            names.textFontSize = NSExpression(forConstantValue: 12)
            names.symbolPlacement = NSExpression(forConstantValue: "line")
            names.textColor = NSExpression(forConstantValue: UIColor(red: 0.12, green: 0.30, blue: 0.18, alpha: 1))
            names.textHaloColor = NSExpression(forConstantValue: UIColor.white)
            names.textHaloWidth = NSExpression(forConstantValue: 1.6)
            style.addLayer(names)

            for d in Difficulty.allCases {
                let c = MLNCircleStyleLayer(identifier: "sb-head-\(d.rawValue)", source: heads)
                c.predicate = NSPredicate(format: "difficulty == %@", d.rawValue)
                c.minimumZoomLevel = 9
                c.circleColor = NSExpression(forConstantValue: Self.colors[d] ?? .systemGreen)
                c.circleRadius = NSExpression(forConstantValue: 6)
                c.circleStrokeColor = NSExpression(forConstantValue: UIColor.white)
                c.circleStrokeWidth = NSExpression(forConstantValue: 2)
                style.addLayer(c)
            }

            // peak heights in the app's units
            let imperial = Units.current == .imperial
            style.layer(withIdentifier: "peak-label-imperial")?.isVisible = imperial
            style.layer(withIdentifier: "peak-label-metric")?.isVisible = !imperial

            styleReady = true
            shownSignature = ""
            shownSelected = .none
            if let p = parent { apply(p, to: mapView) }
        }

        private func round(_ l: MLNLineStyleLayer) {
            l.lineCap = NSExpression(forConstantValue: "round")
            l.lineJoin = NSExpression(forConstantValue: "round")
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
            guard styleReady, let style = map.style else { return }

            let signature = p.trails.map { "\($0.id)\($0.difficulty.rawValue)\($0.segments.count)" }.joined(separator: "|")
            if signature != shownSignature {
                shownSignature = signature
                let lines: [MLNShape & MLNFeature] = p.trails.map { Self.lineFeature($0) }
                let heads: [MLNShape & MLNFeature] = p.trails.filter { !$0.isUnnamed }.map { Self.headFeature($0) }
                trailsSource?.shape = MLNShapeCollectionFeature(shapes: lines)
                headsSource?.shape = MLNShapeCollectionFeature(shapes: heads)
            }
            if shownSelected != .some(p.selectedId) {
                shownSelected = .some(p.selectedId)
                let pred = NSPredicate(format: "id == %@", p.selectedId ?? "")
                (style.layer(withIdentifier: "sb-selected") as? MLNLineStyleLayer)?.predicate = pred
                (style.layer(withIdentifier: "sb-selected-casing") as? MLNLineStyleLayer)?.predicate = pred
                if let id = p.selectedId, let t = p.trails.first(where: { $0.id == id }) {
                    (style.layer(withIdentifier: "sb-selected") as? MLNLineStyleLayer)?.lineColor =
                        NSExpression(forConstantValue: Self.colors[t.difficulty] ?? .systemGreen)
                }
                // fade the others while one is selected
                let opacity = NSExpression(forConstantValue: p.selectedId == nil ? 1 : 0.35)
                for id in Self.lineLayers + ["sb-casing"] {
                    (style.layer(withIdentifier: id) as? MLNLineStyleLayer)?.lineOpacity = opacity
                }
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
