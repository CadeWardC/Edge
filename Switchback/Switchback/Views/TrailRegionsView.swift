import SwiftUI

/// The trail files: which regions are on the phone, and the rest to download (for a trip without signal).
struct TrailRegionsView: View {
    @State private var regions: [TrailPacks.Summary] = []
    @State private var busy: Set<String> = []
    @State private var failed: Set<String> = []
    @State private var query = ""

    private static let countries = ["US": "United States", "CA": "Canada"]

    var body: some View {
        List {
            let onPhone = shown.filter(\.onPhone)
            if !onPhone.isEmpty {
                Section {
                    ForEach(onPhone) { row($0) }
                        .onDelete { offsets in
                            for i in offsets where !onPhone[i].builtIn {
                                let id = onPhone[i].id
                                Task {
                                    await TrailPacks.shared.remove(region: id)
                                    await reload()
                                }
                            }
                        }
                } header: {
                    Text("On this phone")
                } footer: {
                    Text("Your area downloads first, then the rest of your country on Wi-Fi. Others download by themselves when the map shows them, or here before a trip.")
                }
            }
            ForEach(countries, id: \.self) { code in
                let available = shown.filter { !$0.onPhone && $0.country == code }
                if !available.isEmpty {
                    Section(Self.countries[code] ?? code) {
                        ForEach(available) { row($0) }
                    }
                }
            }
        }
        .navigationTitle("Trail regions")
        .searchable(text: $query, prompt: "Find a state or region")
        .task { await reload() }
        .refreshable { await reload() }
        .overlay {
            if regions.isEmpty {
                ContentUnavailableView("No list yet", systemImage: "map",
                                       description: Text("Connect to the internet to see the regions you can download."))
            }
        }
    }

    private var shown: [TrailPacks.Summary] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return regions }
        return regions.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    private var countries: [String] {
        Array(Set(regions.map(\.country))).sorted { ($0 == "US" ? "" : $0) < ($1 == "US" ? "" : $1) }
    }

    @ViewBuilder
    private func row(_ r: TrailPacks.Summary) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(r.name)
                Text("\(r.trails.formatted()) trails · \(ByteCountFormatter.string(fromByteCount: Int64(r.bytes), countStyle: .file))"
                     + (r.builtIn ? " · built in" : ""))
                    .font(.caption)
                    .foregroundStyle(failed.contains(r.id) ? Color.red : Color.secondary)
            }
            Spacer()
            if busy.contains(r.id) {
                ProgressView()
            } else if r.onPhone {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.trailGreen)
            } else {
                Button {
                    busy.insert(r.id)
                    failed.remove(r.id)
                    Task {
                        let ok = await TrailPacks.shared.download(region: r.id)
                        busy.remove(r.id)
                        if !ok { failed.insert(r.id) }
                        await reload()
                    }
                } label: {
                    Image(systemName: "arrow.down.circle").font(.title3)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Download \(r.name)")
            }
        }
    }

    private func reload() async {
        regions = await TrailPacks.shared.summaries()
    }
}
