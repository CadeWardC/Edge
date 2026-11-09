import MapKit
import SwiftUI
import UIKit

struct RecordView: View {
    @EnvironmentObject private var recorder: Recorder
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var profiles: Profiles
    @EnvironmentObject private var highlights: Highlights
    @AppStorage(BaseMap.storageKey) private var baseMap: BaseMap = .standard
    @AppStorage(BaseMap.showRoutesKey) private var showRoutes = false
    @State private var askName = false
    @State private var activityName = ""
    @State private var finished: Activity?
    @State private var camera: CameraRequest?
    @State private var showPicker = false
    @State private var confirmDiscard = false
    @State private var tooShort = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ZStack(alignment: .top) {
                    TrailMapView(baseMap: baseMap,
                                 trails: recorder.following.map { [$0] } ?? [],
                                 selectedId: recorder.following?.id,
                                 track: recorder.trackCoords,
                                 camera: camera,
                                 followUser: recorder.state == .recording,
                                 showsRoutes: showRoutes,
                                 pois: recorder.following.flatMap { highlights.pois(for: $0.id) } ?? [])
                    VStack(spacing: 8) {
                        if recorder.isDenied { permissionBanner }
                        if recorder.offTrail, let off = recorder.offset { offTrailBanner(off) }
                        Spacer()
                        HStack {
                            MapAttribution(baseMap: baseMap)
                            Spacer()
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                }
                panel
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                recorder.locateOnce()
                if camera == nil { centerCamera() }
            }
            .onChange(of: recorder.following?.id) { _, _ in centerCamera() }
            .task(id: recorder.following?.id) {
                guard let t = recorder.following else { return }
                async let profile = profiles.ensureProfile(for: t)
                await highlights.ensure(for: t)
                _ = await profile
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { recorder.voiceOn.toggle() } label: {
                        Image(systemName: recorder.voiceOn ? "speaker.wave.2.fill" : "speaker.slash")
                    }
                    .accessibilityLabel(recorder.voiceOn ? "Turn spoken updates off" : "Turn spoken updates on")
                }
            }
            .alert("Save hike", isPresented: $askName) {
                TextField("Name", text: $activityName)
                Button("Save") {
                    if let a = recorder.finish(name: activityName.isEmpty ? defaultName : activityName) {
                        finished = a
                    } else {
                        tooShort = true
                    }
                }
                Button("Keep going", role: .cancel) {}
            } message: {
                Text("It goes to Activity, where you can share it as GPX.")
            }
            .alert("Nothing to save", isPresented: $tooShort) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("The hike was too short to record a track.")
            }
            .confirmationDialog("Discard this hike?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Discard", role: .destructive) { recorder.discard() }
            }
            .navigationDestination(item: $finished) { ActivityDetailView(activity: $0) }
            .sheet(isPresented: $showPicker) { FollowPicker() }
        }
    }

    private var title: String {
        switch recorder.state {
        case .idle: return recorder.following == nil ? "Record" : "Navigate"
        case .recording: return "Recording"
        case .paused: return "Paused"
        }
    }

    private var defaultName: String {
        if let t = recorder.following { return t.name }
        let hour = Calendar.current.component(.hour, from: recorder.startDate ?? Date())
        switch hour {
        case 5..<12: return "Morning hike"
        case 12..<17: return "Afternoon hike"
        case 17..<21: return "Evening hike"
        default: return "Night hike"
        }
    }

    private func centerCamera() {
        if let t = recorder.following {
            camera = CameraRequest(box: t.bbox)
        } else if let loc = recorder.lastLocation {
            camera = CameraRequest(region: MKCoordinateRegion(center: loc.coordinate, latitudinalMeters: 2500, longitudinalMeters: 2500))
        }
    }

    // MARK: Banners

    private var permissionBanner: some View {
        VStack(spacing: 6) {
            Text("Location is off for Switchback").font(.subheadline.bold())
            Text("Turn it on to see where you are and record hikes.").font(.caption)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            .font(.caption.bold())
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private func offTrailBanner(_ meters: Double) -> some View {
        Label("Off trail: \(Fmt.shortDistance(meters)) away", systemImage: "exclamationmark.triangle.fill")
            .font(.subheadline.bold())
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.red, in: Capsule())
    }

    // MARK: Panel

    private var panel: some View {
        VStack(spacing: 14) {
            if let t = recorder.following {
                HStack(spacing: 8) {
                    Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                        .foregroundStyle(Color.trailGreen)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Following").font(.caption).foregroundStyle(.secondary)
                        Text(t.name).font(.subheadline.bold()).lineLimit(1)
                    }
                    Spacer()
                    if recorder.state == .idle {
                        Button { recorder.follow(nil) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                            .accessibilityLabel("Stop following")
                    }
                }
            }

            if let t = recorder.following, recorder.state != .idle {
                NavigationCard(trail: profiles.withProfile(t), pois: highlights.pois(for: t.id) ?? [], recorder: recorder)
            }

            if recorder.state != .idle {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3), alignment: .leading, spacing: 12) {
                        StatTile(title: "Time", value: Fmt.clock(recorder.elapsed(at: ctx.date)))
                        StatTile(title: "Distance", value: Fmt.distance(recorder.distance))
                        StatTile(title: "Elevation gain", value: Fmt.elevation(recorder.gain))
                        StatTile(title: "Pace", value: Fmt.pace(distance: recorder.distance, time: recorder.movingTime))
                        StatTile(title: "Moving time", value: Fmt.clock(recorder.movingTime))
                        if let r = recorder.remaining {
                            StatTile(title: "To the end", value: Fmt.distance(r))
                        } else {
                            StatTile(title: "Altitude", value: recorder.currentAltitude.map { Fmt.elevation($0) } ?? "–")
                        }
                    }
                }
            }

            controls
        }
        .padding()
        .background(.bar)
    }

    @ViewBuilder
    private var controls: some View {
        switch recorder.state {
        case .idle:
            VStack(spacing: 10) {
                Button {
                    recorder.start()
                } label: {
                    Label("Start hike", systemImage: "play.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(recorder.isDenied)

                if recorder.following == nil {
                    Button {
                        showPicker = true
                    } label: {
                        Label("Follow a saved trail", systemImage: "bookmark")
                    }
                    .font(.subheadline)
                }
            }
        case .recording, .paused:
            HStack(spacing: 10) {
                if recorder.state == .recording {
                    Button { recorder.pause() } label: {
                        Label("Pause", systemImage: "pause.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button { recorder.resume() } label: {
                        Label("Resume", systemImage: "play.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
                Button {
                    recorder.pause()
                    activityName = defaultName
                    askName = true
                } label: {
                    Label("Finish", systemImage: "flag.checkered").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.trailGreen)

                if recorder.state == .paused {
                    Button(role: .destructive) { confirmDiscard = true } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.bordered)
                }
            }
            .controlSize(.large)
        }
    }
}

/// Picks a saved trail to follow.
struct FollowPicker: View {
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var recorder: Recorder
    @EnvironmentObject private var profiles: Profiles
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(library.trails) { t in
                Button {
                    recorder.follow(t)
                    dismiss()
                } label: {
                    TrailRow(trail: profiles.withProfile(t))
                }
                .buttonStyle(.plain)
            }
            .overlay {
                if library.trails.isEmpty {
                    ContentUnavailableView("No saved trails", systemImage: "bookmark",
                                           description: Text("Save a trail from Explore or import a GPX file, then follow it here."))
                }
            }
            .navigationTitle("Follow a trail")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }
}

/// While following a trail: where you are on its elevation, when you'll get to the end compared with sunset,
/// the climbing left and the next water.
struct NavigationCard: View {
    let trail: Trail
    let pois: [TrailPOI]
    @ObservedObject var recorder: Recorder

    var body: some View {
        let along = recorder.along ?? 0
        let remaining = recorder.remaining ?? trail.length
        let climbLeft = Self.climbLeft(trail.profile, after: along)
        let arrival = Date().addingTimeInterval(timeLeft(remaining: remaining, climb: climbLeft))
        let sun = recorder.lastLocation.flatMap { Sun.times(on: Date(), at: Coord($0.coordinate)) }
        let late = sun.map { arrival > $0.sunset } ?? false
        let nextWater = pois.first { $0.kind == .water && $0.along > along + 20 }

        VStack(alignment: .leading, spacing: 8) {
            if let p = trail.profile {
                ElevationChart(profile: p, marker: recorder.along, height: 100)
            }
            HStack(alignment: .top) {
                tile("Arrive", arrival.formatted(date: .omitted, time: .shortened), warn: late)
                tile("Sunset", sun.map { $0.sunset.formatted(date: .omitted, time: .shortened) } ?? "–")
                tile("Climb left", Fmt.elevation(climbLeft))
                if let w = nextWater {
                    tile("Next water", Fmt.distance(w.along - along))
                }
            }
            if late {
                Label("At this pace you'd finish after sunset", systemImage: "sunset.fill")
                    .font(.caption.bold())
                    .foregroundStyle(.orange)
            }
        }
    }

    private func tile(_ title: String, _ value: String, warn: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(warn ? Color.orange : Color.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Your own moving pace once there's enough of it, Naismith's rule before that.
    private func timeLeft(remaining: Double, climb: Double) -> TimeInterval {
        if recorder.movingTime > 300 && recorder.distance > 400 {
            let speed = recorder.distance / recorder.movingTime
            return remaining / speed + climb / 600 * 3600 * 0.5
        }
        return (remaining / 1000 / 4.5 + climb / 600) * 3600
    }

    /// The climbing still ahead on the profile.
    static func climbLeft(_ p: ElevationProfile?, after along: Double) -> Double {
        guard let p, var last = ElevationChart.elevation(at: along, in: p) else { return 0 }
        var total = 0.0
        for (d, e) in zip(p.distances, p.elevations) where d > along {
            if e > last { total += e - last }
            last = e
        }
        return total
    }
}
