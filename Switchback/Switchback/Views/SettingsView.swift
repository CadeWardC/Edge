import SwiftUI

struct SettingsView: View {
    @AppStorage(Units.storageKey) private var units: Units = .systemDefault
    @AppStorage(BaseMap.storageKey) private var baseMap: BaseMap = .standard
    @Environment(\.dismiss) private var dismiss
    @State private var cacheSize: Int64 = 0

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
                        ForEach(BaseMap.allCases) { Text($0.title).tag($0) }
                    }
                } footer: {
                    Text("Topo and USGS Satellite maps can be downloaded for offline use (Saved › Offline maps). USGS covers the United States only.")
                }
                Section("Storage") {
                    LabeledContent("Map cache", value: ByteCountFormatter.string(fromByteCount: cacheSize, countStyle: .file))
                    Button("Clear map and trail cache") {
                        TileStore.shared.clearCache()
                        Task { await TrailCache.shared.clear() }
                        cacheSize = 0
                    }
                }
                Section("Data") {
                    Text("Trails: © OpenStreetMap contributors, available under the Open Database Licence.")
                    Text("Elevation: Open-Meteo (CC BY 4.0), from the Copernicus DEM GLO-90.")
                    Text("Topo map: OpenTopoMap (CC-BY-SA). USGS Topo and Satellite: U.S. Geological Survey (public domain).")
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
                let tiles = await Task.detached { TileStore.shared.cacheSize() }.value
                cacheSize = tiles + (await TrailCache.shared.size())
            }
        }
    }
}
