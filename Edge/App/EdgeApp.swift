import SwiftUI

@main
struct EdgeApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var models = ModelStore.shared
    @StateObject private var tutor = TutorSession()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(models)
                .environmentObject(tutor)
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var models: ModelStore
    @EnvironmentObject private var tutor: TutorSession
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if models.isReady {
                ChatView()
                    .task(id: models.modelURL) { await loadIfNeeded() }
                    .task(id: models.chatModelURL) {
                        // a chat model downloaded later; at launch loadIfNeeded loads it after LFM3
                        if tutor.state != .notLoaded && tutor.state != .loading {
                            await tutor.loadChatModel(models.chatModelURL)
                        }
                    }
            } else {
                SetupView()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { models.refresh() }
        }
    }

    private func loadIfNeeded() async {
        guard let model = models.modelURL, let mmproj = models.mmprojURL else { return }
        if tutor.state == .notLoaded {
            await tutor.load(model: model, mmproj: mmproj)
            await tutor.loadChatModel(models.chatModelURL)
        } else if tutor.loadedModel != model, !tutor.state.isBusy, tutor.state != .listening {
            // a better backbone finished downloading
            await tutor.reload(model: model, mmproj: mmproj)
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    /// iOS relaunches the app when the model downloads finish in the background.
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == ModelStore.sessionIdentifier else {
            completionHandler()
            return
        }
        // touching the store reconnects to the background session, which then delivers its events
        ModelStore.shared.backgroundCompletionHandler = completionHandler
    }
}
