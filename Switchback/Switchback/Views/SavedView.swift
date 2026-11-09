import MapKit
import SwiftUI

struct SavedView: View {
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var offline: OfflineStore
    @EnvironmentObject private var profiles: Profiles
    @EnvironmentObject private var app: AppState
    @State private var importing = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        OfflineAreasView()
                    } label: {
                        Label("Offline maps", systemImage: "arrow.down.circle")
                            .badge(offline.areas.count)
                    }
                }
                Section("Saved trails") {
                    if library.trails.isEmpty {
                        Text("Tap the bookmark on a trail to keep it here, or import a GPX file.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(library.trails) { t in
                        NavigationLink(value: t) {
                            TrailRow(trail: profiles.withProfile(t))
                        }
                    }
                    .onDelete { library.removeTrails(at: $0) }
                }
            }
            .navigationTitle("Saved")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { importing = true } label: { Label("Import GPX", systemImage: "square.and.arrow.down") }
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.gpx, .xml], allowsMultipleSelection: true) { result in
                if case .success(let urls) = result {
                    for url in urls { app.importGPX(from: url) }
                }
            }
            .navigationDestination(for: Trail.self) { TrailDetailView(trail: $0) }
        }
    }
}

struct OfflineAreasView: View {
    @EnvironmentObject private var offline: OfflineStore
    @State private var adding = false

    var body: some View {
        List {
            Section {
                Text("Download a topo or satellite map and the trails for an area before you lose signal. Without signal, switch the map style to the one you downloaded.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(offline.areas) { area in
                OfflineAreaRow(area: area, progress: offline.progress[area.id])
                    .swipeActions(edge: .leading) {
                        if !area.complete && !offline.isDownloading(area.id) {
                            Button("Retry") { offline.retry(area) }.tint(.trailGreen)
                        }
                    }
            }
            .onDelete { offline.delete(at: $0) }
        }
        .navigationTitle("Offline maps")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { adding = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Download an area")
            }
        }
        .overlay {
            if offline.areas.isEmpty {
                ContentUnavailableView {
                    Label("No offline maps", systemImage: "map")
                } description: {
                    Text("Tap + to download the area you're heading to.")
                } actions: {
                    Button("Download an area") { adding = true }
                }
            }
        }
        .sheet(isPresented: $adding) { NewOfflineAreaView() }
    }
}

struct OfflineAreaRow: View {
    let area: OfflineArea
    let progress: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(area.name).font(.headline)
            if let progress {
                ProgressView(value: progress)
                Text("Downloading… \(area.downloaded.formatted()) of \(area.tileCount.formatted()) tiles")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(area.complete ? Color.secondary : Color.orange)
            }
        }
    }

    private var summary: String {
        var parts = [area.baseMap.shortTitle, ByteCountFormatter.string(fromByteCount: area.bytes, countStyle: .file),
                     "\(area.trailCount) trails"]
        if !area.complete { parts.append("incomplete, swipe right to retry") }
        if area.failed > 0 { parts.append("\(area.failed) tiles missing") }
        return parts.joined(separator: " · ")
    }
}

struct NewOfflineAreaView: View {
    @EnvironmentObject private var offline: OfflineStore
    @EnvironmentObject private var explore: ExploreModel
    @EnvironmentObject private var recorder: Recorder
    @AppStorage(BaseMap.storageKey) private var baseMap: BaseMap = .standard
    @Environment(\.dismiss) private var dismiss
    @State private var region: MKCoordinateRegion?
    @State private var name = ""
    @State private var detail = 15
    @State private var start: CameraRequest?
    @State private var source: BaseMap = .topo
    private var box: BBox? { region.map { BBox(region: $0) } }
    private var count: Int {
        guard let box else { return 0 }
        return TileStore.tileCount(box, minZoom: 6, maxZoom: min(detail, source.maxZoom))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ZStack(alignment: .bottomLeading) {
                    TrailMapView(baseMap: source, camera: start, onRegionChange: { region = $0 })
                    Rectangle()
                        .strokeBorder(Color.trailGreen, lineWidth: 4)
                        .allowsHitTesting(false)
                    MapAttribution(baseMap: source)
                }
                Form {
                    TextField("Name (e.g. Yosemite Valley)", text: $name)
                    Picker("Map", selection: $source) {
                        ForEach(BaseMap.baseStyles.filter(\.isTiled)) { Text($0.title).tag($0) }
                    }
                    Picker("Detail", selection: $detail) {
                        Text("Low").tag(13)
                        Text("Medium").tag(14)
                        Text("High").tag(15)
                        Text("Highest").tag(source.maxZoom)
                    }
                    LabeledContent("Size", value: sizeText)
                    if count > OfflineStore.maxTiles {
                        Text("That's too big. Zoom the map in or lower the detail.")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    } else {
                        Text("Everything inside the green frame is downloaded, with the trails in it.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(height: 330)
            }
            .navigationTitle("Download area")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Download") {
                        guard let box else { return }
                        offline.download(name: name, bbox: box, source: source, maxZoom: detail)
                        dismiss()
                    }
                    .disabled(box == nil || count == 0 || count > OfflineStore.maxTiles)
                }
            }
            .onChange(of: source) { _, new in detail = min(detail, new.maxZoom) }
            .onAppear {
                source = baseMap.offlineSource
                if let r = explore.visibleRegion {
                    start = CameraRequest(region: r)
                } else if let loc = recorder.lastLocation {
                    start = CameraRequest(region: MKCoordinateRegion(center: loc.coordinate, latitudinalMeters: 15_000, longitudinalMeters: 15_000))
                }
            }
        }
    }

    private var sizeText: String {
        let bytes = Int64(count) * source.averageTileBytes
        return "\(count.formatted()) tiles · about \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))"
    }
}
