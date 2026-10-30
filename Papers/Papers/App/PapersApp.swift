import SwiftUI
import UserNotifications

@main
struct PapersApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var models = ModelStore.shared
    @ObservedObject private var library = Library.shared
    @ObservedObject private var queue = SummaryQueue.shared
    @ObservedObject private var player = SummaryPlayer.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(models)
                .environmentObject(library)
                .environmentObject(queue)
                .environmentObject(player)
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var models: ModelStore
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var queue: SummaryQueue
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if models.isReady {
                LibraryView()
            } else {
                SetupView()
            }
        }
        // "Open in Papers" from the share sheet or the Files app
        .onOpenURL { url in
            guard url.isFileURL else { return }
            if library.importPDF(from: url) != nil {
                queue.start()
            }
        }
        .onChange(of: models.isReady) { _, ready in
            if ready { queue.start() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { models.refresh() }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        BackgroundKeepAlive.register()
        UNUserNotificationCenter.current().delegate = self
        return true
    }

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

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([])
    }
}
