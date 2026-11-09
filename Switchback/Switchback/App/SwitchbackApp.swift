import SwiftUI

@main
struct SwitchbackApp: App {
    @StateObject private var app = AppState.shared
    @StateObject private var library = Library.shared
    @StateObject private var recorder = Recorder.shared
    @StateObject private var offline = OfflineStore.shared
    @StateObject private var profiles = Profiles.shared
    @StateObject private var explore = ExploreModel()
    @StateObject private var highlights = Highlights.shared
    @StateObject private var trailPhotos = TrailPhotos.shared
    @AppStorage(Units.storageKey) private var units: Units = .systemDefault
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .id(units)   // redraw every number when the units change
                .environmentObject(app)
                .environmentObject(library)
                .environmentObject(recorder)
                .environmentObject(offline)
                .environmentObject(profiles)
                .environmentObject(explore)
                .environmentObject(highlights)
                .environmentObject(trailPhotos)
                .onOpenURL { url in app.importGPX(from: url) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { recorder.flush() }
        }
    }
}

enum AppTab: Hashable { case explore, record, saved, activity }

struct AppMessage: Identifiable {
    let id = UUID()
    let title: String
    let text: String
}

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var tab: AppTab = .explore
    @Published var message: AppMessage?

    func importGPX(from url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let trail = try GPX.trail(from: data, fallbackName: url.deletingPathExtension().lastPathComponent)
            Library.shared.save(trail)
            tab = .saved
            message = AppMessage(title: "Imported", text: "\(trail.name) (\(Fmt.distance(trail.length))) is in Saved.")
            if trail.profile == nil {
                Task { await Profiles.shared.ensureProfile(for: trail) }
            }
        } catch {
            message = AppMessage(title: "Couldn't import the GPX file", text: error.localizedDescription)
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var recorder: Recorder

    var body: some View {
        TabView(selection: $app.tab) {
            ExploreView()
                .tabItem { Label("Explore", systemImage: "map") }
                .tag(AppTab.explore)
            RecordView()
                .tabItem { Label("Record", systemImage: recorder.state == .idle ? "record.circle" : "record.circle.fill") }
                .tag(AppTab.record)
            SavedView()
                .tabItem { Label("Saved", systemImage: "bookmark") }
                .tag(AppTab.saved)
            ActivityListView()
                .tabItem { Label("Activity", systemImage: "figure.hiking") }
                .tag(AppTab.activity)
        }
        .tint(.trailGreen)
        .alert(item: $app.message) { m in
            Alert(title: Text(m.title), message: Text(m.text))
        }
    }
}
