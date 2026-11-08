import Foundation

/// A computer player. It runs inside the simulation (so every peer runs the same bots in multiplayer), sees only what
/// its team sees, and acts only through Commands, like a human.
final class Bot {
    unowned let world: World
    let player: Int
    let difficulty: Difficulty
    let personality: Personality
    let interval: Int
    let phase: Int
    private var rng: Rng

    private struct Known { var id: Int; var type: EntityType; var pos: Vec2 }
    private var knownBuildings: [Known] = []
    private var enemySeen: [Double] = Array(repeating: 0, count: EntityType.allCases.count)
    private var attacking = false
    private var wave = 0
    private var nextAttackTick: Int
    private var attackTarget: Vec2?
    private var scoutId = 0
    private var scoutPlan: [Vec2] = []
    private var beaconSquad: [Int] = []
    private var beaconGoal = 0
    private var lastBuildTick = -10_000
    private var defending = false
    /// When set, commands go here instead of straight into the world (an autoplayer driving a networked seat).
    var sink: ((Command) -> Void)?

    init(world: World, player: Int, difficulty: Difficulty, personality: Personality) {
        self.world = world
        self.player = player
        self.difficulty = difficulty
        self.personality = personality
        switch difficulty {
        case .easy: interval = 40
        case .normal: interval = 20
        case .hard: interval = 10
        case .brutal: interval = 6
        }
        phase = player * 3
        rng = Rng(seed: world.setup.seed ^ (UInt64(player + 1) &* 0x2545_F491_4F6C_DD1D))
        let minute = 60 * Defs.tickRate
        switch (difficulty, personality) {
        case (.easy, _): nextAttackTick = 6 * minute
        case (_, .rusher): nextAttackTick = minute * 5 / 2
        case (_, .turtle): nextAttackTick = 6 * minute
        case (.normal, _): nextAttackTick = 4 * minute
        default: nextAttackTick = minute * 7 / 2
        }
    }

    private var me: Player { world.players[player] }
    private var team: Int { me.team }
    private func issue(_ units: [Int], _ a: Action) {
        guard !units.isEmpty || isGlobal(a) else { return }
        let c = Command(player: player, units: units, action: a)
        if let sink { sink(c) } else { world.apply(c) }
    }
    private func isGlobal(_ a: Action) -> Bool { if case .surrender = a { return true }; return false }
    private var smart: Bool { difficulty.rawValue >= Difficulty.normal.rawValue }
    private var sharp: Bool { difficulty.rawValue >= Difficulty.hard.rawValue }

    // MARK: think

    func think() {
        guard !me.defeated, !world.isOver else { return }
        var mine: [Entity] = []
        var visibleEnemies: [Entity] = []
        for e in world.entities where e.alive {
            if e.owner == player { mine.append(e); continue }
            guard e.owner >= 0, !e.type.isNeutral, world.enemies(team, e.team), world.fog.visible(team: team, e.pos) else { continue }
            visibleEnemies.append(e)
        }
        remember(visibleEnemies)
        let hqs = mine.filter { $0.type == .hq }
        guard let main = hqs.first ?? mine.first(where: { $0.isBuilding }) else { return }
        let workers = mine.filter { $0.isWorker }
        let army = mine.filter { $0.isArmy }

        manageWorkers(workers, hqs: hqs.isEmpty ? [main] : hqs)
        trainWorkers(hqs: hqs.filter { $0.isComplete }, workerCount: workers.count)
        if world.tick - lastBuildTick > interval * 2 {
            if !buildSupply(workers: workers, main: main) {
                if !buildTech(workers: workers, main: main, hqs: hqs) {
                    expand(workers: workers, main: main, hqs: hqs)
                }
            }
        }
        research(mine)
        produceArmy(mine, armyCount: army.count)
        controlArmy(army, main: main, mine: mine, enemies: visibleEnemies)
        scout(workers: workers, army: army, main: main)
    }

    // MARK: knowledge

    private func remember(_ enemies: [Entity]) {
        for e in enemies {
            enemySeen[e.type.rawValue] += e.isUnit ? 1 : 0
            if e.isBuilding, !knownBuildings.contains(where: { $0.id == e.id }) {
                knownBuildings.append(Known(id: e.id, type: e.type, pos: e.pos))
            }
        }
        // forget buildings that are gone (we can see the spot and it is not there)
        knownBuildings.removeAll { k in world.entity(k.id) == nil && world.fog.visible(team: team, k.pos) }
        for i in 0..<enemySeen.count { enemySeen[i] *= 0.985 }
    }

