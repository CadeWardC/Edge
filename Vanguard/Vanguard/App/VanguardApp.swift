import SpriteKit
import SwiftUI

@main
struct VanguardApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.dark)
                .statusBarHidden()
                .persistentSystemOverlays(.hidden)
        }
    }
}

enum Screen {
    case menu, skirmish, multiplayer, howTo, game
}

final class AppModel: ObservableObject {
    @Published var screen: Screen = .menu
    @Published var game: GameController?
    private(set) var scene: GameScene?

    func start(_ setup: MatchSetup, localPlayer: Int, transport: NetTransport? = nil, autopilot: Bool = false) {
        let g = GameController(setup: setup, localPlayer: localPlayer, transport: transport, autopilot: autopilot)
        scene = GameScene(controller: g)
        game = g
        screen = .game
    }

    func leaveGame() {
        game?.quit()
        game = nil
        scene = nil
        screen = .menu
    }
}

struct RootView: View {
    @StateObject private var app = AppModel()

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            switch app.screen {
            case .menu: MenuView(app: app)
            case .skirmish: SkirmishView(app: app)
            case .multiplayer: MultiplayerView(app: app)
            case .howTo: HowToPlayView { app.screen = .menu }
            case .game:
                if let g = app.game, let s = app.scene {
                    GameView(game: g, scene: s) { app.leaveGame() }
                }
            }
        }
        .onAppear {
            // `-demo`: jump straight into a match the autopilot plays at 3x (screenshots on CI)
            let args = ProcessInfo.processInfo.arguments
            if args.contains("-demo"), app.game == nil {
                var setup = SkirmishView.quickSetup()
                setup.seed = 11
                if let i = args.firstIndex(of: "-demo-map"), i + 1 < args.count, let raw = Int(args[i + 1]), let m = MapID(rawValue: raw) {
                    setup.map = m
                }
                setup.players[1].difficulty = .hard
                app.start(setup, localPlayer: 0, autopilot: true)
                app.game?.speed = 3
            }
        }
    }
}

enum Theme {
    static let background = LinearGradient(colors: [Color(red: 0.05, green: 0.07, blue: 0.11), Color(red: 0.09, green: 0.12, blue: 0.18)],
                                           startPoint: .top, endPoint: .bottom)
    static let panel = Color(red: 0.08, green: 0.1, blue: 0.14).opacity(0.88)
    static let accent = Color(red: 0.35, green: 0.75, blue: 1)
    static let gold = Color(red: 1, green: 0.8, blue: 0.3)
    static let crystal = Color(red: 0.4, green: 0.9, blue: 1)
}

struct PanelStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.white.opacity(0.12), lineWidth: 1))
    }
}

extension View {
    func panel() -> some View { modifier(PanelStyle()) }
}

struct BigButton: View {
    var title: String
    var subtitle: String = ""
    var symbol: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: symbol).font(.title2).frame(width: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    if !subtitle.isEmpty { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: 380)
            .panel()
        }
        .buttonStyle(.plain)
    }
}

struct MenuView: View {
    @ObservedObject var app: AppModel

    var body: some View {
        HStack(spacing: 40) {
            VStack(alignment: .leading, spacing: 10) {
                Image(uiImage: Art.icon(.tank, .blue)).resizable().frame(width: 90, height: 90)
                Text("VANGUARD").font(.system(size: 48, weight: .black, design: .rounded)).tracking(4)
                Text("Real-time strategy. Mine crystals, build an army, hold the beacons, crush the enemy base.")
                    .font(.callout).foregroundStyle(.secondary).frame(maxWidth: 320, alignment: .leading)
            }
            VStack(spacing: 12) {
                BigButton(title: "Quick Battle", subtitle: "1v1 against a Normal bot on Crossroads", symbol: "bolt.fill") {
                    app.start(SkirmishView.quickSetup(), localPlayer: 0)
                }
                BigButton(title: "Skirmish", subtitle: "Pick a map, bots, difficulty and teams", symbol: "flag.2.crossed.fill") {
                    app.screen = .skirmish
                }
                BigButton(title: "Multiplayer", subtitle: "Play friends through a relay server", symbol: "person.2.wave.2.fill") {
                    app.screen = .multiplayer
                }
                BigButton(title: "How to Play", subtitle: "Controls, units and counters", symbol: "book.fill") {
                    app.screen = .howTo
                }
            }
        }
        .padding(30)
    }
}

struct SpriteViewRep: UIViewRepresentable {
    let scene: SKScene

    func makeUIView(context: Context) -> SKView {
        let v = SKView()
        v.preferredFramesPerSecond = 60
        v.ignoresSiblingOrder = true
        v.presentScene(scene)
        return v
    }

    func updateUIView(_ v: SKView, context: Context) {
        if v.scene !== scene { v.presentScene(scene) }
    }
}
