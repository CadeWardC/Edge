import SwiftUI

@main
struct EdgeApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(ModelStore.shared)
                .environmentObject(VoiceLibrary.shared)
                .environmentObject(PaperLibrary.shared)
                .environmentObject(PaperWorker.shared)
                .environmentObject(SpeechClips.shared)
                .environmentObject(Player.shared)
                .environmentObject(IncomingFiles.shared)
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        BackgroundKeepAlive.register()
        return true
    }

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

struct ContentView: View {
    @EnvironmentObject private var incoming: IncomingFiles

    var body: some View {
        TabView(selection: $incoming.tab) {
            PapersView()
                .withMiniPlayer()
                .tabItem { Label("Papers", systemImage: "doc.text.magnifyingglass") }
                .tag(IncomingFiles.Tab.papers)
            SpeakView()
                .withMiniPlayer()
                .tabItem { Label("Speak", systemImage: "text.bubble") }
                .tag(IncomingFiles.Tab.speak)
            VoicesView()
                .withMiniPlayer()
                .tabItem { Label("Voices", systemImage: "person.wave.2") }
                .tag(IncomingFiles.Tab.voices)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(IncomingFiles.Tab.settings)
        }
        .onOpenURL { incoming.handle($0) }
        .sheet(item: $incoming.voiceRecording) { item in
            AddVoiceView(initialURL: item.url)
        }
        .alert("Couldn't open the file", isPresented: Binding(get: { incoming.error != nil }, set: { if !$0 { incoming.error = nil } })) {
            Button("OK") { incoming.error = nil }
        } message: { Text(incoming.error ?? "") }
        .onAppear { KeyboardDismisser.shared.install() }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            // sheets can live in their own window
            KeyboardDismisser.shared.install()
        }
    }
}

extension View {
    /// Shows the mini player at the bottom of a tab while something is loaded.
    func withMiniPlayer() -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) { MiniPlayerInset() }
    }
}

private struct MiniPlayerInset: View {
    @EnvironmentObject private var player: Player

    var body: some View {
        if player.item != nil {
            MiniPlayer()
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
        }
    }
}

/// The current audio, shown above the tab bar.
struct MiniPlayer: View {
    @EnvironmentObject private var player: Player

    var body: some View {
        if let item = player.item {
            VStack(spacing: 6) {
                HStack(spacing: 12) {
                    Button { player.skip(-15) } label: { Image(systemName: "gobackward.15") }
                    Button { player.toggle() } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.title3)
                    }
                    Button { player.skip(15) } label: { Image(systemName: "goforward.15") }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text(item.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Menu {
                        ForEach(Player.speeds, id: \.self) { s in
                            Button {
                                player.speed = s
                            } label: {
                                if s == player.speed { Label(speedLabel(s), systemImage: "checkmark") } else { Text(speedLabel(s)) }
                            }
                        }
                    } label: {
                        Text(speedLabel(player.speed)).font(.caption.monospacedDigit().weight(.semibold))
                    }
                    Button { player.stop() } label: { Image(systemName: "xmark").font(.caption) }
                        .foregroundStyle(.secondary)
                }
                Slider(value: Binding(get: { player.position }, set: { player.seek(to: $0) }),
                       in: 0...max(player.duration, 1))
                    .controlSize(.mini)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
        }
    }

    private func speedLabel(_ s: Float) -> String {
        s == 1 ? "1×" : String(format: "%g×", s)
    }
}

func formatDuration(_ seconds: Double) -> String {
    let s = Int(seconds.rounded())
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
}