    // MARK: economy

    private func manageWorkers(_ workers: [Entity], hqs: [Entity]) {
        var idle: [Int] = []
        for w in workers where w.order == .idle && w.id != scoutId { idle.append(w.id) }
        guard !idle.isEmpty else { return }
        // send idle workers to the base that needs them most
        for id in idle {
            guard let w = world.entity(id) else { continue }
            let hq = hqs.min { $0.pos.distSq(w.pos) < $1.pos.distSq(w.pos) } ?? hqs[0]
            if let c = world.nearestCrystal(to: hq.pos, within: 360, preferFree: true) ?? world.nearestCrystal(to: w.pos, within: 2000, preferFree: true) {
                issue([id], .gather(c.id))
            }
        }
    }

    private var workerTarget: Int {
        let per: Int
        switch difficulty {
        case .easy: per = 15
        case .normal: per = 16
        case .hard, .brutal: per = 18
        }
        let bases = max(1, me.count(.hq))
        return min(difficulty == .easy ? 16 : 48, per * bases + (bases > 1 ? 2 : 0))
    }

    private func trainWorkers(hqs: [Entity], workerCount: Int) {
        let pending = me.pending[EntityType.worker.rawValue]
        guard workerCount + pending < workerTarget else { return }
        if personality == .rusher && attacking && workerCount > 14 { return }
        for hq in hqs where hq.queue.count < (sharp ? 2 : 1) {
            if me.crystals >= 50 && me.supplyUsed + 1 <= me.supplyCap {
                issue([hq.id], .train(.worker))
            }
        }
    }

    private func builder(_ workers: [Entity], near p: Vec2) -> Entity? {
        let free = workers.filter { w in
            switch w.order {
            case .build, .construct: return false
            default: return w.id != scoutId
            }
        }
        return free.min { a, b in
            let da = a.pos.distSq(p) + (a.cargo > 0 ? 4000 : 0), db = b.pos.distSq(p) + (b.cargo > 0 ? 4000 : 0)
            return da < db || (da == db && a.id < b.id)
        }
    }

    private func buildSupply(workers: [Entity], main: Entity) -> Bool {
        let p = me
        guard p.supplyCap < Defs.maxSupply else { return false }
        let producers = p.count(.barracks) + p.count(.factory) + p.count(.hq)
        let buffer = 2 + producers * 2
        let incoming = p.pending[EntityType.depot.rawValue] * 8 + p.pending[EntityType.hq.rawValue] * 10
        guard p.supplyUsed + buffer >= p.supplyCap + incoming else { return false }
        return place(.depot, workers: workers, near: main)
    }

    private struct Goal { var type: EntityType; var count: Int; var workers: Int; var minute: Double }

    private var buildPlan: [Goal] {
        let delay: Double = difficulty == .easy ? 2 : 0
        let w: Int = difficulty == .easy ? 1 : 0
        switch personality {
        case .balanced:
            return [Goal(type: .barracks, count: 1, workers: 9 + w, minute: delay),
                    Goal(type: .factory, count: 1, workers: 14 + w, minute: 2.5 + delay),
                    Goal(type: .lab, count: 1, workers: 16 + w, minute: 4 + delay),
                    Goal(type: .barracks, count: 2, workers: 18 + w, minute: 5 + delay),
                    Goal(type: .turret, count: sharp ? 1 : 0, workers: 18, minute: 6),
                    Goal(type: .factory, count: sharp ? 2 : 1, workers: 26, minute: 8)]
        case .rusher:
            return [Goal(type: .barracks, count: 1, workers: 7 + w, minute: delay),
                    Goal(type: .barracks, count: 2, workers: 9 + w, minute: 1 + delay),
                    Goal(type: .barracks, count: sharp ? 3 : 2, workers: 12 + w, minute: 3 + delay),
                    Goal(type: .lab, count: 1, workers: 14 + w, minute: 4.5 + delay),
                    Goal(type: .factory, count: 1, workers: 16 + w, minute: 6 + delay)]
        case .turtle:
            return [Goal(type: .barracks, count: 1, workers: 10 + w, minute: delay),
                    Goal(type: .turret, count: 1, workers: 11, minute: 1.5 + delay),
                    Goal(type: .factory, count: 1, workers: 14 + w, minute: 2.5 + delay),
                    Goal(type: .turret, count: difficulty == .easy ? 1 : 3, workers: 15, minute: 3.5 + delay),
                    Goal(type: .lab, count: 1, workers: 16 + w, minute: 4 + delay),
                    Goal(type: .factory, count: 2, workers: 24, minute: 7 + delay),
                    Goal(type: .turret, count: difficulty == .easy ? 2 : 5, workers: 24, minute: 8)]
        case .mechanic:
            return [Goal(type: .barracks, count: 1, workers: 9 + w, minute: delay),
                    Goal(type: .factory, count: 1, workers: 12 + w, minute: 2 + delay),
                    Goal(type: .lab, count: 1, workers: 15 + w, minute: 3.5 + delay),
                    Goal(type: .factory, count: 2, workers: 18 + w, minute: 5 + delay),
                    Goal(type: .factory, count: sharp ? 3 : 2, workers: 28, minute: 9)]
        }
    }

