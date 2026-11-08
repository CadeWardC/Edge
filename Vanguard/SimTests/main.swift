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
    return String(format: "%.1f min, winner team %@: ", mins, w.winningTeam.map(String.init) ?? "none") + ps
}

// MARK: maps
print("Maps")
for id in MapID.allCases {
    let m = MapGen.build(id)
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
