import MapKit
import SwiftUI

struct ExploreView: View {
    @EnvironmentObject private var model: ExploreModel
    @EnvironmentObject private var recorder: Recorder
    @EnvironmentObject private var profiles: Profiles
    @AppStorage(BaseMap.storageKey) private var baseMap: BaseMap = .standard
    @State private var mode: Mode = .map
    @State private var query = ""
    @State private var showFilters = false
    @State private var showSettings = false
    @State private var didCenter = false

    enum Mode: String, CaseIterable { case map = "Map", list = "List" }

    var body: some View {
        NavigationStack {
            Group {
                if mode == .map { mapMode } else { listMode }
            }
            .navigationTitle("Explore")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search a place or park")
            .onSubmit(of: .search) {
                Task { await model.searchPlace(query) }
            }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("View", selection: $mode) {
                        ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 160)
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Settings")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showFilters = true } label: {
                        Image(systemName: model.filters.isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                    }
                    .accessibilityLabel("Filters")
                }
            }
            .navigationDestination(for: Trail.self) { TrailDetailView(trail: $0) }
            .sheet(isPresented: $showFilters) {
                FiltersView(filters: $model.filters, sort: $model.sort)
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .onAppear {
                recorder.locateOnce()
                if !didCenter, let loc = recorder.lastLocation {
                    didCenter = true
                    model.center(on: loc, searchIfEmpty: true)
                }
            }
            .onReceive(recorder.$lastLocation) { loc in
                guard !didCenter, let loc else { return }
                didCenter = true
                model.center(on: loc, searchIfEmpty: true)
            }
        }
    }

    // MARK: Map

    private var mapMode: some View {
        let trails = model.filtered
        return ZStack {
            TrailMapView(baseMap: baseMap, trails: trails, selectedId: model.selectedId, camera: model.cameraRequest,
                         onSelect: { id in withAnimation(.snappy) { model.selectedId = id } },
                         onRegionChange: { model.regionChanged($0) })

            VStack(spacing: 8) {
                statusBar
                Spacer()
                if let t = model.selectedTrail {
                    NavigationLink(value: t) {
                        HStack {
                            TrailRow(trail: t, distanceAway: model.distanceFromUser(t))
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }
                        .padding(12)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                } else if !trails.isEmpty {
                    Button { mode = .list } label: {
                        Label("\(trails.count) trails · List", systemImage: "list.bullet")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(.regularMaterial, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                HStack {
                    MapAttribution(baseMap: baseMap)
                    Spacer()
                    mapStyleMenu
                }
            }
            .padding(.bottom, 4)
        }
    }

    @ViewBuilder
    private var statusBar: some View {
        VStack(spacing: 6) {
            if model.isLoading {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Finding trails…")
                }
                .font(.subheadline.weight(.semibold))
                .capsuleStyle()
            } else if model.regionMoved || model.results.isEmpty {
                Button { model.searchVisibleArea() } label: {
                    Label(model.isTooWide ? "Search the middle of this area" : "Search this area", systemImage: "magnifyingglass")
                        .font(.subheadline.weight(.semibold))
                        .capsuleStyle()
                }
                .buttonStyle(.plain)
            }
            if let e = model.errorText {
                Text(e)
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .capsuleStyle()
            } else if model.usedOffline {
                Label("No signal: showing downloaded trails", systemImage: "wifi.slash")
                    .font(.caption)
                    .capsuleStyle()
            }
        }
        .padding(.top, 8)
        .padding(.horizontal, 60)
    }

    private var mapStyleMenu: some View {
        Menu {
            Picker("Map style", selection: $baseMap) {
                ForEach(BaseMap.allCases) { Text($0.title).tag($0) }
            }
        } label: {
            Image(systemName: "square.3.layers.3d")
                .font(.title3)
                .padding(10)
                .background(.regularMaterial, in: Circle())
        }
        .padding(10)
    }

    // MARK: List

    private var listMode: some View {
        let trails = model.filtered
        return List {
            Section {
                ForEach(trails) { t in
                    NavigationLink(value: t) {
                        TrailRow(trail: t, distanceAway: model.distanceFromUser(t))
                    }
                }
            } header: {
                HStack {
                    Text(model.isLoading ? "Searching…" : "\(trails.count) trails")
                    Spacer()
                    Menu {
                        Picker("Sort", selection: $model.sort) {
                            ForEach(TrailSort.allCases) { Text($0.title).tag($0) }
                        }
                    } label: {
                        Label(model.sort.title, systemImage: "arrow.up.arrow.down")
                            .font(.caption.weight(.semibold))
                    }
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if trails.isEmpty && !model.isLoading {
                ContentUnavailableView {
                    Label("No trails", systemImage: "figure.hiking")
                } description: {
                    Text(model.results.isEmpty
                         ? "Move the map to where you want to hike and tap Search this area."
                         : "No trails match your filters.")
                } actions: {
                    if model.results.isEmpty {
                        Button("Show map") { mode = .map }
                    } else {
                        Button("Clear filters") { model.filters = TrailFilters() }
                    }
                }
            }
        }
    }
}

private extension View {
    func capsuleStyle() -> some View {
        padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
    }
}

struct FiltersView: View {
    @Binding var filters: TrailFilters
    @Binding var sort: TrailSort
    @Environment(\.dismiss) private var dismiss

    private var lengthOptions: [Double?] {
        let imperial: [Double] = [1, 3, 5, 8, 12, 20]
        let metric: [Double] = [2, 5, 8, 12, 20, 30]
        let meters: [Double] = Units.current == .imperial
            ? imperial.map { $0 * Fmt.metersPerMile }
            : metric.map { $0 * 1000 }
        let options: [Double?] = meters.map { Optional($0) }
        return [nil] + options
    }

    private var gainOptions: [Double?] {
        let imperial: [Double] = [500, 1000, 2000, 3000, 5000]
        let metric: [Double] = [150, 300, 600, 1000, 1500]
        let meters: [Double] = Units.current == .imperial
            ? imperial.map { $0 / Fmt.feetPerMeter }
            : metric
        let options: [Double?] = meters.map { Optional($0) }
        return [nil] + options
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Sort by") {
                    Picker("Sort by", selection: $sort) {
                        ForEach(TrailSort.allCases) { Text($0.title).tag($0) }
                    }
                }
                Section("Difficulty") {
                    ForEach(Difficulty.allCases) { d in
                        Toggle(isOn: Binding(
                            get: { !filters.excluded.contains(d) },
                            set: { on in
                                if on { filters.excluded.remove(d) } else { filters.excluded.insert(d) }
                            }
                        )) {
                            DifficultyBadge(difficulty: d)
                        }
                    }
                }
                Section {
                    Picker("Max length", selection: $filters.maxLength) {
                        ForEach(lengthOptions, id: \.self) { v in
                            Text(v.map { Fmt.distance($0) } ?? "Any").tag(v)
                        }
                    }
                    Picker("Max elevation gain", selection: $filters.maxGain) {
                        ForEach(gainOptions, id: \.self) { v in
                            Text(v.map { Fmt.elevation($0) } ?? "Any").tag(v)
                        }
                    }
                    Toggle("Loops only", isOn: $filters.loopsOnly)
                } footer: {
                    Text("Difficulty is worked out from each trail's length and climb (and its SAC scale when mapped).")
                }
                Section {
                    Button("Reset filters", role: .destructive) { filters = TrailFilters() }
                        .disabled(!filters.isActive)
                }
            }
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
