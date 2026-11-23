import SwiftUI

/// Pick, unlock and add aircraft.
struct HangarView: View {
    @EnvironmentObject private var model: GameModel
    @EnvironmentObject private var catalog: AircraftCatalog
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 14) {
                            ForEach(catalog.aircraft) { AircraftCard(spec: $0) }
                        }
                        .padding(.horizontal)
                    }
                    makeYourOwn
                        .padding(.horizontal)
                }
                .padding(.vertical)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Hangar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Label("\(model.totalStars)", systemImage: "star.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.headline)
                        .foregroundStyle(.orange)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var makeYourOwn: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Make your own")
                .font(.headline)
            Text("Every aircraft is a small text file. Open the Files app › On My iPhone › Skylark. Copy a file from Examples into Aircraft, give it a new \"id\" and change whatever you like, then tap Reload. \"How to make aircraft.txt\" in Examples explains every setting.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button { catalog.reload() } label: { Label("Reload aircraft", systemImage: "arrow.clockwise") }
                .buttonStyle(.bordered)
            ForEach(catalog.problems, id: \.self) { problem in
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct AircraftCard: View {
    @EnvironmentObject private var model: GameModel
    @EnvironmentObject private var catalog: AircraftCatalog
    let spec: AircraftSpec

    var body: some View {
        let stats = spec.tunedStats
        let isSelected = model.selectedID == spec.id
        VStack(alignment: .leading, spacing: 8) {
            Image(uiImage: AircraftArt.image(for: spec, size: CGSize(width: 190, height: 96)))
                .frame(width: 190, height: 96)
                .background(LinearGradient(colors: [Color(red: 0.45, green: 0.74, blue: 0.93), Color(red: 0.8, green: 0.92, blue: 0.99)], startPoint: .top, endPoint: .bottom),
                            in: RoundedRectangle(cornerRadius: 12))
            HStack {
                Text(spec.name).font(.headline)
                Spacer()
                Text(catalog.custom.contains(spec.id) ? "yours" : spec.type)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color(.tertiarySystemFill), in: Capsule())
            }
            StatBar(name: "Speed", value: (stats.speed - 80) / 200)
            StatBar(name: "Climb", value: (stats.climb - 0.4) / 1.2)
            StatBar(name: "Agility", value: (stats.agility - 0.4) / 1.4)
            if stats.magnet > 0 { StatBar(name: "Magnet", value: stats.magnet / 80) }
            if let description = spec.description {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if isSelected {
                Label("Flying this", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.green)
                    .frame(maxWidth: .infinity, minHeight: 34)
            } else if model.isUnlocked(spec) {
                Button { model.select(spec) } label: { Text("Fly this").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent)
            } else {
                Button { model.unlock(spec) } label: {
                    Label("Unlock for \(spec.cost)", systemImage: "star.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .disabled(model.totalStars < spec.cost)
            }
        }
        .padding(12)
        .frame(width: 214)
        .frame(minHeight: 300, alignment: .top)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(isSelected ? Color.green : .clear, lineWidth: 2))
    }
}

private struct StatBar: View {
    let name: String
    let value: Double

    var body: some View {
        HStack(spacing: 8) {
            Text(name)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .leading)
            ProgressView(value: min(max(value, 0.04), 1))
                .tint(.blue)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name) \(Int(min(max(value, 0), 1) * 100)) percent")
    }
}
