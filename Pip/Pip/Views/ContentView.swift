import PhotosUI
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var library: PhotoLibrary
    @EnvironmentObject private var engine: PipEngine
    @State private var picked: [PhotosPickerItem] = []
    @State private var confirmRemoveAll = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                PreviewPanel()
                List {
                    optionsSection
                    photosSection
                }
            }
            .navigationTitle("Pip")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !library.photos.isEmpty { EditButton() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    PhotosPicker(selection: $picked, maxSelectionCount: 60, matching: .images) {
                        Label("Add photos", systemImage: "plus")
                    }
                }
            }
            .onChange(of: picked) { _, items in
                guard !items.isEmpty else { return }
                picked = []
                Task { await library.add(items) }
            }
            .alert("Picture in Picture", isPresented: Binding(get: { engine.message != nil }, set: { if !$0 { engine.message = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(engine.message ?? "")
            }
            .alert("Some photos could not be added", isPresented: Binding(get: { library.failed > 0 && library.importing == 0 }, set: { if !$0 { library.failed = 0 } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(library.failed == 1 ? "1 photo could not be read." : "\(library.failed) photos could not be read.")
            }
        }
    }

    private var optionsSection: some View {
        Section {
            Picker("Photos at once", selection: $engine.settings.perPage) {
                ForEach(PipSettings.perPageChoices, id: \.self) { Text("\($0)").tag($0) }
            }
            if engine.settings.perPage > 1 {
                Picker("Arrangement", selection: $engine.settings.arrangement) {
                    ForEach(PipSettings.Arrangement.allCases) { Text($0.title).tag($0) }
                }
            }
            Picker("Window shape", selection: $engine.settings.shape) {
                ForEach(PipSettings.Shape.allCases) { Text($0.title).tag($0) }
            }
            Toggle("Crop photos to fill", isOn: $engine.settings.fill)
            Toggle("Change photos automatically", isOn: $engine.settings.autoAdvance)
            if engine.settings.autoAdvance {
                Stepper("Every \(engine.settings.seconds) seconds", value: $engine.settings.seconds, in: 2...120)
            }
            Toggle("Open when leaving the app", isOn: $engine.settings.startOnLeave)
        } header: {
            Text("Floating window")
        } footer: {
            Text("In the floating window, the skip buttons go to the previous or next photos, and play/pause turns automatic changing on or off.")
        }
    }

    private var photosSection: some View {
        Section {
            ForEach(Array(library.photos.enumerated()), id: \.element.id) { index, photo in
                Button {
                    engine.show(photoAt: index)
                } label: {
                    HStack(spacing: 12) {
                        Thumbnail(photo: photo)
                        Text("Photo \(index + 1)")
                            .foregroundStyle(.primary)
                        Spacer()
                        if index / engine.settings.perPage == engine.page {
                            Image(systemName: "eye.fill")
                                .foregroundStyle(.secondary)
                                .accessibilityLabel("Showing")
                        }
                    }
                }
            }
            .onDelete { library.remove(atOffsets: $0) }
            .onMove { library.move(fromOffsets: $0, toOffset: $1) }

            if library.importing > 0 {
                HStack(spacing: 12) {
                    ProgressView()
                    Text(library.importing == 1 ? "Adding 1 photo…" : "Adding \(library.importing) photos…")
                        .foregroundStyle(.secondary)
                }
            }
            PhotosPicker(selection: $picked, maxSelectionCount: 60, matching: .images) {
                Label("Add photos", systemImage: "photo.badge.plus")
            }
            if library.photos.count > 1 {
                Button("Remove all photos", role: .destructive) { confirmRemoveAll = true }
                    .confirmationDialog("Remove all \(library.photos.count) photos from Pip?", isPresented: $confirmRemoveAll, titleVisibility: .visible) {
                        Button("Remove all", role: .destructive) { library.removeAll() }
                    } message: {
                        Text("They stay in your photo library.")
                    }
            }
        } header: {
            Text(library.photos.isEmpty ? "Photos" : "Photos (\(library.photos.count))")
        } footer: {
            if library.photos.count > 1 {
                Text("Tap Edit to reorder or remove photos.")
            }
        }
    }
}

/// The picture the floating window shows, with the buttons that drive it.
private struct PreviewPanel: View {
    @EnvironmentObject private var library: PhotoLibrary
    @EnvironmentObject private var engine: PipEngine

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Color.black
                LayerView(view: engine.preview)
                if library.photos.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.largeTitle)
                        Text("Add photos to float them over other apps")
                            .font(.callout)
                            .multilineTextAlignment(.center)
                    }
                    .foregroundStyle(.white.opacity(0.75))
                    .padding()
                }
            }
            .aspectRatio(engine.canvasAspect, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .frame(maxWidth: .infinity, maxHeight: 260)

            if engine.pageCount > 1 {
                HStack(spacing: 24) {
                    Button { engine.step(-1) } label: {
                        Image(systemName: "chevron.left").frame(width: 44, height: 32)
                    }
                    .accessibilityLabel("Previous")
                    Text("\(engine.page + 1) of \(engine.pageCount)")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Button { engine.step(1) } label: {
                        Image(systemName: "chevron.right").frame(width: 44, height: 32)
                    }
                    .accessibilityLabel("Next")
                }
            }

            if engine.isSupported {
                Button {
                    engine.toggle()
                } label: {
                    Label(engine.isActive ? "Close floating window" : "Float over other apps",
                          systemImage: engine.isActive ? "pip.exit" : "pip.enter")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(library.photos.isEmpty)
            } else {
                Text("This device does not support Picture in Picture.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(Color(.systemGroupedBackground))
    }
}

private struct LayerView: UIViewRepresentable {
    let view: PreviewView
    func makeUIView(context: Context) -> PreviewView { view }
    func updateUIView(_ uiView: PreviewView, context: Context) {}
}

private struct Thumbnail: View {
    @EnvironmentObject private var library: PhotoLibrary
    let photo: Photo

    var body: some View {
        Group {
            if let image = library.thumbnail(photo) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Color.secondary.opacity(0.2)
            }
        }
        .frame(width: 52, height: 52)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
