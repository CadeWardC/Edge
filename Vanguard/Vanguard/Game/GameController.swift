import Combine
import SwiftUI
import UIKit

struct SelectionGroup: Identifiable {
    var type: EntityType
    var ids: [Int]
    var id: Int { type.rawValue }
}

struct QueueSlot: Identifiable {
    var id: Int
    var item: ProdItem
    var progress: Double
}

struct CommandButton: Identifiable {
    enum Icon {
        case entity(EntityType)
        case upgrade(Upgrade)
        case symbol(String)
    }
    var id: String
    var title: String
    var icon: Icon
    var cost: Int?
    var enabled: Bool
    var highlighted = false
    var hint: String
    var run: () -> Void
}

struct PlayerLine: Identifiable {
    var id: Int
    var name: String
    var color: TeamColor
    var crystals: Int
    var supply: String
    var army: Int
    var defeated: Bool
}

struct HUDState {
    var crystals = 0
    var supplyUsed = 0
    var supplyCap = 0
    var beacons = 0
    var time = "0:00"
    var selection: [SelectionGroup] = []
    var single: Entity?
    var singleHP = ""
    var singleInfo = ""
    var queue: [QueueSlot] = []
    var buttons: [CommandButton] = []
    var idleWorkers = 0
    var armyCount = 0
    var waiting = false
    var players: [PlayerLine] = []
}

struct MatchResult {
    var won: Bool
    var title: String
    var lines: [String]
}

/// Owns a running match: the lockstep session, the selection and the HUD. The SpriteKit scene draws the world and
/// forwards touches here; the SwiftUI HUD reads `hud` and calls the command buttons.
final class GameController: ObservableObject {
    let world: World
    let session: LockstepSession
    let localPlayer: Int            // -1 = watching bots
    let localTeam: Int
    let isMultiplayer: Bool
    let transport: NetTransport?

    @Published var hud = HUDState()
    @Published var buildMenu = false
    @Published var placing: EntityType?
    @Published var placeOrigin: TilePoint?
    @Published var attackArmed = false
    @Published var showMenu = false
    @Published var toast: String?
    @Published var result: MatchResult?
    @Published var minimapDots: [MinimapDot] = []
    @Published var cameraRect = CGRect.zero
    @Published var speed: Double = 1 { didSet { session.speed = speed } }

    private(set) var selection: [Int] = []
    var groups: [[Int]] = [[], [], []]
    weak var scene: GameScene?
    private var hudTimer: Double = 0
    private var miniTimer: Double = 0
    private var lastTapId = 0
    private var lastTapTime: TimeInterval = 0
    private var toastWork: DispatchWorkItem?
    let minimapImage: UIImage

    init(setup: MatchSetup, localPlayer: Int, transport: NetTransport? = nil) {
        let w = World(setup: setup)
        world = w
        self.localPlayer = localPlayer
        localTeam = localPlayer >= 0 ? w.players[localPlayer].team : -1
        self.transport = transport
        isMultiplayer = transport != nil
        let humans = setup.players.indices.filter { !setup.players[$0].isBot }
        session = LockstepSession(world: w, humans: humans, local: localPlayer >= 0 ? [localPlayer] : [], transport: transport)
        minimapImage = Art.minimap(w.map)
        session.onDesync = { [weak self] turn in
            self?.showToast("Out of sync with the other players (turn \(turn)).")
        }
        session.onPeerLeft = { [weak self] _ in
            self?.showToast("A player left the game.")
        }
        refreshHUD()
    }

    var me: Player? { localPlayer >= 0 ? world.players[localPlayer] : nil }

    // MARK: frame

    func frame(_ dt: Double) {
        if !showMenu || isMultiplayer { session.update(realDt: dt) }
        handleEvents()
        hudTimer += dt
        miniTimer += dt
        if hudTimer > 0.12 { hudTimer = 0; refreshHUD() }
        if miniTimer > 0.25 { miniTimer = 0; refreshMinimap() }
        if world.isOver && result == nil { finish() }
    }

    private func handleEvents() {
        guard !world.events.isEmpty else { return }
        let evs = world.events
        world.events.removeAll(keepingCapacity: true)
        scene?.play(evs)
        for e in evs {
            switch e {
            case let .underAttack(p, at) where p == localPlayer:
                showToast("We're under attack!")
                scene?.ping(at)
            case let .notEnough(p, what) where p == localPlayer:
                showToast("Not enough \(what).")
            case let .researched(p, u) where p == localPlayer:
                showToast("\(u.info.name) complete.")
            case let .completed(b) where b.owner == localPlayer:
                showToast("\(b.st.name) complete.")
            case let .captured(_, team) where localTeam >= 0:
                showToast(team == localTeam ? "Beacon captured." : "We lost a beacon.")
            case let .defeated(p):
                if p == localPlayer { showToast("You have been defeated.") } else { showToast("\(world.players[p].name) was eliminated.") }
            default:
                break
            }
        }
        selection.removeAll { world.entity($0) == nil }
    }

