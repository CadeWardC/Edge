import SwiftUI

struct SettingsView: View {
    @AppStorage(Units.storageKey) private var units: Units = .systemDefault
    @AppStorage(BaseMap.storageKey) private var baseMap: BaseMap = .switchback
    @Environment(\.dismiss) private var dismiss
    @State private var cacheSize: Int64 = 0
    @State private var packStatus: [String] = []
    @State private var updating = false
    @State private var updateResult: String?
    @AppStorage(BaseMap.showRoutesKey) private var showRoutes = false
    @AppStorage(USFS.enabledKey) private var usfsTrails = true
    @AppStorage(Overpass.unnamedKey) private var unnamedTrails = true

    var body: some View {
        NavigationStack {
            Form {
                Section("Units") {
                    Picker("Units", selection: $units) {
                        ForEach(Units.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                Section {
                    Picker("Map style", selection: $baseMap) {
                        ForEach(BaseMap.baseStyles) { Text($0.title).tag($0) }
                    }
                    Toggle("Waymarked hiking routes", isOn: $showRoutes)
                    Toggle("U.S. Forest Service trails", isOn: $usfsTrails)
                    Toggle("Unnamed trails", isOn: $unnamedTrails)
                } footer: {
                    Text("The Switchback map (our own, in light and dark), Topo and USGS Satellite can be downloaded for offline use (Saved › Offline maps); the Switchback map is the smallest and stays sharp at every zoom. USGS covers the United States only. Waymarked routes draws every signposted hiking route in the world on top of the map. Forest Service trails add official national forest trails in the US. Unnamed trails are paths mapped without a name, drawn dashed. Clear the cache for these switches to apply to places you've already seen.")
                }
                Section("Storage") {
                    LabeledContent("Map cache", value: ByteCountFormatter.string(fromByteCount: cacheSize, countStyle: .file))
                    Button("Clear map and trail cache") {
                        TileStore.shared.clearCache()
                        Task {
                            await TrailCache.shared.clear()
                            await TrailPacks.shared.clear()
                        }
                        cacheSize = 0
                    }
                }
                Section {
                    Button {
                        updating = true
                        updateResult = nil
                        Task {
                            updateResult = await TrailPacks.shared.checkForUpdates()
                            packStatus = await TrailPacks.shared.statusLines()
                            updating = false
                        }
                    } label: {
                        HStack {
                            Label("Check for trail updates", systemImage: "arrow.triangle.2.circlepath")
                            Spacer()
                            if updating { ProgressView() }
                        }
                    }
                    .disabled(updating)
                    if let updateResult {
                        Text(updateResult).font(.footnote).foregroundStyle(.secondary)
                    }
                    NavigationLink {
                        TrailRegionsView()
                    } label: {
                        Label("Trail regions", systemImage: "square.stack.3d.down.right")
                    }
                    if packStatus.isEmpty {
                        Text("No state trail files yet; they download when the map first shows a state.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(packStatus, id: \.self) { Text($0).font(.caption.monospaced()) }
                } header: {
                    Text("Trail files")
                } footer: {
                    Text("Every US state's trails come with the app, so they work offline from the start; other regions download when the map shows them. They're rebuilt from OpenStreetMap every week; the app picks up new versions for the states you look at by itself every few days, or right away here.")
                }
                Section("Data") {
                    Text("Trails: © OpenStreetMap contributors, available under the Open Database Licence.")
                    Text("Elevation: Open-Meteo (CC BY 4.0), from the Copernicus DEM GLO-90.")
                    Text("Topo map: OpenTopoMap (CC-BY-SA). USGS Topo and Satellite: U.S. Geological Survey (public domain).")
                    Text("Hiking routes layer: waymarkedtrails.org (CC-BY-SA). Forest Service trails: USDA Forest Service (public domain).")
                    Link("OpenStreetMap copyright", destination: URL(string: "https://www.openstreetmap.org/copyright")!)
                    Link("Fix or add a trail on OpenStreetMap", destination: URL(string: "https://www.openstreetmap.org/")!)
                }
                .font(.footnote)
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task {
                packStatus = await TrailPacks.shared.statusLines()
                let tiles = await Task.detached { TileStore.shared.cacheSize() }.value
                cacheSize = tiles + (await TrailCache.shared.size()) + (await TrailPacks.shared.size())
            }
        }
    }
}
