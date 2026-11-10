import Foundation

// Headless checks of the simulation, run on CI (see .github/workflows/build-vanguard-ipa.yml):
//   swiftc -O Vanguard/Vanguard/Sim/*.swift Vanguard/Vanguard/Net/*.swift Vanguard/SimTests/main.swift -o simtest
// 1. determinism: the same setup gives the same game, 2. lockstep over a fake network stays in sync,
// 3. bot ladder: harder bots beat easier ones, 4. every map is fair-ish and finishes, 5. speed.

setvbuf(stdout, nil, _IONBF, 0)
var failures = 0
var blockedTicks: [Int: Int] = [:]
func track(_ w: World) {
    for p in w.players where !p.defeated && p.supplyCap < Defs.maxSupply && p.supplyUsed >= p.supplyCap && p.crystals > 250 {
        blockedTicks[p.index, default: 0] += 1
    }
}

func check(_ ok: Bool, _ what: String) {
    print(ok ? "  ok   \(what)" : "  FAIL \(what)")
    if !ok { failures += 1 }
}

func bots(_ diffs: [Difficulty], map: MapID, personalities: [Personality?]? = nil) -> [PlayerSetup] {
    diffs.enumerated().map { i, d in
        PlayerSetup(name: "\(d.name) \(i)", team: map.defaultTeam(slot: i), color: TeamColor.allCases[i], isBot: true,
                    difficulty: d, personality: personalities?[i])
    }
}

func run(_ w: World, maxMinutes: Double) {
    let limit = Int(maxMinutes * 60) * Defs.tickRate
    let t0 = Date()
    var slowest = 0.0, slowTick = 0
    while !w.isOver && w.tick < limit {
        let s = Date()
        w.step([])
        track(w)
        let d = Date().timeIntervalSince(s)
        if d > slowest { slowest = d; slowTick = w.tick }
        if w.tick % 2400 == 0 && Date().timeIntervalSince(t0) > 60 {
            print(String(format: "    !! still running after %.0fs at minute %d (slowest tick %.1f ms at %d, %d units, %d path searches)",
                         Date().timeIntervalSince(t0), w.tick / 1200, slowest * 1000, slowTick,
                         w.entities.filter { $0.isUnit }.count, w.pathfinder.searches))
            check(false, "game finishes in reasonable time")
            return
        }
    }
    if slowest > 0.02 {
        print(String(format: "    slowest tick %.1f ms at %d; %d path searches", slowest * 1000, slowTick, w.pathfinder.searches))
    }
}

var blockedSamples: [Int] = []
func describe(_ w: World) -> String {
    for p in w.players { blockedSamples.append((blockedTicks[p.index] ?? 0) / Defs.tickRate) }
    defer { blockedTicks = [:] }
    let mins = Double(w.tick) / Double(60 * Defs.tickRate)
    let ps = w.players.map { p in
        "\(p.name)[\(w.bots.first { $0.player == p.index }?.personality.name ?? "-")] made \(p.unitsMade) (supply-blocked \((blockedTicks[p.index] ?? 0) / Defs.tickRate)s, cap \(p.supplyCap)) killed \(p.kills) mined \(p.gathered)\(p.defeated ? " (out)" : "")"
    }.joined(separator: "; ")
    var extra = ""
    if w.winningTeam == nil {
        for p in w.players {
            let blds = w.entities.filter { $0.owner == p.index && $0.isBuilding }
                .map { "\($0.st.name)@\(Int($0.pos.x)),\(Int($0.pos.y))\($0.isComplete ? "" : "(unfinished)") elev\(w.map.elevation(at: $0.pos))" }
            let army = w.entities.filter { $0.owner == p.index && $0.isArmy }.count
            let workers = w.entities.filter { $0.owner == p.index && $0.isWorker }.count
            extra += "\n      \(p.name): army \(army), drones \(workers), supply \(p.supplyUsed)/\(p.supplyCap), crystals \(p.crystals), "
            extra += (w.bots.first { $0.player == p.index }?.debugState ?? "") + ", buildings: " + blds.prefix(6).joined(separator: " ")
        }
    }
    return String(format: "%.1f min, winner team %@: ", mins, w.winningTeam.map(String.init) ?? "none") + ps + extra
}

