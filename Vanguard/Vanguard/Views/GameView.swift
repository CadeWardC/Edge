import Charts
import SpriteKit
import SwiftUI

struct GameView: View {
    @ObservedObject var game: GameController
    let scene: GameScene
    var onExit: () -> Void
    @State private var hint: String?

    var body: some View {
        ZStack {
            SpriteViewRep(scene: scene).ignoresSafeArea()
            hudLayer
            if game.placing != nil { placementBar }
            if game.hud.waiting && !game.showMenu {
                Text("Waiting for other players…").font(.headline).padding(12).panel()
            }
            if game.showMenu { pauseMenu }
            if let r = game.result { resultView(r) }
            if !game.sceneReady { loadingCard.transition(.opacity) }
        }
        .animation(.easeOut(duration: 0.6), value: game.sceneReady)
    }

    /// Covers the screen while the battlefield is drawn, then fades into the match.
    private var loadingCard: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 10) {
                Text(game.world.map.id.name.uppercased())
                    .font(.system(size: 38, weight: .black, design: .rounded)).tracking(6)
                    .foregroundStyle(LinearGradient(colors: [.white, Theme.accent], startPoint: .top, endPoint: .bottom))
                Rectangle().fill(LinearGradient(colors: [.clear, Theme.accent, .clear], startPoint: .leading, endPoint: .trailing))
                    .frame(width: 280, height: 2)
                Text(game.localPlayer >= 0 ? "Destroy every enemy building" : "Spectating")
                    .font(.system(.callout, design: .rounded).weight(.medium)).foregroundStyle(.white.opacity(0.7))
                ProgressView().tint(Theme.accent).padding(.top, 8)
            }
        }
    }

    // MARK: HUD

    private var hudLayer: some View {
        ZStack {
            // top: resources, messages, menu
            VStack(spacing: 6) {
                topBar
                if let t = game.toast {
                    Text(t).font(.callout.weight(.semibold)).padding(.horizontal, 12).padding(.vertical, 6).panel()
                        .transition(.opacity)
                        .onTapGesture { game.jumpToAlert() }
                }
                if let c = game.coachText, game.toast == nil {
                    Label(c, systemImage: "lightbulb.fill")
                        .font(.caption.weight(.medium)).foregroundStyle(Theme.gold)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(8).frame(maxWidth: 360).panel()
                }
                if let h = hint {
                    Text(h).font(.caption).padding(8).frame(maxWidth: 320).panel()
                }
                Spacer()
            }
            VStack {
                HStack {
                    Spacer()
                    VStack(spacing: 6) {
                        Button { game.showMenu = true } label: {
                            Image(systemName: "pause.fill").font(.title3).frame(width: 44, height: 40).panel()
                        }
                        .buttonStyle(PressStyle())
                        ForEach(game.hud.powers) { p in powerButton(p) }
                    }
                }
                Spacer()
            }
            // left: army, idle drones, control groups
            VStack {
                HStack {
                    leftButtons
                    Spacer()
                }
                Spacer()
            }
            // bottom: minimap, selection, commands
            VStack {
                Spacer()
                HStack(alignment: .bottom, spacing: 10) {
                    MinimapView(game: game, scene: scene).frame(width: 128, height: 128)
                    selectionPanel
                    Spacer(minLength: 0)
                    commandCard
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .animation(.easeOut(duration: 0.15), value: game.toast)
    }

    private func powerButton(_ p: PowerState) -> some View {
        let armed = game.powerArmed == p.kind
        return Button {
            if p.ready {
                Sound.shared.play(.click)
                game.armPower(p.kind)
            } else {
                Sound.shared.play(.error)
                hint = "\(p.kind.name) (\(p.kind.cost) crystals): \(p.kind.blurb)"
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { hint = nil }
            }
        } label: {
            ZStack {
                Image(systemName: p.kind == .strike ? "bolt.fill" : "eye.fill")
                    .font(.body.weight(.bold))
                    .foregroundStyle(p.kind == .strike ? Color.orange : Theme.accent)
                    .opacity(p.ready ? 1 : 0.3)
                if p.unlocked && p.wait > 0 {
                    Text("\(p.wait)").font(.caption.bold().monospacedDigit())
                } else if !p.unlocked {
                    Image(systemName: "lock.fill").font(.caption2).offset(x: 12, y: 10).opacity(0.7)
                }
            }
            .frame(width: 44, height: 40)
            .background(armed ? Theme.accent.opacity(0.4) : Theme.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(armed ? Theme.accent : Color.white.opacity(0.12), lineWidth: armed ? 2 : 1))
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel(p.kind.name)
    }

    private var topBar: some View {
        HStack(spacing: 16) {
            if game.localPlayer >= 0 {
                Label("\(game.hud.crystals)", systemImage: "diamond.fill").foregroundStyle(Theme.crystal)
                Label("\(game.hud.supplyUsed)/\(game.hud.supplyCap)", systemImage: "bolt.fill")
                    .foregroundStyle(game.hud.supplyUsed >= game.hud.supplyCap ? .red : Theme.gold)
                Label("\(game.hud.beacons)", systemImage: "dot.radiowaves.left.and.right").foregroundStyle(.white.opacity(0.85))
            } else {
                ForEach(game.hud.players) { p in
                    HStack(spacing: 4) {
                        Circle().fill(Color(Art.color(p.color))).frame(width: 10, height: 10)
                        Text(p.defeated ? "\(p.name) ✕" : "\(p.name) \(p.army)").strikethrough(p.defeated)
                    }
                }
            }
            Text(game.hud.time).monospacedDigit().foregroundStyle(.secondary)
            if !game.isMultiplayer && game.speed != 1 {
                Text("×\(game.speed, specifier: "%.1f")").foregroundStyle(.orange)
            }
        }
        .font(.callout.weight(.semibold).monospacedDigit())
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .panel()
    }

    private var leftButtons: some View {
        VStack(spacing: 6) {
            if game.localPlayer >= 0 {
                SideButton(symbol: "figure.walk", label: "Army", badge: game.hud.armyCount) { game.selectArmy() }
                SideButton(symbol: "hammer", label: "Idle", badge: game.hud.idleWorkers, alert: game.hud.idleWorkers > 0) { game.selectIdleWorker() }
                ForEach(0..<3, id: \.self) { i in
                    SideButton(symbol: "\(i + 1).square", label: "Group \(i + 1). Hold to save the selection", badge: game.groups[i].count) {
                        game.group(i, assign: false)
                    }
                    .simultaneousGesture(LongPressGesture(minimumDuration: 0.45).onEnded { _ in game.group(i, assign: true) })
                }
            }
        }
    }

    @ViewBuilder private var selectionPanel: some View {
        if !game.hud.selection.isEmpty {
            selectionContent
                .overlay(alignment: .topTrailing) {
                    Button { game.select([]) } label: {
                        Image(systemName: "xmark.circle.fill").font(.body).foregroundStyle(.white.opacity(0.7))
                    }
                    .buttonStyle(PressStyle())
                    .offset(x: 6, y: -6)
                }
        }
    }

    @ViewBuilder private var selectionContent: some View {
        if let e = game.hud.single {
            HStack(alignment: .top, spacing: 10) {
                Image(uiImage: Art.icon(e.type, e.owner >= 0 ? game.world.players[e.owner].color : .blue))
                    .resizable().frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text(e.st.name).font(.headline)
                    if !game.hud.singleHP.isEmpty { Text(game.hud.singleHP).font(.caption.monospacedDigit()) }
                    if !game.hud.singleInfo.isEmpty {
                        Text(game.hud.singleInfo).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                    }
                    if !game.hud.queue.isEmpty {
                        HStack(spacing: 4) {
                            ForEach(game.hud.queue) { q in queueIcon(q) }
                        }
                    }
                }
            }
            .padding(8)
            .frame(maxWidth: 300, alignment: .leading)
            .panel()
        } else if !game.hud.selection.isEmpty {
            let groups = game.hud.selection
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(44), spacing: 4), count: min(6, max(1, groups.count))), spacing: 4) {
                ForEach(groups) { g in
                    Button { game.select(type: g.type) } label: {
                        ZStack(alignment: .bottomTrailing) {
                            Image(uiImage: Art.icon(g.type, game.me?.color ?? .blue)).resizable().frame(width: 40, height: 40)
                            if g.ids.count > 1 {
                                Text("\(g.ids.count)").font(.caption2.bold()).padding(2).background(.black.opacity(0.6), in: Capsule())
                            }
                        }
                    }
                    .buttonStyle(PressStyle())
                }
            }
            .padding(8)
            .panel()
        }
    }

    private func queueIcon(_ q: QueueSlot) -> some View {
        let img: UIImage
        switch q.item {
        case let .unit(t): img = Art.icon(t, game.me?.color ?? .blue)
        case let .research(u): img = Art.upgradeIcon(u)
        case let .spec(sp): img = Art.specIcon(sp)
        }
        return ZStack(alignment: .bottom) {
            Image(uiImage: img).resizable().frame(width: 28, height: 28).opacity(q.id == 0 ? 1 : 0.6)
            if q.id == 0 {
                GeometryReader { geo in
                    Rectangle().fill(Theme.accent).frame(width: geo.size.width * q.progress, height: 3)
                }
                .frame(width: 28, height: 3)
            }
        }
    }

    private var commandCard: some View {
        let buttons = game.hud.buttons
        return LazyVGrid(columns: Array(repeating: GridItem(.fixed(62), spacing: 5), count: 3), spacing: 5) {
            ForEach(buttons) { b in
                CommandTile(button: b, me: game.me) { hint = $0 }
            }
        }
        .padding(buttons.isEmpty ? 0 : 6)
        .background(buttons.isEmpty ? Color.clear : Theme.panel, in: RoundedRectangle(cornerRadius: 12))
    }

    private var placementBar: some View {
        VStack {
            Spacer()
            HStack(spacing: 14) {
                Text("Tap the map to place the \(game.placing?.stats.name ?? "")").font(.callout)
                Button { game.confirmPlacement() } label: {
                    Label("Build", systemImage: "checkmark").padding(.horizontal, 6)
                }
                .buttonStyle(PrimaryButtonStyle())
                .tint(.green)
                .disabled(!game.placementValid)
                Button(role: .cancel) { game.cancelPlacement() } label: { Label("Cancel", systemImage: "xmark") }
                    .buttonStyle(SecondaryButtonStyle())
            }
            .padding(10)
            .panel()
            .padding(.bottom, 150)
        }
    }

    private var pauseMenu: some View {
        ZStack {
            Color.black.opacity(0.5).ignoresSafeArea()
            VStack(spacing: 12) {
                Text(game.isMultiplayer ? "Menu" : "Paused").font(.title.bold())
                if !game.isMultiplayer {
                    Picker("Speed", selection: $game.speed) {
                        Text("Slow").tag(0.75)
                        Text("Normal").tag(1.0)
                        Text("Fast").tag(1.4)
                        Text("Faster").tag(2.0)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 320)
                }
                Button { game.showMenu = false } label: { Text("Resume").frame(width: 220) }
                    .buttonStyle(PrimaryButtonStyle())
                Button(role: .destructive) { onExit() } label: {
                    Text(game.localPlayer >= 0 && game.result == nil ? "Surrender and quit" : "Quit").frame(width: 220)
                }
                .buttonStyle(SecondaryButtonStyle())
                Text("Drag to scroll · pinch to zoom · press and hold, then drag, to box-select · tap a unit twice to select all of that type on screen")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(width: 380)
            }
            .padding(24)
            .panel()
        }
    }

    private func resultView(_ r: MatchResult) -> some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(r.title).font(.system(size: 40, weight: .black, design: .rounded))
                        .foregroundStyle(r.won ? Theme.gold : .red)
                    ForEach(r.lines, id: \.self) { Text($0).font(.caption) }
                    Spacer(minLength: 4)
                    Button { onExit() } label: { Text("Back to menu").frame(width: 200) }
                        .buttonStyle(PrimaryButtonStyle())
                }
                .frame(maxWidth: 320, alignment: .leading)
                ResultCharts(game: game)
                    .frame(maxWidth: 380)
            }
            .padding(22)
            .panel()
            .padding(20)
        }
    }
}