    private func buildTech(workers: [Entity], main: Entity, hqs: [Entity]) -> Bool {
        let minutes = Double(world.tick) / Double(60 * Defs.tickRate)
        for g in buildPlan where g.count > 0 {
            let have = me.count(g.type) + me.pending[g.type.rawValue]
            if have >= g.count { continue }
            if workers.count < g.workers || minutes < g.minute { return false }
            guard world.requirementsMet(g.type, player: me) else { return false }
            // let one building finish before the next tier on easy
            if difficulty == .easy && (me.pending[EntityType.barracks.rawValue] + me.pending[EntityType.factory.rawValue]) > 0 { return false }
            let anchor = g.type == .turret ? turretSpot(hqs: hqs, main: main) : main.pos
            return place(g.type, workers: workers, near: main, anchor: anchor)
        }
        // late game: spend a big bank on more production
        if me.crystals > 700 && me.count(.barracks) + me.count(.factory) < (sharp ? 7 : 4) {
            let t: EntityType = (personality == .mechanic || me.count(.factory) < me.count(.barracks)) && me.count(.barracks) > 0 ? .factory : .barracks
            return place(t, workers: workers, near: main)
        }
        return false
    }

    private func turretSpot(hqs: [Entity], main: Entity) -> Vec2 {
        let center = Vec2(world.map.worldWidth / 2, world.map.worldHeight / 2)
        let base = hqs.count > 1 ? hqs[hqs.count - 1] : main
        let n = me.count(.turret) + me.pending[EntityType.turret.rawValue]
        let toward = (center - base.pos).normalized()
        let side = toward.perp * (Double(n % 3 - 1) * 110)
        return base.pos + toward * 230 + side
    }

    private func expand(workers: [Entity], main: Entity, hqs: [Entity]) {
        guard smart, me.pending[EntityType.hq.rawValue] == 0 else { return }
        let minutes = Double(world.tick) / Double(60 * Defs.tickRate)
        let maxBases = sharp ? 4 : 2
        guard hqs.count < maxBases else { return }
        let wantByWorkers = workers.count >= workerTarget - 2
        let early: Double = personality == .turtle ? 4 : (personality == .rusher ? 9 : 6)
        guard wantByWorkers && minutes > early * Double(hqs.count) * 0.8 || me.crystals > 900 else { return }
        guard me.crystals >= 400 else { return }
        // nearest free base site to the main
        var best: BaseSite?
        var bestD = Double.infinity
        for site in world.map.bases {
            let c = site.center
            if world.entities.contains(where: { $0.isBuilding && $0.alive && $0.pos.distSq(c) < 260 * 260 }) { continue }
            if !world.canPlace(.hq, at: site.hqOrigin) { continue }
            if !world.fog.explored(team: team, c) && difficulty == .normal && hqs.count > 1 { continue }
            let d = c.dist(main.pos)
            if d < bestD { bestD = d; best = site }
        }
        guard let site = best, let w = builder(workers, near: site.center) else { return }
        issue([w.id], .build(.hq, site.hqOrigin))
        lastBuildTick = world.tick
    }

