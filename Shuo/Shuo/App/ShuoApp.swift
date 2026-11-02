import SwiftUI

@main
struct ShuoApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ChatView()
                .environmentObject(Conversation.shared)
                .environmentObject(ModelStore.shared)
                .onAppear {
                    KeyboardDismisser.shared.install()
                    SpeechEngines.shared.warmUp()   // load the models before the first turn
                }
                .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                    KeyboardDismisser.shared.install()
                }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    /// iOS relaunches the app when a model download finishes in the background.
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == ModelStore.sessionIdentifier else {
            completionHandler()
            return
        }
        Task { @MainActor in
            ModelStore.shared.backgroundCompletionHandler = completionHandler
        }
    }
}
