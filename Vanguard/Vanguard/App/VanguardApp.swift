import SpriteKit
import SwiftUI

@main
struct VanguardApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
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
                BackdropView(scene: app.makeBackdrop())
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .overlay(LinearGradient(colors: [Color.black.opacity(0.72), Color.black.opacity(app.screen == .menu ? 0.25 : 0.6),
                                                     Color.black.opacity(app.screen == .menu ? 0.5 : 0.7)],
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
        .animation(.easeInOut(duration: 0.22), value: app.screen)
        .onAppear {
            Sound.shared.start()
            // `-demo`: jump straight into a match the autopilot plays at 3x (screenshots on CI)
            let args = ProcessInfo.processInfo.arguments
            if let i = args.firstIndex(of: "-screen"), i + 1 < args.count {
                switch args[i + 1] {
                case "mission": app.start(Mission.all[0].setup(playerName: "Commander"), localPlayer: 0, mission: 0)
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
    static let background = LinearGradient(colors: [Color(red: 0.04, green: 0.06, blue: 0.10), Color(red: 0.08, green: 0.11, blue: 0.17)],
                                           startPoint: .top, endPoint: .bottom)
    static let panel = Color(red: 0.07, green: 0.09, blue: 0.13).opacity(0.9)
    static let panelTop = Color(red: 0.13, green: 0.16, blue: 0.22).opacity(0.92)
    static let accent = Color(red: 0.36, green: 0.78, blue: 1)
    static let accentDeep = Color(red: 0.13, green: 0.47, blue: 0.86)
    static let gold = Color(red: 1, green: 0.8, blue: 0.3)
    static let crystal = Color(red: 0.4, green: 0.9, blue: 1)
    static let edge = LinearGradient(colors: [Color.white.opacity(0.28), Color.white.opacity(0.05)], startPoint: .top, endPoint: .bottom)
}

/// The one panel look used everywhere: dark glass, lit top edge, soft shadow.
struct PanelStyle: ViewModifier {
    var radius: CGFloat = 12
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background(LinearGradient(colors: [Theme.panelTop, Theme.panel], startPoint: .top, endPoint: .bottom), in: shape)
            .overlay(shape.strokeBorder(Theme.edge, lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 6, y: 3)
    }
}

extension View {
    func panel(radius: CGFloat = 12) -> some View { modifier(PanelStyle(radius: radius)) }
}

/// Main call-to-action buttons (Start, Resume, Host).
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)
        configuration.label
            .font(.headline)
            .foregroundStyle(Color(red: 0.03, green: 0.08, blue: 0.16))
            .padding(.horizontal, 16).padding(.vertical, 9)
            .background(LinearGradient(colors: [Theme.accent, Theme.accentDeep], startPoint: .top, endPoint: .bottom), in: shape)
            .overlay(shape.strokeBorder(Color.white.opacity(0.45), lineWidth: 1))
            .shadow(color: Theme.accent.opacity(enabled ? 0.45 : 0), radius: 8)
            .saturation(enabled ? 1 : 0.1)
            .opacity(enabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Everything else (Back, Cancel, Join).
struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(configuration.role == .destructive ? Color(red: 1, green: 0.45, blue: 0.4) : Color.white)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .panel(radius: 10)
            .opacity(enabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Rows and tiles that are themselves the button: they dip and dim when pressed.
struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .brightness(configuration.isPressed ? 0.08 : 0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

struct ScreenTitle: View {
    var text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 26, weight: .heavy, design: .rounded)).tracking(3)
            .foregroundStyle(LinearGradient(colors: [.white, Theme.accent], startPoint: .top, endPoint: .bottom))
            .shadow(color: .black.opacity(0.6), radius: 4, y: 2)
    }
}

struct BigButton: View {
    var title: String
    var subtitle: String = ""
    var symbol: String
    var action: () -> Void

    var body: some View {
        Button {
            Sound.shared.play(.click)
            action()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.body.weight(.bold)).foregroundStyle(Theme.accent)
                    .frame(width: 36, height: 36)
                    .background(Theme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(.headline, design: .rounded))
                    if !subtitle.isEmpty {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: 360)
            .panel()
        }
        .buttonStyle(PressStyle())
    }
}

struct MenuView: View {
    @ObservedObject var app: AppModel

    var body: some View {
        HStack(spacing: 36) {
            VStack(alignment: .leading, spacing: 8) {
                Image(uiImage: Art.icon(.tank, .blue)).resizable().frame(width: 76, height: 76)
                    .shadow(color: Theme.accent.opacity(0.5), radius: 14)
                Text("VANGUARD")
                    .font(.system(size: 46, weight: .black, design: .rounded)).tracking(5)
                    .foregroundStyle(LinearGradient(colors: [.white, Theme.accent], startPoint: .top, endPoint: .bottom))
                    .shadow(color: .black.opacity(0.7), radius: 6, y: 3)
                Rectangle().fill(LinearGradient(colors: [Theme.accent, .clear], startPoint: .leading, endPoint: .trailing))
                    .frame(width: 260, height: 2)
                Text("Mine. Build. Hold the high ground.")
                    .font(.system(.callout, design: .rounded).weight(.medium)).foregroundStyle(.white.opacity(0.75))
            }
            VStack(spacing: 8) {
                BigButton(title: "Campaign", subtitle: "Eight missions against rising odds", symbol: "map.fill") {
                    app.screen = .campaign
                }
                BigButton(title: "Quick Battle", subtitle: "1v1 against a Normal bot", symbol: "bolt.fill") {
                    app.start(SkirmishView.quickSetup(), localPlayer: 0)
                }
                BigButton(title: "Skirmish", subtitle: "Choose the map, bots and teams", symbol: "flag.2.crossed.fill") {
                    app.screen = .skirmish
                }
                BigButton(title: "Multiplayer", subtitle: "Play friends through a relay", symbol: "person.2.wave.2.fill") {
                    app.screen = .multiplayer
                }
                HStack(spacing: 8) {
                    SmallButton(title: "How to Play", symbol: "book.fill") { app.screen = .howTo }
                    SmallButton(title: "Settings", symbol: "gearshape.fill") { app.screen = .settings }
                }
                .frame(maxWidth: 360)
            }
        }
        .padding(24)
    }
}

/// The bot battle behind the menus; fades in once it is drawn and under way.
struct BackdropView: View {
    let scene: GameScene
    @ObservedObject private var game: GameController

    init(scene: GameScene) {
        self.scene = scene
        game = scene.controller
    }

    var body: some View {
        // the scene has to stay visible to keep running, so a cover fades away instead
        SpriteViewRep(scene: scene)
            .overlay(Color(red: 0.04, green: 0.06, blue: 0.10).opacity(game.sceneReady ? 0 : 1))
            .animation(.easeIn(duration: 0.8), value: game.sceneReady)
    }
}

struct SmallButton: View {
    var title: String
    var symbol: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol).font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity).padding(.vertical, 9).panel()
        }
        .buttonStyle(PressStyle())
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