    func showToast(_ s: String) {
        toast = s
        toastWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.toast = nil }
        toastWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6, execute: w)
    }

    private func finish() {
        var lines: [String] = []
        for p in world.players {
            lines.append("\(p.name): mined \(p.gathered), built \(p.unitsMade) units, \(p.kills) kills, lost \(p.unitsLost)")
        }
        let minutes = world.tick / (60 * Defs.tickRate), secs = (world.tick / Defs.tickRate) % 60
        lines.append(String(format: "Match length %d:%02d", minutes, secs))
        if localTeam < 0 {
            let names = world.players.filter { $0.team == world.winningTeam }.map { $0.name }.joined(separator: " & ")
            result = MatchResult(won: true, title: names.isEmpty ? "Draw" : "\(names) win", lines: lines)
        } else {
            let won = world.winningTeam == localTeam
            result = MatchResult(won: won, title: won ? "Victory" : "Defeat", lines: lines)
        }
        transport?.close()
    }

    func quit() {
        if let me, !me.defeated, !world.isOver { issue(.surrender, units: []) }
        transport?.send(.leave(clientId: ""))
        transport?.close()
    }

    // MARK: commands

    func issue(_ a: Action, units: [Int]) {
        guard localPlayer >= 0 else { return }
        session.issue(Command(player: localPlayer, units: units, action: a))
    }

    private var mySelected: [Entity] { selection.compactMap { world.entity($0) }.filter { $0.owner == localPlayer } }

    func select(_ ids: [Int]) {
        selection = ids
        buildMenu = false
        placing = nil
        attackArmed = false
        refreshHUD()
    }

    func select(type: EntityType) {
        select(selection.compactMap { world.entity($0) }.filter { $0.type == type }.map { $0.id })
    }

    func selectArmy() {
        select(world.entities.filter { $0.owner == localPlayer && $0.isArmy }.map { $0.id })
        if let c = centroid(selection) { scene?.focus(c) }
    }

    func selectIdleWorker() {
        let idle = world.entities.filter { $0.owner == localPlayer && $0.isWorker && $0.order == .idle }
        guard !idle.isEmpty else { return }
        let current = selection.count == 1 ? selection[0] : 0
        let next = idle.first { $0.id > current } ?? idle[0]
        select([next.id])
        scene?.focus(next.pos)
    }

    func group(_ i: Int, assign: Bool) {
        if assign {
            groups[i] = selection
            showToast("Group \(i + 1) set (\(selection.count)).")
        } else {
            let ids = groups[i].filter { world.entity($0) != nil }
            groups[i] = ids
            guard !ids.isEmpty else { return }
            if selection == ids, let c = centroid(ids) { scene?.focus(c) }
            select(ids)
        }
    }

    private func centroid(_ ids: [Int]) -> Vec2? {
        let es = ids.compactMap { world.entity($0) }
        guard !es.isEmpty else { return nil }
        var c = Vec2.zero
        for e in es { c += e.pos }
        return c / Double(es.count)
    }

    // MARK: touch input (world coordinates)

    func entityAt(_ p: Vec2) -> Entity? {
        var best: Entity?
        var bestD = Double.infinity
        for e in world.entities where e.alive {
            if e.owner != localPlayer && !e.type.isNeutral && localTeam >= 0 && !world.fog.visible(team: localTeam, e.pos) { continue }
            if e.type == .beacon { continue }
            let reach = e.st.radius + (e.isUnit ? 16 : 4)
            let d = e.pos.dist(p)
            if d < reach {
                let score = d - (e.isUnit ? 30 : 0)
                if score < bestD { bestD = score; best = e }
            }
        }
        return best
    }

    func tap(_ p: Vec2) {
        if let t = placing {
            let n = t.stats.footprint
            placeOrigin = TilePoint(x: Int((p.x / Defs.tile - Double(n) / 2).rounded()), y: Int((p.y / Defs.tile - Double(n) / 2).rounded()))
            return
        }
        let hit = entityAt(p)
        let mine = mySelected
        if attackArmed {
            attackArmed = false
            if let h = hit, h.owner >= 0, world.enemies(localTeam, h.team) {
                issue(.attack(h.id), units: mine.map { $0.id })
            } else {
                issue(.attackMove(p), units: mine.map { $0.id })
            }
            scene?.marker(at: p, attack: true)
            return
        }
        if let h = hit {
            if h.owner == localPlayer {
                // tapping your own unit: select it; a second tap selects all of that type on screen
                let now = Date().timeIntervalSince1970
                if mine.contains(where: { $0.isWorker }) && h.isBuilding && !h.isComplete && !(selection == [h.id]) {
                    issue(.gather(h.id), units: mine.filter { $0.isWorker }.map { $0.id })
                    scene?.marker(at: h.pos, attack: false)
                } else if h.id == lastTapId && now - lastTapTime < 0.4, let scene {
                    select(world.entities.filter { $0.owner == localPlayer && $0.type == h.type && scene.onScreen($0.pos) }.map { $0.id })
                } else {
                    select([h.id])
                }
                lastTapId = h.id
                lastTapTime = now
                return
            }
            if !mine.isEmpty && mine.contains(where: { $0.isUnit }) {
                if h.type == .crystal {
                    issue(.gather(h.id), units: mine.map { $0.id })
                    scene?.marker(at: h.pos, attack: false)
                } else if world.enemies(localTeam, h.team) {
                    issue(.attack(h.id), units: mine.map { $0.id })
                    scene?.marker(at: h.pos, attack: true)
                } else {
                    issue(.move(p), units: mine.map { $0.id })
                    scene?.marker(at: p, attack: false)
                }
                return
            }
            if !mine.isEmpty && mine.allSatisfy({ $0.isBuilding }) {
                if h.type == .crystal { issue(.gather(h.id), units: mine.map { $0.id }) } else { issue(.rally(p), units: mine.map { $0.id }) }
                scene?.marker(at: p, attack: false)
                return
            }
            select([h.id])   // look at an enemy or a crystal
            return
        }
        guard !mine.isEmpty else { return }
        if mine.contains(where: { $0.isUnit }) {
            issue(.move(p), units: mine.map { $0.id })
        } else {
            issue(.rally(p), units: mine.map { $0.id })
        }
        scene?.marker(at: p, attack: false)
    }

    func boxSelect(_ a: Vec2, _ b: Vec2) {
        let lo = Vec2(min(a.x, b.x), min(a.y, b.y)), hi = Vec2(max(a.x, b.x), max(a.y, b.y))
        let inside = world.entities.filter { e in
            e.owner == localPlayer && e.isUnit && e.pos.x >= lo.x - e.st.radius && e.pos.x <= hi.x + e.st.radius &&
                e.pos.y >= lo.y - e.st.radius && e.pos.y <= hi.y + e.st.radius
        }
        let army = inside.filter { $0.isArmy }
        let ids = (army.isEmpty ? inside : army).map { $0.id }
        if !ids.isEmpty {
            select(ids)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }

    func startPlacing(_ t: EntityType) {
        buildMenu = false
        placing = t
        let c = scene?.cameraCenter ?? world.map.starts[max(0, localPlayer) % world.map.starts.count].center
        let n = t.stats.footprint
        placeOrigin = TilePoint(x: Int((c.x / Defs.tile - Double(n) / 2).rounded()), y: Int((c.y / Defs.tile - Double(n) / 2).rounded()))
    }

    var placementValid: Bool {
        guard let t = placing, let o = placeOrigin else { return false }
        return world.canPlace(t, at: o) && localTeam >= 0 && world.fog.explored(team: localTeam, world.map.center(o))
    }

    func confirmPlacement() {
        guard let t = placing, let o = placeOrigin, placementValid else { return }
        issue(.build(t, o), units: mySelected.filter { $0.isWorker }.map { $0.id })
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        placing = nil
    }

    func cancelPlacement() { placing = nil }

    // MARK: HUD

    private func refreshMinimap() {
        var dots: [MinimapDot] = []
        let w = world.map.worldWidth, h = world.map.worldHeight
        for e in world.entities where e.alive {
            if e.type == .crystal { continue }
            let visible = localTeam < 0 || e.team == localTeam || world.fog.visible(team: localTeam, e.pos)
            if !visible && !(e.isBuilding && world.fog.explored(team: localTeam, e.pos)) { continue }
            let color: Color
            if e.type == .beacon {
                color = e.owner >= 0 ? Color(Art.color(world.players[e.owner].color)) : .white
            } else {
                color = Color(Art.color(world.players[e.owner].color))
            }
            dots.append(MinimapDot(x: e.pos.x / w, y: 1 - e.pos.y / h, size: e.isBuilding ? 4 : (e.type == .beacon ? 4 : 2.2), color: color, square: e.isBuilding))
        }
        minimapDots = dots
        if let r = scene?.visibleWorldRect {
            cameraRect = CGRect(x: r.minX / w, y: 1 - r.maxY / h, width: r.width / w, height: r.height / h)
        }
    }

    func refreshHUD() {
        var s = HUDState()
        let secs = world.tick / Defs.tickRate
        s.time = String(format: "%d:%02d", secs / 60, secs % 60)
        s.waiting = session.waiting
        s.players = world.players.map { p in
            PlayerLine(id: p.index, name: p.name, color: p.color, crystals: p.crystals, supply: "\(p.supplyUsed)/\(p.supplyCap)",
                       army: world.entities.filter { $0.owner == p.index && $0.isArmy }.count, defeated: p.defeated)
        }
        if let p = me {
            s.crystals = p.crystals
            s.supplyUsed = p.supplyUsed
            s.supplyCap = p.supplyCap
            s.beacons = world.entities.filter { $0.type == .beacon && $0.owner >= 0 && world.players[$0.owner].team == p.team }.count
            s.idleWorkers = world.entities.filter { $0.owner == p.index && $0.isWorker && $0.order == .idle }.count
            s.armyCount = world.entities.filter { $0.owner == p.index && $0.isArmy }.count
        }
        let sel = selection.compactMap { world.entity($0) }
        var groupsByType: [EntityType: [Int]] = [:]
        for e in sel { groupsByType[e.type, default: []].append(e.id) }
        s.selection = EntityType.allCases.compactMap { t in groupsByType[t].map { SelectionGroup(type: t, ids: $0) } }
        if sel.count == 1, let e = sel.first {
            s.single = e
            if e.type == .crystal {
                s.singleHP = "\(e.amount) crystals left"
            } else if e.type != .beacon {
                s.singleHP = "\(Int(e.hp.rounded(.up))) / \(Int(e.maxHp))"
            }
            var info: [String] = []
            if e.isBuilding && !e.isComplete { info.append("Building \(Int(e.progress * 100))%") }
            if e.st.damage > 0 && e.type != .crystal {
                let dps = (e.sieged ? Defs.siegeDamage / Defs.siegeCooldown : e.st.damage / e.st.cooldown)
                info.append(e.type == .mender ? String(format: "Heals %.0f/s", dps) : String(format: "%.0f dps, range %.0f", dps, world.effectiveRange(e)))
            }
            if let b = e.st.bonusVs, e.st.bonusDamage > 0 { info.append("+\(Int(e.st.bonusDamage)) vs \(b.name)") }
            if e.isUnit { info.append(e.st.armorClass.name + (e.isAir ? ", air" : "")) }
            if e.kills >= 4 { info.append(e.kills >= 10 ? "★★ Elite" : "★ Veteran") }
            if e.cargo > 0 { info.append("Carrying \(e.cargo)") }
            if e.sieged { info.append("Sieged") }
            s.singleInfo = info.joined(separator: " · ")
            if e.owner == localPlayer {
                s.queue = e.queue.enumerated().map { i, item in
                    QueueSlot(id: i, item: item, progress: i == 0 ? min(1, e.queueProgress / item.time) : 0)
                }
            }
        }
        s.buttons = buttons(for: sel.filter { $0.owner == localPlayer })
        hud = s
    }

    private func buttons(for sel: [Entity]) -> [CommandButton] {
        guard let p = me, !sel.isEmpty else { return [] }
        var out: [CommandButton] = []
        let ids = sel.map { $0.id }
        let units = sel.filter { $0.isUnit }
        let workers = units.filter { $0.isWorker }

        if buildMenu && !workers.isEmpty {
            for t in EntityType.buildings {
                let ok = world.requirementsMet(t, player: p)
                let need = t.stats.requires.map { "Needs \($0.stats.name)" } ?? ""
                out.append(CommandButton(id: "b\(t.rawValue)", title: t.stats.name, icon: .entity(t), cost: t.stats.cost,
                                         enabled: ok && p.crystals >= t.stats.cost,
                                         hint: ok ? t.stats.blurb : need) { [weak self] in self?.startPlacing(t) })
            }
            out.append(CommandButton(id: "back", title: "Back", icon: .symbol("chevron.left"), enabled: true, hint: "") { [weak self] in
                self?.buildMenu = false
                self?.refreshHUD()
            })
            return out
        }
        if !units.isEmpty {
            if !workers.isEmpty {
                out.append(CommandButton(id: "build", title: "Build", icon: .symbol("hammer.fill"), enabled: true,
                                         hint: "Construct a building") { [weak self] in
                    self?.buildMenu = true
                    self?.refreshHUD()
                })
            }
            if units.contains(where: { $0.isArmy }) || workers.count > 0 {
                out.append(CommandButton(id: "amove", title: "Attack", icon: .symbol("scope"), enabled: true, highlighted: attackArmed,
                                         hint: "Then tap: move there, fighting everything on the way") { [weak self] in
                    self?.attackArmed.toggle()
                    self?.refreshHUD()
                })
            }
            out.append(CommandButton(id: "stop", title: "Stop", icon: .symbol("stop.fill"), enabled: true, hint: "Stop") { [weak self] in
                self?.issue(.stop, units: ids)
            })
            out.append(CommandButton(id: "hold", title: "Hold", icon: .symbol("shield.lefthalf.filled"), enabled: true,
                                     hint: "Hold position: shoot, but don't chase") { [weak self] in
                self?.issue(.hold, units: ids)
            })
            let tanks = units.filter { $0.type == .tank }
            if !tanks.isEmpty {
                let anyMobile = tanks.contains { !$0.sieged }
                out.append(CommandButton(id: "siege", title: anyMobile ? "Siege" : "Unsiege", icon: .upgrade(.siegeMode), enabled: p.has(.siegeMode),
                                         hint: p.has(.siegeMode) ? "Range 330 with splash, but cannot move" : "Research Siege Mode at the Tech Lab") { [weak self] in
                    self?.issue(anyMobile ? .siege : .unsiege, units: tanks.map { $0.id })
                })
            }
            let sprinters = units.filter { $0.type == .trooper || $0.type == .lancer }
            if !sprinters.isEmpty {
                let ready = sprinters.contains { $0.sprintCooldown <= 0 }
                out.append(CommandButton(id: "sprint", title: "Sprint", icon: .upgrade(.sprint), enabled: p.has(.sprint) && ready,
                                         hint: p.has(.sprint) ? "+50% speed and fire rate for 6 s, costs 10 HP" : "Research Sprint at the Tech Lab") { [weak self] in
                    self?.issue(.sprint, units: sprinters.map { $0.id })
                })
            }
            return out
        }
        // buildings: all the same type
        guard let first = sel.first, sel.allSatisfy({ $0.type == first.type }) else { return out }
        if !first.isComplete {
            out.append(CommandButton(id: "cancelb", title: "Cancel", icon: .symbol("xmark"), enabled: true, hint: "Refunds 75%") { [weak self] in
                self?.issue(.cancel, units: [first.id])
            })
            return out
        }
        for t in first.st.produces {
            let ok = world.requirementsMet(t, player: p)
            let need = t.stats.requires.map { "Needs \($0.stats.name)" } ?? ""
            out.append(CommandButton(id: "t\(t.rawValue)", title: t.stats.name, icon: .entity(t), cost: t.stats.cost,
                                     enabled: ok && p.crystals >= t.stats.cost && p.supplyUsed + t.stats.supply <= p.supplyCap,
                                     hint: ok ? "\(t.stats.blurb) Supply \(t.stats.supply)." : need) { [weak self] in
                self?.issue(.train(t), units: ids)
            })
        }
        for u in first.st.researches where !p.has(u) {
            let ok = world.canResearch(u, player: p)
            var hint = u.info.blurb
            if p.researching[u.rawValue] { hint = "Researching…" } else if let r = u.info.requires, !p.has(r) { hint = "Needs \(r.info.name)" }
            out.append(CommandButton(id: "r\(u.rawValue)", title: u.info.name, icon: .upgrade(u), cost: u.info.cost,
                                     enabled: ok && p.crystals >= u.info.cost, hint: hint) { [weak self] in
                self?.issue(.research(u), units: ids)
            })
        }
        if !first.queue.isEmpty {
            out.append(CommandButton(id: "cancelq", title: "Cancel", icon: .symbol("xmark"), enabled: true, hint: "Cancel the last item") { [weak self] in
                self?.issue(.cancel, units: [first.id])
            })
        }
        return out
    }
}

struct MinimapDot {
    var x: Double
    var y: Double
    var size: CGFloat
    var color: Color
    var square: Bool
}