/// Army value and crystals mined over the match, one line per player.
struct ResultCharts: View {
    let game: GameController
    @State private var showArmy = true

    var body: some View {
        let names = game.world.players.map { $0.name }
        let colors = game.world.players.map { Color(Art.color($0.color)) }
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: $showArmy) {
                Text("Army value").tag(true)
                Text("Crystals mined").tag(false)
            }
            .pickerStyle(.segmented)
            Chart(game.samples) { s in
                LineMark(x: .value("Minute", s.minute), y: .value(showArmy ? "Army" : "Mined", showArmy ? s.army : s.mined))
                    .foregroundStyle(by: .value("Player", s.player))
                    .interpolationMethod(.monotone)
            }
            .chartForegroundStyleScale(domain: names, range: colors)
            .chartXAxisLabel("minutes")
            .frame(height: 190)
        }
    }
}

struct SideButton: View {
    var symbol: String
    var label: String
    var badge: Int
    var alert = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: symbol).font(.body.weight(.semibold)).frame(width: 42, height: 36).panel()
                if badge > 0 {
                    Text("\(badge)").font(.caption2.bold()).padding(.horizontal, 4).padding(.vertical, 1)
                        .background(alert ? Color.orange : Theme.accent.opacity(0.85), in: Capsule())
                        .offset(x: 6, y: -5)
                }
            }
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel(label)
    }
}

