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
    // watched so that picking LFM3-Audio for anything loads it, and picking it for nothing frees it
    @AppStorage("asrEngine") private var asrEngine = "sensevoice"
    @AppStorage("replyEngine") private var replyEngine = "qwen"
    @AppStorage("ttsEngine") private var ttsEngine = "kokoro"

    var body: some View {
        Group {
            if models.isReady {
                ChatView()
                    .task(id: plan) { await tutor.apply(plan) }
            } else {
                SetupView()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { models.refresh() }
        }
    }

    /// LFM3-Audio is loaded only when it is picked for something, or the other models aren't all there.
    private var plan: TutorSession.LoadPlan {
        let lfmChosen = asrEngine == "lfm" || replyEngine == "lfm" || ttsEngine == "lfm"
        let lfmWanted = models.lfmReady && (lfmChosen || !models.lightReady)
        return .init(lfmModel: lfmWanted ? models.modelURL : nil,
                     lfmMMProj: lfmWanted ? models.mmprojURL : nil,
                     chatModel: models.chatModelURL)
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