    /// Finds room near `anchor` (spiralling out) and sends a worker. Keeps a free tile around buildings and stays out
    /// of the mining lanes.
    @discardableResult
    private func place(_ type: EntityType, workers: [Entity], near main: Entity, anchor: Vec2? = nil) -> Bool {
        let cost = type.stats.cost
        guard me.crystals >= cost - (sharp ? 20 : 0) else { return true }   // saving up counts as "doing it"
        let n = type.stats.footprint
        let a = anchor ?? main.pos
        let at = world.map.tile(of: a)
        let crystals = world.entities.filter { $0.type == .crystal && $0.alive && $0.pos.distSq(main.pos) < 360 * 360 }
        let mineDir: Vec2 = {
            guard !crystals.isEmpty else { return .zero }
            var s = Vec2.zero
            for c in crystals { s += c.pos }
            return (s / Double(crystals.count) - main.pos).normalized()
        }()
        let startRing = anchor == nil ? 3 : 0
        let skew = rng.int(4)
        for r in startRing...14 {
            var options: [TilePoint] = []
            for dy in -r...r {
                for dx in -r...r where abs(dx) == r || abs(dy) == r {
                    options.append(TilePoint(x: at.x + dx - n / 2, y: at.y + dy - n / 2))
                }
            }
            if !options.isEmpty {
                let k = (skew * options.count / 4) % options.count
                options = Array(options[k...] + options[..<k])
            }
            for o in options {
                let pad = TilePoint(x: o.x - 1, y: o.y - 1)
                guard world.map.canPlace(origin: pad, size: n + 2), world.canPlace(type, at: o) else { continue }
                let c = Vec2((Double(o.x) + Double(n) / 2) * Defs.tile, (Double(o.y) + Double(n) / 2) * Defs.tile)
                if mineDir != .zero && type != .turret {
                    let rel = c - main.pos
                    if rel.dot(mineDir) > -20 && rel.length < 260 { continue }
                }
                // no units standing there
                var blocked = false
                world.grid.query(c, Double(n) * 16) { u in if u.isUnit && !u.isAir { blocked = true } }
                if blocked { continue }
                guard let w = builder(workers, near: c) else { return false }
                issue([w.id], .build(type, o))
                lastBuildTick = world.tick
                return true
            }
        }
        return false
    }

    private func research(_ mine: [Entity]) {
        guard let lab = mine.first(where: { $0.type == .lab && $0.isComplete && $0.queue.isEmpty }) else { return }
        if difficulty == .easy && world.tick < 9 * 60 * Defs.tickRate { return }
        let tanks = me.count(.tank), infantry = me.count(.trooper) + me.count(.lancer)
        var order: [Upgrade]
        switch personality {
        case .mechanic: order = [.siegeMode, .weapons1, .plating1, .weapons2, .plating2, .sprint]
        case .rusher: order = [.sprint, .weapons1, .plating1, .weapons2, .plating2, .siegeMode]
        case .turtle: order = [.siegeMode, .plating1, .weapons1, .plating2, .weapons2, .sprint]
        case .balanced: order = [.weapons1, infantry > tanks * 2 ? .sprint : .siegeMode, .plating1, .weapons2, .siegeMode, .sprint, .plating2]
        }
        if difficulty == .easy { order = [.weapons1] }
        let reserve = sharp ? 50 : 150
        for u in order where world.canResearch(u, player: me) {
            if u == .siegeMode && tanks == 0 && personality != .mechanic { continue }
            if u == .sprint && infantry < 4 { continue }
            if me.crystals >= u.info.cost + reserve { issue([lab.id], .research(u)) }
            return
        }
    }

    // MARK: army

