import SceneKit
import SwiftUI

/// Pick an aircraft, look at it, and add your own.
struct HangarView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var catalog: AircraftCatalog
    @Environment(\.dismiss) private var dismiss
    @State private var shownID = ""
    @State private var preview: SCNScene?

    private var shown: AircraftSpec? {
        catalog.aircraft.first { $0.id == shownID } ?? model.selected
    }

    var body: some View {
        NavigationStack {
            HStack(spacing: 0) {
                List {
                    Section("Aircraft") {
                        ForEach(catalog.aircraft) { spec in
                            Button { show(spec) } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(spec.name).foregroundStyle(.primary)
                                        Text(catalog.custom.contains(spec.id) ? "\(spec.type) · yours" : spec.type)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if spec.id == model.selectedID {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.green)
                                            .accessibilityLabel("Chosen")
                                    }
                                }
                            }
                            .listRowBackground(spec.id == shown?.id ? Color.accentColor.opacity(0.15) : nil)
                        }
                    }
                    Section {
                        Button { catalog.reload() } label: { Label("Reload aircraft", systemImage: "arrow.clockwise") }
                        ForEach(catalog.problems, id: \.self) { problem in
                            Label(problem, systemImage: "exclamationmark.triangle.fill")
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }
                    } header: {
                        Text("Make your own")
                    } footer: {
                        Text("Every aircraft is a small text file. In the Files app open On My iPhone › Skylark, copy a file from Examples into Aircraft, give it a new \"id\", change what you like, then tap Reload. \"How to make aircraft.txt\" in Examples explains every setting.")
                    }
                }
                .frame(width: 300)

                if let spec = shown {
                    detail(spec)
                } else {
                    Text("No aircraft found").frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("Hangar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear { if let spec = model.selected { show(spec) } }
            .onChange(of: catalog.aircraft.map(\.id)) { _, _ in
                if let spec = shown { show(spec) }
            }
        }
    }

    private func show(_ spec: AircraftSpec) {
        shownID = spec.id
        preview = AircraftBuilder.previewScene(spec)
    }

    private func detail(_ spec: AircraftSpec) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SceneView(scene: preview, options: [.allowsCameraControl, .rendersContinuously])
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("\(spec.name), turning")
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(spec.name).font(.title3.weight(.bold))
                    if let description = spec.description {
                        Text(description).font(.footnote).foregroundStyle(.secondary)
                    }
                    Text(Self.facts(spec)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if spec.id == model.selectedID {
                    Label("Chosen", systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.green)
                } else {
                    Button("Fly this") { model.select(spec) }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(12)
    }

    private static func facts(_ spec: AircraftSpec) -> String {
        let flight = spec.flight
        var facts: [String] = []
        if let top = flight?.topSpeed { facts.append("Top speed \(Int(top)) kt") }
        if spec.type == "plane", let stall = flight?.stallSpeed { facts.append("stalls at \(Int(stall)) kt") }
        if spec.type == "plane", let roll = flight?.rollRate { facts.append("rolls \(Int(roll))° a second") }
        return facts.joined(separator: " · ")
    }
}
