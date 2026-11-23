import SwiftUI

@main
struct SkylarkApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(model.catalog)
                .environmentObject(model.simulator)
        }
    }
}