    private func weights() -> [EntityType: Double] {
        var w: [EntityType: Double]
        switch personality {
        case .balanced: w = [.trooper: 3, .lancer: 2, .mender: 0.8, .skimmer: 1, .tank: 2, .gunship: 1]
        case .rusher: w = [.trooper: 5, .lancer: 1.2, .mender: 1, .skimmer: 2.5, .tank: 0.8, .gunship: 0.4]
        case .turtle: w = [.trooper: 2, .lancer: 2, .mender: 1, .skimmer: 0.3, .tank: 3.5, .gunship: 1]
        case .mechanic: w = [.trooper: 1, .lancer: 1, .mender: 0.3, .skimmer: 2, .tank: 4, .gunship: 2]
        }
        guard smart else { return w }
        // counter what we have seen
        let s = enemySeen
        let armored = s[EntityType.tank.rawValue] + s[EntityType.gunship.rawValue]
        let light = s[EntityType.trooper.rawValue] + s[EntityType.skimmer.rawValue] + s[EntityType.mender.rawValue] + s[EntityType.lancer.rawValue]
        let air = s[EntityType.gunship.rawValue]
        let total = armored + light + 0.001
        let k = sharp ? 1.6 : 0.8
        if total > 3 {
            let fa = armored / total, fl = light / total
            w[.lancer, default: 0] *= 1 + k * fa * 2
            w[.gunship, default: 0] *= 1 + k * s[EntityType.tank.rawValue] / total * 2
            w[.tank, default: 0] *= 1 + k * fl * 1.5
            w[.skimmer, default: 0] *= 1 + k * (s[EntityType.trooper.rawValue] < s[EntityType.lancer.rawValue] ? fl : 0)
            w[.trooper, default: 0] *= 1 + k * fl * 0.5
            if air / total > 0.2 {
                w[.trooper, default: 0] *= 1 + k
                w[.lancer, default: 0] *= 1 + k
                w[.tank, default: 0] *= 0.5
                w[.skimmer, default: 0] *= 0.3
            }
        }
        return w
    }

    private func produceArmy(_ mine: [Entity], armyCount: Int) {
        let producers = mine.filter { ($0.type == .barracks || $0.type == .factory) && $0.isComplete }
        guard !producers.isEmpty else { return }
        let w = weights()
        var have: [EntityType: Int] = [:]
        for e in mine where e.isArmy { have[e.type, default: 0] += 1 }
        for t in EntityType.army { have[t, default: 0] += me.pending[t.rawValue] }
        let total = Double(max(1, have.values.reduce(0, +)))
        let maxQueue = sharp ? 2 : 1
        // keep some money for planned buildings
        let reserve = (me.count(.barracks) == 0 || world.tick - lastBuildTick < 60) ? 100 : 0
        for b in producers where b.queue.count < maxQueue {
            var options = b.st.produces.filter { world.requirementsMet($0, player: me) }
            if options.isEmpty { continue }
            if !smart {
                options = options.filter { $0 != .mender && $0 != .gunship }
                if options.isEmpty { continue }
                let t = options[rng.int(options.count)]
                if me.crystals >= t.stats.cost + reserve { issue([b.id], .train(t)) }
                continue
            }
            let totalW = options.reduce(0) { $0 + (w[$1] ?? 0) } + 0.001
            var best = options[0]
            var bestDeficit = -Double.infinity
            for t in options {
                let want = (w[t] ?? 0) / totalW
                let cur = Double(have[t] ?? 0) / total
                let deficit = want - cur + rng.range(0, 0.05)
                if t == .mender && Double(have[.mender] ?? 0) > Double((have[.trooper] ?? 0) + (have[.lancer] ?? 0)) / 4 { continue }
                if deficit > bestDeficit { bestDeficit = deficit; best = t }
            }
            if me.crystals >= best.stats.cost + reserve && me.supplyUsed + best.stats.supply <= me.supplyCap {
                issue([b.id], .train(best))
                have[best, default: 0] += 1
            }
        }
    }

    private func power(_ list: [Entity]) -> Double {
        list.reduce(0) { s, e in
            guard e.isArmy || e.type == .turret else { return s + (e.isWorker ? 5 : 0) }
            return s + Double(e.st.cost) * (e.hp / e.maxHp) * (e.type == .turret ? 1.2 : 1)
        }
    }

    private var attackThreshold: Int {
        var base: Int
        switch difficulty {
        case .easy: base = 8 + wave * 3
        case .normal: base = 14 + wave * 4
        case .hard, .brutal: base = 18 + wave * 4
        }
        if personality == .rusher { base = base * 2 / 3 }
        if personality == .turtle { base = base * 4 / 3 }
        return min(base, difficulty == .easy ? 30 : 70)
    }

