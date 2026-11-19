import SwiftUI

@main
struct PipApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(PhotoLibrary.shared)
                .environmentObject(PipEngine.shared)
        }
    }
}
