import SwiftUI

struct ActivityListView: View {
    @EnvironmentObject private var library: Library

    var body: some View {
        NavigationStack {
            List {
                if !library.activities.isEmpty {
                    Section {
                        HStack {
                            StatTile(title: "Hikes", value: "\(library.activities.count)")
                            StatTile(title: "Distance", value: Fmt.distance(library.activities.reduce(0) { $0 + $1.distance }))
                            StatTile(title: "Climbed", value: Fmt.elevation(library.activities.reduce(0) { $0 + $1.gain }))
                        }
                    }
                }
                Section {
                    ForEach(library.activities) { a in
                        NavigationLink(value: a) { ActivityRow(activity: a) }
                    }
                    .onDelete { library.deleteActivities(at: $0) }
                }
            }
            .overlay {
                if library.activities.isEmpty {
                    ContentUnavailableView("No hikes yet", systemImage: "figure.hiking",
                                           description: Text("Hikes you record in the Record tab show up here."))
                }
            }
            .navigationTitle("Activity")
            .navigationDestination(for: Activity.self) { ActivityDetailView(activity: $0) }
        }
    }
}

struct ActivityRow: View {
    let activity: Activity

    var body: some View {
        HStack(spacing: 12) {
            TrailThumbnail(trail: activity.asTrail(), size: 56)
            VStack(alignment: .leading, spacing: 3) {
                Text(activity.name).font(.headline).lineLimit(1)
                Text(activity.start.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(Fmt.distance(activity.distance)) · \(Fmt.duration(activity.elapsedTime)) · ↑ \(Fmt.elevation(activity.gain))")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct ActivityDetailView: View {
    let activity: Activity
    @EnvironmentObject private var library: Library
    @Environment(\.dismiss) private var dismiss
    @AppStorage(BaseMap.storageKey) private var baseMap: BaseMap = .switchback
    @State private var gpxURL: URL?
    @State private var renaming = false
    @State private var newName = ""
    @State private var confirmDelete = false
    @State private var savedAsTrail = false
    @State private var hikePhotos: [HikePhoto] = []
    @State private var thumbs: [String: UIImage] = [:]
    @State private var photosChecked = false

    private var photoPins: [PhotoPin] {
        hikePhotos.compactMap { p in
            guard let c = p.coord, let img = thumbs[p.id] else { return nil }
            return PhotoPin(id: p.id, coord: c, image: img)
        }
    }

    @ViewBuilder
    private var photosSection: some View {
        if !hikePhotos.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Your photos").font(.headline)
                HikePhotoStrip(photos: hikePhotos, thumbs: thumbs)
            }
        } else if !HikePhotos.isAuthorized {
            Button {
                Task {
                    if await HikePhotos.requestAccess() { await loadPhotos(current) }
                }
            } label: {
                Label("Show my photos from this hike", systemImage: "photo.on.rectangle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        } else if photosChecked {
            Text("No photos in your library from during this hike.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func loadPhotos(_ a: Activity) async {
        let found = HikePhotos.photos(for: a)
        hikePhotos = found
        photosChecked = true
        for p in found.prefix(60) {
            if let img = await HikePhotos.image(p.asset, size: CGSize(width: 240, height: 240)) {
                thumbs[p.id] = img
            }
        }
    }

    private var current: Activity { library.activities.first { $0.id == activity.id } ?? activity }

    var body: some View {
        let a = current
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ZStack(alignment: .bottomLeading) {
                    AppMap(baseMap: baseMap, track: a.coordSegments, initialBox: a.bbox, showsUserButton: false,
                                 photos: photoPins)
                    MapAttribution(baseMap: baseMap)
                }
                .frame(height: 300)
                .clipShape(RoundedRectangle(cornerRadius: 18))

                VStack(alignment: .leading, spacing: 4) {
                    Text(a.name).font(.title2.bold())
                    Text(a.start.formatted(date: .complete, time: .shortened))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if let t = a.trailName {
                        Label("Followed \(t)", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3), alignment: .leading, spacing: 14) {
                    StatTile(title: "Distance", value: Fmt.distance(a.distance))
                    StatTile(title: "Elevation gain", value: Fmt.elevation(a.gain))
                    StatTile(title: "Pace", value: Fmt.pace(distance: a.distance, time: a.movingTime))
                    StatTile(title: "Moving time", value: Fmt.clock(a.movingTime))
                    StatTile(title: "Total time", value: Fmt.clock(a.elapsedTime))
                    StatTile(title: "Finished", value: a.end.formatted(date: .omitted, time: .shortened))
                }

                photosSection

                if let p = a.profile {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Elevation").font(.headline)
                        ElevationChart(profile: p)
                        Text("From the phone's GPS altitude.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 10) {
                    if let gpxURL {
                        ShareLink(item: gpxURL) {
                            Label("Share GPX", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    Button {
                        library.save(a.asTrail())
                        savedAsTrail = true
                    } label: {
                        Label(savedAsTrail ? "Saved" : "Save as trail", systemImage: savedAsTrail ? "checkmark" : "bookmark")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(savedAsTrail)
                }
                .controlSize(.large)
            }
            .padding()
        }
        .navigationTitle(a.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        newName = a.name
                        renaming = true
                    } label: { Label("Rename", systemImage: "pencil") }
                    Button(role: .destructive) { confirmDelete = true } label: { Label("Delete", systemImage: "trash") }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .alert("Rename hike", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Save") { library.renameActivity(id: a.id, to: newName) }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete this hike?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                library.deleteActivity(id: a.id)
                dismiss()
            }
        }
        .task(id: a.id) {
            if HikePhotos.isAuthorized { await loadPhotos(a) }
        }
        .task(id: a.name) {
            savedAsTrail = library.isSaved("rec-\(a.id.uuidString)")
            gpxURL = try? GPX.file(named: a.name, contents: GPX.document(for: a))
        }
    }
}