    private func controlArmy(_ army: [Entity], main: Entity, mine: [Entity], enemies: [Entity]) {
        guard !army.isEmpty else { return }
        let center = Vec2(world.map.worldWidth / 2, world.map.worldHeight / 2)
        let rally = world.clampToMap(main.pos + (center - main.pos).normalized() * 260)
        let armySupply = army.reduce(0) { $0 + $1.st.supply }
        let free = army.filter { !beaconSquad.contains($0.id) }

        // 1. defend: enemies close to our buildings
        let buildings = mine.filter { $0.isBuilding }
        let threats = enemies.filter { e in
            !e.isBuilding && !e.isWorker && buildings.contains { $0.pos.distSq(e.pos) < 520 * 520 }
        }
        if !threats.isEmpty {
            var c = Vec2.zero
            for t in threats { c += t.pos }
            c = c / Double(threats.count)
            defending = true
            let reactLimit = difficulty == .easy ? 0.6 : 1.0
            let responders = attacking && power(threats) < power(free) * 0.3
                ? free.filter { $0.pos.distSq(c) < 900 * 900 }
                : free
            let ids = responders.prefix(Int(Double(responders.count) * reactLimit + 1)).map { $0.id }
            issue(Array(ids), .attackMove(c))
            if sharp { micro(responders, enemies: enemies) }
            return
        }
        if defending {
            defending = false
            if !attacking { issue(free.map { $0.id }, .attackMove(rally)) }
        }

        // 2. attack waves
        if !attacking && world.tick >= nextAttackTick && (armySupply >= attackThreshold || me.supplyUsed >= Defs.maxSupply - 6) {
            attacking = true
            wave += 1
            attackTarget = pickTarget(from: armyCenter(free) ?? rally)
        }
        if attacking {
            let myPower = power(free)
            let near = enemies.filter { e in free.contains { $0.pos.distSq(e.pos) < 500 * 500 } }
            let theirPower = power(near)
            if smart && theirPower > myPower * (sharp ? 1.6 : 2.2) || armySupply < attackThreshold / 3 {
                // retreat and regroup
                attacking = false
                nextAttackTick = world.tick + (difficulty == .easy ? 120 : 60) * Defs.tickRate / 2
                issue(free.map { $0.id }, .move(rally))
                return
            }
            if let t = attackTarget, let ac = armyCenter(free), ac.dist(t) < 200, near.isEmpty {
                attackTarget = pickTarget(from: ac)
            }
            if let t = attackTarget {
                let idle = free.filter { $0.order == .idle || isRally($0, rally) }
                issue(idle.map { $0.id }, .attackMove(t))
                // stragglers far behind regroup on the army
                if sharp, let ac = armyCenter(free) {
                    let lost = free.filter { $0.pos.dist(ac) > 700 && $0.order != .idle }
                    issue(lost.map { $0.id }, .attackMove(ac))
                }
            } else {
                attacking = false
            }
            if sharp { micro(free, enemies: enemies) }
        } else {
            // gather at the rally point
            let idle = free.filter { $0.order == .idle && $0.pos.dist(rally) > 220 }
            issue(idle.map { $0.id }, .attackMove(rally))
            sendBeaconSquad(free)
        }
        beaconSquad.removeAll { world.entity($0) == nil }
        if let b = world.entity(beaconGoal), b.team == team { beaconSquad.removeAll(); beaconGoal = 0 }
    }

    private func isRally(_ e: Entity, _ rally: Vec2) -> Bool {
        if case let .attackMove(p) = e.order, p.distSq(rally) < 30 * 30 { return true }
        if case let .move(p) = e.order, p.distSq(rally) < 30 * 30 { return true }
        return false
    }

    private func armyCenter(_ army: [Entity]) -> Vec2? {
        guard !army.isEmpty else { return nil }
        var c = Vec2.zero
        for e in army { c += e.pos }
        return c / Double(army.count)
    }

    private func pickTarget(from p: Vec2) -> Vec2? {
        // closest known enemy building; otherwise the enemy start locations
        if let k = knownBuildings.min(by: { a, b in
            let pa = a.pos.distSq(p) * (a.type == .hq ? 0.6 : 1), pb = b.pos.distSq(p) * (b.type == .hq ? 0.6 : 1)
            return pa < pb || (pa == pb && a.id < b.id)
        }) { return k.pos }
        let mine = world.map.starts[player % world.map.starts.count].center
        let others = world.map.starts.map { $0.center }.filter { $0.distSq(mine) > 100 && !world.fog.visible(team: team, $0) }
        return others.min { $0.distSq(p) < $1.distSq(p) } ?? world.map.starts.map { $0.center }.first { $0.distSq(mine) > 100 }
    }

