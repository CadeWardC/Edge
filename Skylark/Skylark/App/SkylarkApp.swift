import SwiftUI

@main
struct SkylarkApp: App {
    @StateObject private var model = GameModel()

    var body: some Scene {
        WindowGroup {
            GameView()
                .environmentObject(model)
                .environmentObject(model.catalog)
        }
    }
}