// MARK: maps
print("Maps")
for id in MapID.allCases {
    let m = MapGen.build(id)
    // ASCII picture of the map (top row = north), for eyeballing layouts in the CI log
    var marks: [Int: Character] = [:]
    for b in m.bases {
        for c in b.crystals { marks[m.index(c.x, c.y)] = b.rich ? "v" : "c" }
        marks[m.index(b.hqOrigin.x + 1, b.hqOrigin.y + 1)] = b.isStart ? "S" : "H"
    }
    for b in m.beacons { marks[m.index(b.x, b.y)] = "B" }
    for t in m.towers { marks[m.index(t.x, t.y)] = "W" }
    for y in stride(from: m.height - 1, through: 0, by: -1) {
        var row = ""
        for x in 0..<m.width {
            let i = m.index(x, y)
            if let mk = marks[i] { row.append(mk); continue }
            let high = m.elevation[i] == 1
            switch m.terrain[i] {
            case .grass: row.append(high ? "^" : ".")
            case .dirt: row.append(high ? ";" : ":")
            case .rock: row.append("#")
            case .water: row.append("~")
            case .cliff: row.append("C")
            case .forest: row.append("T")
            case .ramp: row.append("/")
            }
        }
        print("MAP \(id.name)|" + row)
    }
    check(m.starts.count >= id.maxPlayers, "\(id.name): \(m.starts.count) starts, \(m.bases.count) bases, \(m.beacons.count) beacons")
    let w = World(setup: MatchSetup(map: id, seed: 1, players: bots(Array(repeating: .normal, count: id.maxPlayers), map: id)))
    let crystals = w.entities.filter { $0.type == .crystal }.count
    check(crystals >= m.bases.count * 6, "\(id.name): \(crystals) crystals placed")
    // every start can walk to every other start
    let a = w.map.starts[0].center + Vec2(0, -70)
    for s in w.map.starts.dropFirst() {
        let p = w.pathfinder.path(from: a, to: s.center + Vec2(0, -70), tick: -1, halfWidth: 6) ?? []
        let end = p.last ?? a
        check(end.dist(s.center + Vec2(0, -70)) < 80, "\(id.name): path from start 0 reaches start at \(Int(s.center.x)),\(Int(s.center.y))")
    }
}

// MARK: new orders
print("Auto-train, retreat, powers")
do {
    let setup = MatchSetup(map: .crossroads, seed: 3, players: [
        PlayerSetup(name: "A", team: 0, color: .blue, isBot: false),
        PlayerSetup(name: "B", team: 1, color: .red, isBot: false, bonusCrystals: 2000),
    ])
    let w = World(setup: setup)
    let hq = w.entities.first { $0.owner == 0 && $0.type == .hq }!
    w.step([Command(player: 0, units: [hq.id], action: .autoTrain(.worker))])
    for _ in 0..<(70 * Defs.tickRate) { w.step([]) }
    let drones = w.entities.filter { $0.owner == 0 && $0.isWorker }
    check(drones.count >= 9, "auto-train keeps a Command Center making Drones (\(drones.count) after 70 s)")
    let runner = drones[0]
    w.step([Command(player: 0, units: [runner.id], action: .move(Vec2(w.map.worldWidth / 2, w.map.worldHeight / 2)))])
    for _ in 0..<(12 * Defs.tickRate) { w.step([]) }
    let far = runner.pos.dist(hq.pos)
    w.step([Command(player: 0, units: [runner.id], action: .retreat)])
    for _ in 0..<(25 * Defs.tickRate) { w.step([]) }
    check(far > 300 && runner.pos.dist(hq.pos) < 220, "retreat brings a unit home (from \(Int(far)) to \(Int(runner.pos.dist(hq.pos))))")
    // powers need their building: refused without one, and never charged
    let before = w.players[1].crystals
    w.step([Command(player: 1, units: [], action: .power(.strike, hq.pos))])
    check(w.strikes.isEmpty && w.players[1].crystals == before, "Orbital Strike is refused without a Tech Lab")
}

// MARK: watch-only
do {
    let w = World(setup: MatchSetup(map: .crossroads, seed: 9, players: bots([.normal, .normal], map: .crossroads)))
    let s = LockstepSession(world: w, humans: [], local: [], transport: nil)
    var ran = 0
    for _ in 0..<200 where s.stepTick() { ran += 1 }
    check(ran == 200, "a match with only bots (watch-only, menu battle) advances (\(ran) of 200 ticks)")
}

// MARK: determinism
print("Determinism")
do {
    let setup = MatchSetup(map: .highlands, seed: 42, players: bots([.hard, .normal, .brutal, .easy], map: .highlands))
    let a = World(setup: setup), b = World(setup: setup)
    var same = true
    for t in 0..<(6 * 60 * Defs.tickRate) {
        a.step([]); b.step([])
        if t % 200 == 0 && a.checksum() != b.checksum() { same = false; print("    diverged at tick \(t)"); break }
    }
    check(same && a.checksum() == b.checksum(), "two runs of the same 4-bot match stay identical for 6 minutes")
}