    private func sendBeaconSquad(_ army: [Entity]) {
        guard smart, beaconSquad.isEmpty, army.count >= 6 else { return }
        let beacons = world.entities.filter { $0.type == .beacon && $0.alive && $0.team != team }
        guard let a = armyCenter(army), let goal = beacons.min(by: { $0.pos.distSq(a) < $1.pos.distSq(a) }) else { return }
        let squad = army.sorted { $0.pos.distSq(goal.pos) < $1.pos.distSq(goal.pos) }.prefix(sharp ? 4 : 3)
        beaconSquad = squad.map { $0.id }
        beaconGoal = goal.id
        issue(beaconSquad, .attackMove(goal.pos))
    }

    /// Hard and Brutal: focus fire, siege tanks, sprint into fights.
    private func micro(_ army: [Entity], enemies: [Entity]) {
        guard !army.isEmpty, !enemies.isEmpty else {
            if me.has(.siegeMode) {
                let sieged = army.filter { $0.type == .tank && $0.sieged }
                issue(sieged.map { $0.id }, .unsiege)
            }
            return
        }
        let fighters = enemies.filter { $0.isUnit || $0.type == .turret }
        // siege up when ground enemies come close; pack up when nothing is around
        if me.has(.siegeMode) {
            var siege: [Int] = [], unsiege: [Int] = []
            for t in army where t.type == .tank && t.siegeTimer <= 0 {
                let close = fighters.contains { !$0.isAir && $0.pos.distSq(t.pos) < 340 * 340 }
                let any = enemies.contains { !$0.isAir && $0.pos.distSq(t.pos) < 420 * 420 }
                if close && !t.sieged { siege.append(t.id) }
                if !any && t.sieged { unsiege.append(t.id) }
            }
            issue(siege, .siege)
            issue(unsiege, .unsiege)
        }
        if me.has(.sprint) {
            let ids = army.filter { u in
                (u.type == .trooper || u.type == .lancer) && u.sprintCooldown <= 0 && u.hp > 35 &&
                    fighters.contains { $0.pos.distSq(u.pos) < 260 * 260 }
            }.map { $0.id }
            issue(ids, .sprint)
        }
        // focus fire: everybody in range of the weakest threat shoots it
        guard let weakest = fighters.filter({ e in army.contains { world.canHit($0, e) && $0.gap(to: e) <= world.effectiveRange($0) + 20 } })
            .min(by: { a, b in a.hp / a.maxHp < b.hp / b.maxHp || (a.hp / a.maxHp == b.hp / b.maxHp && a.id < b.id) }) else { return }
        let shooters = army.filter { $0.type != .mender && !$0.sieged && world.canHit($0, weakest) && $0.gap(to: weakest) <= world.effectiveRange($0) + 40 }
        issue(shooters.filter { $0.order != .attack(weakest.id) }.map { $0.id }, .attack(weakest.id))
    }

    private func scout(workers: [Entity], army: [Entity], main: Entity) {
        guard smart else { return }
        let minute = 60 * Defs.tickRate
        if scoutId == 0 && world.tick > minute * 3 / 2 && world.tick < minute * 2 && knownBuildings.isEmpty {
            if let w = workers.last(where: { $0.cargo == 0 }) {
                scoutId = w.id
                scoutPlan = world.map.starts.map { $0.center }.filter { $0.distSq(main.pos) > 300 * 300 }
                scoutPlan.sort { $0.distSq(main.pos) < $1.distSq(main.pos) }
            }
        }
        guard scoutId != 0 else { return }
        guard let s = world.entity(scoutId) else { scoutId = -1; return }
        if !knownBuildings.isEmpty && !scoutPlan.isEmpty && s.isWorker {
            // found them: go home
            scoutPlan = []
            issue([s.id], .stop)
            scoutId = -1
            return
        }
        if let next = scoutPlan.first {
            if s.pos.dist(next) < 200 { scoutPlan.removeFirst() } else if s.order == .idle || !isGoing(s, to: next) {
                issue([s.id], .move(next))
            }
        } else if s.isWorker {
            issue([s.id], .stop)
            scoutId = -1
        }
    }

    private func isGoing(_ e: Entity, to p: Vec2) -> Bool {
        if case let .move(q) = e.order { return q.distSq(p) < 64 * 64 }
        return false
    }
}