struct CommandTile: View {
    let button: CommandButton
    let me: Player?
    var showHint: (String?) -> Void

    var body: some View {
        Button {
            Sound.shared.play(button.enabled ? .click : .error)
            if button.enabled { button.run() } else { showHint(button.hint) }
        } label: {
            VStack(spacing: 2) {
                icon.frame(width: 34, height: 34)
                Text(button.title).font(.system(size: 9, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.7)
                if let c = button.cost {
                    Text("\(c)").font(.system(size: 9, weight: .bold).monospacedDigit())
                        .foregroundStyle((me?.crystals ?? 0) >= c ? Theme.crystal : .red)
                }
            }
            .frame(width: 62, height: 62)
            .background(button.highlighted ? Theme.accent.opacity(0.35) : Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(button.highlighted ? Theme.accent : Color.white.opacity(0.12)))
            .opacity(button.enabled ? 1 : 0.42)
        }
        .buttonStyle(PressStyle())
        .simultaneousGesture(LongPressGesture(minimumDuration: 0.4).onEnded { _ in
            showHint(button.hint)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { showHint(nil) }
        })
    }

    @ViewBuilder private var icon: some View {
        switch button.icon {
        case let .entity(t): Image(uiImage: Art.icon(t, me?.color ?? .blue)).resizable().scaledToFit()
        case let .upgrade(u): Image(uiImage: Art.upgradeIcon(u)).resizable().scaledToFit()
        case let .spec(sp): Image(uiImage: Art.specIcon(sp)).resizable().scaledToFit()
        case let .symbol(s): Image(systemName: s).font(.title3)
        }
    }
}

struct MinimapView: View {
    @ObservedObject var game: GameController
    let scene: GameScene

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                Image(uiImage: game.minimapImage).interpolation(.none).resizable()
                Canvas { ctx, sz in
                    for d in game.minimapDots {
                        let r = CGRect(x: d.x * sz.width - d.size / 2, y: d.y * sz.height - d.size / 2, width: d.size, height: d.size)
                        ctx.fill(d.square ? Path(r) : Path(ellipseIn: r), with: .color(d.color))
                    }
                    let c = game.cameraRect
                    let cr = CGRect(x: c.minX * sz.width, y: c.minY * sz.height, width: c.width * sz.width, height: c.height * sz.height)
                    ctx.stroke(Path(cr), with: .color(.white.opacity(0.9)), lineWidth: 1)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                scene.jump(toFraction: Double(v.location.x / size.width), Double(v.location.y / size.height))
            })
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.25)))
    }
}
