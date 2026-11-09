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
    case menu, campaign, skirmish, multiplayer, howTo, settings, game
}

final class AppModel: ObservableObject {
    @Published var screen: Screen = .menu
    @Published var game: GameController?
    private(set) var scene: GameScene?

    /// A bot battle playing behind the menus.
    private(set) var backdrop: GameScene?

    func start(_ setup: MatchSetup, localPlayer: Int, transport: NetTransport? = nil, autopilot: Bool = false, mission: Int? = nil) {
        backdrop = nil
        let g = GameController(setup: setup, localPlayer: localPlayer, transport: transport, autopilot: autopilot)
        g.missionId = mission
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

    func makeBackdrop() -> GameScene {
        if let b = backdrop, !(b.controller.world.isOver) { return b }
        let maps: [MapID] = [.highlands, .caldera, .frontier]
        let map = maps[Int.random(in: 0..<maps.count)]
        let colors: [TeamColor] = [.blue, .red, .gold, .purple]
        let styles: [Personality] = [.balanced, .rusher, .mechanic, .turtle]
        let players = (0..<4).map { i in
            PlayerSetup(name: "Bot \(i + 1)", team: map.defaultTeam(slot: i), color: colors[i], isBot: true, difficulty: .hard, personality: styles[i])
        }
        let g = GameController(setup: MatchSetup(map: map, seed: UInt64.random(in: 1...999_999), players: players), localPlayer: -1)
        g.isBackdrop = true
        g.speed = 1.5
        // start a couple of minutes in, when armies are on the field
        for _ in 0..<(150 * Defs.tickRate) { g.session.stepTick() }
        g.world.events.removeAll()
        let sc = GameScene(controller: g)
        backdrop = sc
        return sc
    }
}

struct RootView: View {
    @StateObject private var app = AppModel()

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            if app.screen != .game {
                SpriteViewRep(scene: app.makeBackdrop())
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .overlay(LinearGradient(colors: [Color.black.opacity(0.75), Color.black.opacity(0.45), Color.black.opacity(0.75)],
                                            startPoint: .leading, endPoint: .trailing).ignoresSafeArea())
            }
            switch app.screen {
            case .menu: MenuView(app: app)
            case .campaign: CampaignView(app: app)
            case .settings: SettingsView { app.screen = .menu }
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
            Sound.shared.start()
            // `-demo`: jump straight into a match the autopilot plays at 3x (screenshots on CI)
            let args = ProcessInfo.processInfo.arguments
            if let i = args.firstIndex(of: "-screen"), i + 1 < args.count {
                switch args[i + 1] {
                case "campaign": app.screen = .campaign
                case "skirmish": app.screen = .skirmish
                case "settings": app.screen = .settings
                default: break
                }
            }
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
            VStack(spacing: 9) {
                BigButton(title: "Campaign", subtitle: "Eight missions, from first contact to a Brutal commander", symbol: "map.fill") {
                    app.screen = .campaign
                }
                BigButton(title: "Quick Battle", subtitle: "1v1 against a Normal bot on Crossroads", symbol: "bolt.fill") {
                    app.start(SkirmishView.quickSetup(), localPlayer: 0)
                }
                BigButton(title: "Skirmish", subtitle: "Pick a map, bots, difficulty and teams", symbol: "flag.2.crossed.fill") {
                    app.screen = .skirmish
                }
                BigButton(title: "Multiplayer", subtitle: "Play friends through a relay server", symbol: "person.2.wave.2.fill") {
                    app.screen = .multiplayer
                }
                HStack(spacing: 10) {
                    SmallButton(title: "How to Play", symbol: "book.fill") { app.screen = .howTo }
                    SmallButton(title: "Settings", symbol: "gearshape.fill") { app.screen = .settings }
                }
                .frame(maxWidth: 380)
            }
        }
        .padding(30)
    }
}

struct SmallButton: View {
    var title: String
    var symbol: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol).font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity).padding(.vertical, 11).panel()
        }
        .buttonStyle(.plain)
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