// MARK: lockstep
print("Lockstep over a fake network")
do {
    let setup = MatchSetup(map: .crossroads, seed: 7, players: [
        PlayerSetup(name: "A", team: 0, color: .blue, isBot: false),
        PlayerSetup(name: "B", team: 1, color: .red, isBot: false),
    ])
    let hub = LoopbackHub()
    let wa = World(setup: setup), wb = World(setup: setup)
    let sa = LockstepSession(world: wa, humans: [0, 1], local: [0], transport: hub.makeEndpoint())
    let sb = LockstepSession(world: wb, humans: [0, 1], local: [1], transport: hub.makeEndpoint())
    // each "human" is an autoplayer that only sees its own copy of the world
    let pa = Bot(world: wa, player: 0, difficulty: .hard, personality: .balanced)
    let pb = Bot(world: wb, player: 1, difficulty: .normal, personality: .rusher)
    pa.sink = { sa.issue($0) }
    pb.sink = { sb.issue($0) }
    var desync = false
    sa.onDesync = { _ in desync = true }
    sb.onDesync = { _ in desync = true }
    var stalls = 0
    var commands = 0
    for i in 0..<(8 * 60 * Defs.tickRate) {
        if wa.tick % 10 == 0 { pa.think() }
        if wb.tick % 10 == 5 { pb.think() }
        let ra = sa.stepTick(), rb = sb.stepTick()
        track(wa)
        if ra && wa.tick % 1200 == 0 && wa.tick <= 4800 {
            for p in wa.players {
                var orders: [String: Int] = [:]
                for e in wa.entities where e.owner == p.index && e.isWorker {
                    let k: String
                    switch e.order {
                    case .idle: k = "idle"
                    case .gather: k = "gather"
                    case .returnCargo: k = "return"
                    case .build: k = "build"
                    case .construct: k = "construct"
                    case .move: k = "move"
                    default: k = "other"
                    }
                    orders[k, default: 0] += 1
                }
                let blds = EntityType.buildings.map { "\($0.stats.name)=\(p.count($0))+\(p.pending[$0.rawValue])" }.joined(separator: " ")
                print("    [min \(wa.tick / 1200)] \(p.name): crystals \(p.crystals) supply \(p.supplyUsed)/\(p.supplyCap) workers \(orders.sorted { $0.key < $1.key }) \(blds)")
            }
        }
        if !ra || !rb { stalls += 1 }
        hub.pump(keepNewest: i % 3)       // jittery latency
        if wa.isOver || wb.isOver { break }
    }
    hub.pump()
    for _ in 0..<40 { sa.stepTick(); sb.stepTick(); hub.pump() }
    commands = sa.log.count
    // bring both to the same tick and compare
    while wa.tick < wb.tick, sa.stepTick() {}
    while wb.tick < wa.tick, sb.stepTick() {}
    print("    " + describe(wa))
    check(commands > 50, "players issued \(commands) commands through the network")
    check(!desync, "no checksum mismatch reported")
    check(wa.tick == wb.tick && wa.checksum() == wb.checksum(), "both devices end in the same state (tick \(wa.tick), \(stalls) waits)")
}

// MARK: bot ladder
print("Bot ladder (1v1)")
var ladderWins = 0, ladderGames = 0
let ladder: [(Difficulty, Difficulty)] = [(.normal, .easy), (.hard, .normal), (.brutal, .hard), (.hard, .easy)]
for (strong, weak) in ladder {
    var wins = 0, games = 0
    for seed in 1...6 {
        let map: MapID = seed % 2 == 0 ? .twinRivers : .crossroads
        // swap sides every other game
        let strongFirst = seed % 3 != 0
        let players = strongFirst ? bots([strong, weak], map: map) : bots([weak, strong], map: map)
        let w = World(setup: MatchSetup(map: map, seed: UInt64(seed * 1000 + strong.rawValue * 10 + weak.rawValue), players: players))
        let t0 = Date()
        run(w, maxMinutes: 25)
        let strongTeam = strongFirst ? w.players[0].team : w.players[1].team
        games += 1
        if w.winningTeam == strongTeam { wins += 1 }
        print(String(format: "    %@ vs %@ seed %d (%.1fs): ", strong.name, weak.name, seed, Date().timeIntervalSince(t0)) + describe(w))
    }
    ladderWins += wins
    ladderGames += games
    check(wins * 2 > games, "\(strong.name) beats \(weak.name) in \(wins) of \(games)")
}

let avgBlocked = Double(blockedSamples.reduce(0, +)) / Double(max(1, blockedSamples.count))
check(avgBlocked < 45, String(format: "bots rarely sit supply-blocked (average %.0f s per game)", avgBlocked))

// MARK: bigger games finish
print("4-player games")
for (map, seed) in [(MapID.highlands, UInt64(3)), (MapID.frontier, UInt64(5))] {
    let w = World(setup: MatchSetup(map: map, seed: seed, players: bots([.hard, .normal, .hard, .normal], map: map)))
    let t0 = Date()
    run(w, maxMinutes: 30)
    let secs = Date().timeIntervalSince(t0)
    print(String(format: "    %@ (%.1fs, %.2f ms/tick): ", map.name, secs, secs * 1000 / Double(max(1, w.tick))) + describe(w))
    check(w.players.allSatisfy { $0.unitsMade > 10 }, "\(map.name): every bot builds an army")
    check(secs * 1000 / Double(max(1, w.tick)) < 4, "\(map.name): ticks are fast enough for a phone")
}

print(failures == 0 ? "All checks passed" : "\(failures) check(s) failed")
exit(failures == 0 ? 0 : 1)
