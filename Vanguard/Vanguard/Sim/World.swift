import Foundation

enum Vanguard {
    /// Bump whenever the simulation changes: peers must run the exact same rules.
    static let protocolVersion = 1
}

struct PlayerSetup: Codable, Equatable {
    var name: String
    var team: Int
    var color: TeamColor
    var isBot: Bool
    var difficulty: Difficulty = .normal
    var personality: Personality? = nil   // nil = picked from the match seed
    var clientId: String? = nil           // multiplayer: the device playing this slot
}

struct MatchSetup: Codable, Equatable {
    var map: MapID
    var seed: UInt64
    var players: [PlayerSetup]
    var startCrystals: Int = Defs.startCrystals
    var version: Int = Vanguard.protocolVersion
}

final class Player {
    let index: Int
    let team: Int
    let name: String
    let color: TeamColor
    let isBot: Bool
    let difficulty: Difficulty
    var crystals: Int
    var crystalFrac: Double = 0
    var supplyUsed = 0
    var supplyCap = 0
    var upgrades: [Bool] = Array(repeating: false, count: Upgrade.allCases.count)
    var researching: [Bool] = Array(repeating: false, count: Upgrade.allCases.count)
    /// Completed buildings / living units per EntityType.
    var counts: [Int] = Array(repeating: 0, count: EntityType.allCases.count)
    var pending: [Int] = Array(repeating: 0, count: EntityType.allCases.count)   // under construction / in queue
    var defeated = false
    var gatherMultiplier: Double = 1
    var lastAlertTick = -10_000
    // stats
    var gathered = 0
    var unitsMade = 0
    var unitsLost = 0
    var kills = 0
    var buildingsMade = 0

    init(index: Int, setup: PlayerSetup, team: Int, crystals: Int) {
        self.index = index
        self.team = team
        name = setup.name
        color = setup.color
        isBot = setup.isBot
        difficulty = setup.difficulty
        self.crystals = crystals
    }

    func has(_ u: Upgrade) -> Bool { upgrades[u.rawValue] }
    func count(_ t: EntityType) -> Int { counts[t.rawValue] }
    var weaponsLevel: Int { (has(.weapons1) ? 1 : 0) + (has(.weapons2) ? 1 : 0) }
    var platingLevel: Int { (has(.plating1) ? 1 : 0) + (has(.plating2) ? 1 : 0) }
}

final class World {
    let setup: MatchSetup
    let map: GameMap
    let pathfinder: Pathfinder
    let grid: SpatialGrid
    let fog: Fog
    var tick = 0
    private(set) var entities: [Entity] = []
    private var byId: [Int: Entity] = [:]
    private var nextId = 1
    var players: [Player] = []
    var teamCount = 0
    var rng: Rng
    var bots: [Bot] = []
    var events: [GameEvent] = []
    var winningTeam: Int?
    var isOver: Bool { winningTeam != nil }
    let dt = Defs.dt

    init(setup: MatchSetup) {
        self.setup = setup
        map = MapGen.build(setup.map)
        pathfinder = Pathfinder(map: map)
        grid = SpatialGrid(width: map.worldWidth, height: map.worldHeight)
        rng = Rng(seed: setup.seed)

        // teams become 0..<teamCount
        var teamIds: [Int] = []
        for p in setup.players where !teamIds.contains(p.team) { teamIds.append(p.team) }
        teamCount = teamIds.count
        fog = Fog(width: map.width, height: map.height, teams: teamCount)
        for (i, p) in setup.players.enumerated() {
            let team = teamIds.firstIndex(of: p.team) ?? 0
            players.append(Player(index: i, setup: p, team: team, crystals: setup.startCrystals))
        }

        for site in map.bases {
            for t in site.crystals where map.walkable(t.x, t.y) {
                let c = spawn(.crystal, owner: -1, at: map.center(t))
                c.amount = Defs.crystalAmount
                c.origin = t
                map.setOccupant(origin: t, size: 1, id: c.id)
            }
        }
        for b in map.beacons { _ = spawn(.beacon, owner: -1, at: map.center(b)) }

        let starts = map.starts
        for p in players {
            let site = starts[p.index % starts.count]
            let hq = placeBuilding(.hq, owner: p.index, origin: site.hqOrigin, complete: true)
            let toCrystals = site.crystals.isEmpty ? Vec2(1, 0) :
                (map.center(site.crystals[site.crystals.count / 2]) - hq.pos).normalized()
            for k in 0..<5 {
                let side = toCrystals.perp * (Double(k - 2) * 22)
                let pos = hq.pos + toCrystals * 70 + side
                let w = spawn(.worker, owner: p.index, at: map.walkable(at: pos) ? pos : hq.pos + toCrystals * 60)
                if let c = nearestCrystal(to: w.pos, within: 400) { w.order = .gather(c.id) }
            }
        }
        recomputePlayers()
        for p in players where p.isBot {
            let ps = setup.players[p.index]
            let personality = ps.personality ?? Personality(rawValue: rng.int(Personality.allCases.count)) ?? .balanced
            if p.difficulty == .brutal { p.gatherMultiplier = 1.3 }
            bots.append(Bot(world: self, player: p.index, difficulty: p.difficulty, personality: personality))
        }
        fog.update(self)
    }

    // MARK: lookup

    func entity(_ id: Int) -> Entity? {
        guard id != 0, let e = byId[id], e.alive else { return nil }
        return e
    }

    func enemies(_ a: Int, _ b: Int) -> Bool { a >= 0 && b >= 0 && a != b }

    func nearestCrystal(to p: Vec2, within r: Double, preferFree: Bool = false) -> Entity? {
        var best: Entity?
        var bestScore = Double.infinity
        for e in entities where e.type == .crystal && e.alive {
            let d = e.pos.dist(p)
            if d > r { continue }
            let score = d + (preferFree ? Double(e.assigned) * 60 : 0)
            if score < bestScore { bestScore = score; best = e }
        }
        return best
    }

    func nearestDropoff(for e: Entity) -> Entity? {
        var best: Entity?
        var bestD = Double.infinity
        for b in entities where b.type == .hq && b.owner == e.owner && b.alive && b.isComplete {
            let d = b.pos.distSq(e.pos)
            if d < bestD { bestD = d; best = b }
        }
        return best
    }

    func canSee(team: Int, _ e: Entity) -> Bool {
        if e.team == team { return true }
        return fog.visible(team: team, e.pos)
    }

    // MARK: spawning

    @discardableResult
    func spawn(_ type: EntityType, owner: Int, at pos: Vec2) -> Entity {
        let team = owner >= 0 ? players[owner].team : -1
        let e = Entity(id: nextId, type: type, owner: owner, team: team, pos: pos)
        nextId += 1
        entities.append(e)
        byId[e.id] = e
        if owner >= 0 && type.isUnit { e.dir = (Vec2(map.worldWidth / 2, map.worldHeight / 2) - pos).normalized() }
        if e.dir == .zero { e.dir = Vec2(1, 0) }
        e.aimDir = e.dir
        return e
    }

    @discardableResult
    func placeBuilding(_ type: EntityType, owner: Int, origin: TilePoint, complete: Bool) -> Entity {
        let n = type.stats.footprint
        let pos = Vec2((Double(origin.x) + Double(n) / 2) * Defs.tile, (Double(origin.y) + Double(n) / 2) * Defs.tile)
        let b = spawn(type, owner: owner, at: pos)
        b.origin = origin
        map.setOccupant(origin: origin, size: n, id: b.id)
        if complete {
            b.progress = 1
        } else {
            b.progress = 0
            b.hp = b.maxHp * 0.1
        }
        return b
    }

    /// Placement check used by the UI and the bots.
    func canPlace(_ type: EntityType, at origin: TilePoint, ignoring: Int = 0) -> Bool {
        let n = type.stats.footprint
        guard map.canPlace(origin: origin, size: n) else { return false }
        // keep Command Centers off the crystals' doorstep, and nothing right on top of a crystal line
        let lo = Vec2(Double(origin.x) * Defs.tile, Double(origin.y) * Defs.tile)
        let hi = lo + Vec2(Double(n) * Defs.tile, Double(n) * Defs.tile)
        let margin: Double = type == .hq ? 2.5 * Defs.tile : 0.6 * Defs.tile
        var blocked = false
        let c = (lo + hi) / 2
        grid.query(c, Double(n) * Defs.tile * 0.75 + margin + 20) { e in
            if e.type == .crystal && e.pos.x > lo.x - margin && e.pos.x < hi.x + margin &&
                e.pos.y > lo.y - margin && e.pos.y < hi.y + margin { blocked = true }
        }
        return !blocked
    }

    func requirementsMet(_ t: EntityType, player p: Player) -> Bool {
        let s = t.stats
        if let r = s.requires, p.count(r) == 0 { return false }
        if let u = s.requiresUpgrade, !p.has(u) { return false }
        return true
    }

    func canResearch(_ u: Upgrade, player p: Player) -> Bool {
        if p.has(u) || p.researching[u.rawValue] { return false }
        if let r = u.info.requires, !p.has(r) { return false }
        if let b = u.info.requiresBuilding, p.count(b) == 0 { return false }
        return true
    }

    // MARK: commands

    func apply(_ c: Command) {
        guard c.player >= 0, c.player < players.count, !players[c.player].defeated, !isOver else { return }
        let p = players[c.player]
        var seen = Set<Int>()
        let units = c.units.compactMap { id -> Entity? in
            guard seen.insert(id).inserted, let e = entity(id), e.owner == c.player else { return nil }
            return e
        }
        switch c.action {
        case .surrender:
            defeat(p)
        case let .move(pt), let .attackMove(pt):
            let attack: Bool
            if case .attackMove = c.action { attack = true } else { attack = false }
            let movers = units.filter { $0.isUnit }
            let offsets = formation(movers, to: pt)
            for (k, u) in movers.enumerated() {
                var goal = pt + offsets[k]
                if !u.isAir && !map.walkable(at: goal) { goal = pt }
                goal = clampToMap(goal)
                u.order = attack ? .attackMove(goal) : .move(goal)
                resetMove(u)
            }
            for b in units where b.isBuilding && !b.st.produces.isEmpty {
                b.rally = pt
                b.rallyTarget = 0
            }
        case let .attack(tid):
            guard let t = entity(tid) else { return }
            for u in units where u.isUnit {
                if t.type == .crystal && u.isWorker {
                    u.order = .gather(t.id)
                } else if canHit(u, t) && u.type != .mender {
                    u.order = .attack(t.id)
                } else {
                    u.order = .move(t.pos)
                }
                resetMove(u)
            }
        case let .gather(cid):
            guard let t = entity(cid) else { return }
            for u in units where u.isUnit {
                if u.isWorker {
                    if t.type == .crystal {
                        u.order = .gather(t.id)
                        u.gatherTimer = 0
                    } else if t.type == .hq && t.owner == u.owner && u.cargo > 0 {
                        u.order = .returnCargo
                    } else if t.isBuilding && t.owner == u.owner && !t.isComplete {
                        u.order = .construct(t.id)
                    } else {
                        u.order = .move(t.pos)
                    }
                } else {
                    u.order = .move(t.pos)
                }
                resetMove(u)
            }
            for b in units where b.isBuilding && !b.st.produces.isEmpty {
                b.rally = t.pos
                b.rallyTarget = t.type == .crystal ? t.id : 0
            }
        case .stop:
            for u in units where u.isUnit { u.order = .idle; resetMove(u); u.target = 0 }
        case .hold:
            for u in units where u.isUnit { u.order = .hold; resetMove(u) }
        case let .build(type, origin):
            guard type.isBuilding, requirementsMet(type, player: p) else { return }
            let center = Vec2((Double(origin.x) + Double(type.stats.footprint) / 2) * Defs.tile,
                              (Double(origin.y) + Double(type.stats.footprint) / 2) * Defs.tile)
            let workers = units.filter { $0.isWorker }
            guard let w = workers.min(by: { a, b in
                let da = a.pos.distSq(center), db = b.pos.distSq(center)
                return da < db || (da == db && a.id < b.id)
            }) else { return }
            w.order = .build(type, origin)
            resetMove(w)
        case let .train(t):
            guard t.isUnit, let prod = t.stats.producedAt else { return }
            let cands = units.filter { $0.type == prod && $0.isComplete && $0.queue.count < Defs.queueLimit }
            guard let b = cands.min(by: { a, b in a.queue.count < b.queue.count || (a.queue.count == b.queue.count && a.id < b.id) }) else { return }
            guard requirementsMet(t, player: p) else { return }
            if p.crystals < t.stats.cost { events.append(.notEnough(player: p.index, what: "crystals")); return }
            if p.supplyUsed + t.stats.supply > p.supplyCap {
                events.append(.notEnough(player: p.index, what: p.supplyCap >= Defs.maxSupply ? "max supply" : "supply"))
                return
            }
            p.crystals -= t.stats.cost
            b.queue.append(.unit(t))
            p.supplyUsed += t.stats.supply
            p.pending[t.rawValue] += 1
        case let .research(u):
            guard let b = units.first(where: { $0.type == .lab && $0.isComplete && $0.queue.count < Defs.queueLimit }),
                  canResearch(u, player: p) else { return }
            if p.crystals < u.info.cost { events.append(.notEnough(player: p.index, what: "crystals")); return }
            p.crystals -= u.info.cost
            p.researching[u.rawValue] = true
            b.queue.append(.research(u))
        case .cancel:
            guard let b = units.first(where: { $0.isBuilding }) else { return }
            if !b.isComplete {
                p.crystals += b.st.cost * 3 / 4
                b.hp = 0
            } else if let last = b.queue.popLast() {
                p.crystals += last.cost
                if case let .research(u) = last { p.researching[u.rawValue] = false }
                if b.queue.isEmpty { b.queueProgress = 0 }
            }
        case let .rally(pt):
            for b in units where b.isBuilding && !b.st.produces.isEmpty {
                b.rally = pt
                b.rallyTarget = 0
            }
        case .siege, .unsiege:
            let want: Bool
            if case .siege = c.action { want = true } else { want = false }
            guard p.has(.siegeMode) else { return }
            for u in units where u.type == .tank && u.sieged != want && u.siegeTimer <= 0 {
                u.siegeTimer = Defs.siegeTransition
                u.vel = .zero
                u.path = []
                if want, case .move = u.order { u.order = .idle }
            }
        case .sprint:
            guard p.has(.sprint) else { return }
            for u in units where (u.type == .trooper || u.type == .lancer) && u.sprintCooldown <= 0 {
                u.sprintTime = Defs.sprintDuration
                u.sprintCooldown = Defs.sprintCooldown
                u.hp = max(1, u.hp - 10)
            }
        }
    }

    private func resetMove(_ u: Entity) {
        u.path = []
        u.pathGoal = nil
        u.arrived = false
        u.progressCheckTick = tick
        u.progressCheckPos = u.pos
        if case .attack = u.order {} else { u.target = 0 }
    }

    /// Keep the group's shape (compressed) so units do not all fight over one point.
    private func formation(_ units: [Entity], to pt: Vec2) -> [Vec2] {
        guard units.count > 1 else { return units.map { _ in .zero } }
        var c = Vec2.zero
        for u in units { c += u.pos }
        c = c / Double(units.count)
        let maxR = 13 * Double(units.count).squareRoot() + 10
        var spread: Double = 1
        for u in units { spread = max(spread, u.pos.dist(c)) }
        let k = min(1, maxR / spread)
        return units.map { ($0.pos - c) * k }
    }

    func clampToMap(_ p: Vec2) -> Vec2 {
        Vec2(min(max(p.x, 20), map.worldWidth - 20), min(max(p.y, 20), map.worldHeight - 20))
    }

    // MARK: the tick

    func step(_ commands: [Command]) {
        guard !isOver else { return }
        for c in commands { apply(c) }
        for b in bots where (tick + b.phase) % b.interval == 0 { b.think() }

        grid.rebuild(entities)
        for e in entities where e.type == .crystal { e.assigned = 0 }
        for e in entities where e.isWorker && e.alive {
            if case let .gather(cid) = e.order, let c = byId[cid] { c.assigned += 1 }
        }
        for e in entities where e.alive {
            e.prevPos = e.pos
            if e.isUnit {
                updateUnit(e)
            } else if e.isBuilding {
                updateBuilding(e)
            } else if e.type == .beacon {
                updateBeacon(e)
            }
        }
        moveUnits()
        removeDead()
        recomputePlayers()
        if tick % 4 == 0 { fog.update(self) }
        if tick % 10 == 0 { checkDefeat() }
        if events.count > 4000 { events.removeFirst(2000) }
        tick += 1
    }

    // MARK: units

    private func updateUnit(_ e: Entity) {
        e.cooldown -= dt
        if e.sprintTime > 0 { e.sprintTime -= dt }
        if e.sprintCooldown > 0 { e.sprintCooldown -= dt }
        e.vel = .zero
        if e.siegeTimer > 0 {
            e.siegeTimer -= dt
            if e.siegeTimer <= 0 { e.sieged.toggle() }
            return
        }
        if e.type == .mender { updateMender(e); return }

        switch e.order {
        case .idle:
            if e.isArmy, let t = acquire(e, radius: e.st.sight * 0.9) {
                e.order = .attackMove(e.pos)
                e.target = t.id
                engage(e, t)
            }
            if e.sieged, let t = acquire(e, radius: effectiveRange(e)) { engage(e, t) }
        case .hold:
            if let t = currentTarget(e, maxGap: effectiveRange(e)) ?? acquire(e, radius: effectiveRange(e)) {
                e.target = t.id
                engage(e, t, mayMove: false)
            }
        case let .move(p):
            if e.sieged { e.order = .idle; break }
            if moveTo(e, p) { e.order = .idle }
        case let .attackMove(p):
            if let t = currentTarget(e, maxGap: e.st.sight * 1.1) ?? acquire(e, radius: e.sieged ? effectiveRange(e) : e.st.sight * 0.9) {
                e.target = t.id
                engage(e, t)
            } else {
                e.target = 0
                if e.sieged { break }
                if moveTo(e, p) { e.order = .idle }
            }
        case let .attack(tid):
            guard let t = entity(tid), canSee(team: e.team, t) || t.isBuilding else { e.order = .idle; e.target = 0; break }
            e.target = t.id
            engage(e, t)
        case let .gather(cid):
            updateGather(e, cid)
        case .returnCargo:
            updateReturn(e)
        case let .build(type, origin):
            updateBuild(e, type, origin)
        case let .construct(bid):
            updateConstruct(e, bid)
        }
    }

    private func currentTarget(_ e: Entity, maxGap: Double) -> Entity? {
        guard let t = entity(e.target), enemies(e.team, t.team), canHit(e, t), canSee(team: e.team, t),
              e.gap(to: t) <= maxGap else { return nil }
        if e.sieged && e.gap(to: t) < Defs.siegeMinRange { return nil }
        return t
    }

    func canHit(_ e: Entity, _ t: Entity) -> Bool {
        if t.type.isNeutral || !enemies(e.team, t.team) { return false }
        if e.st.damage <= 0 || e.type == .mender { return false }
        if t.isAir { return e.st.hitsAir && !e.sieged }
        return e.st.hitsGround
    }

    func effectiveRange(_ e: Entity) -> Double { e.sieged ? Defs.siegeRange : e.st.range }

    /// Best enemy to shoot within `radius` (gap distance). Prefers things that shoot back, then units, then buildings.
    func acquire(_ e: Entity, radius: Double) -> Entity? {
        var best: Entity?
        var bestScore = Double.infinity
        grid.query(e.pos, radius + 20) { t in
            guard canHit(e, t), t.owner >= 0 else { return }
            let gap = e.gap(to: t)
            if gap > radius { return }
            if e.sieged && gap < Defs.siegeMinRange { return }
            guard fog.visible(team: e.team, t.pos) else { return }
            var score = gap
            if t.st.damage > 0 && t.type != .worker { score -= 220 }
            else if t.isUnit { score -= 120 }
            if t.isBuilding && !t.isComplete { score += 40 }
            if score < bestScore || (score == bestScore && t.id < (best?.id ?? Int.max)) {
                bestScore = score
                best = t
            }
        }
        return best
    }

    private func engage(_ e: Entity, _ t: Entity, mayMove: Bool = true) {
        let gap = e.gap(to: t)
        let range = effectiveRange(e)
        let toT = (t.pos - e.pos).normalized()
        if gap <= range {
            if e.sieged && gap < Defs.siegeMinRange { e.target = 0; return }
            e.aimDir = toT == .zero ? e.aimDir : toT
            if e.type != .tank && e.type != .gunship { e.dir = e.aimDir }
            if e.type == .gunship { e.dir = e.aimDir }
            if e.cooldown <= 0 { fire(e, t) }
        } else if mayMove && !e.sieged {
            _ = moveTo(e, t.pos, arrive: 0)
        } else {
            e.target = 0
        }
    }

    private func fire(_ e: Entity, _ t: Entity) {
        let owner = players[e.owner]
        var dmg = e.sieged ? Defs.siegeDamage : e.st.damage
        if let b = e.st.bonusVs, b == t.st.armorClass { dmg += e.st.bonusDamage }
        dmg *= 1 + 0.15 * Double(owner.weaponsLevel)
        if e.kills >= 10 { dmg *= 1.2 } else if e.kills >= 4 { dmg *= 1.1 }
        let armor = t.st.armor + (t.isUnit && t.owner >= 0 ? Double(players[t.owner].platingLevel) : 0)
        let final = max(0.5, dmg - armor)
        damage(t, final, by: e)
        let splash = e.sieged ? Defs.siegeSplash : e.st.splash
        if splash > 0 {
            grid.query(t.pos, splash) { o in
                guard o !== t, o.alive, o.owner >= 0, !o.type.isNeutral, enemies(e.team, o.team), o.isAir == t.isAir else { return }
                damage(o, final * 0.5, by: e)
            }
        }
        var cd = e.sieged ? Defs.siegeCooldown : e.st.cooldown
        if e.sprintTime > 0 { cd /= 1.3 }
        e.cooldown = cd
        e.lastShotTick = tick
        events.append(.shot(from: e.id, to: t.pos, style: e.st.weapon, fromPos: e.pos))
    }

    private func damage(_ t: Entity, _ amount: Double, by e: Entity) {
        guard t.alive else { return }
        t.hp -= amount
        t.lastHitTick = tick
        t.lastAttackerTeam = e.team
        if t.owner >= 0 {
            let p = players[t.owner]
            if tick - p.lastAlertTick > 200 {
                p.lastAlertTick = tick
                events.append(.underAttack(player: p.index, at: t.pos))
            }
            // idle units and workers hit by something they can shoot fight back
            if t.isArmy, t.order == .idle, canHit(t, e) { t.order = .attackMove(t.pos); t.target = e.id }
        }
        if t.hp <= 0 {
            e.kills += 1
            if e.owner >= 0 { players[e.owner].kills += 1 }
        }
    }

    private func updateMender(_ e: Entity) {
        // heal the most hurt friendly infantry in range, otherwise follow orders
        var best: Entity?
        var bestMissing = 0.5
        grid.query(e.pos, e.st.range) { o in
            guard o.team == e.team, o.isUnit, o.st.isBio, o.alive else { return }
            let missing = o.maxHp - o.hp
            if missing > bestMissing { bestMissing = missing; best = o }
        }
        if let t = best {
            if e.cooldown <= 0 {
                t.hp = min(t.maxHp, t.hp + e.st.damage)
                e.cooldown = e.st.cooldown
                e.lastShotTick = tick
                events.append(.shot(from: e.id, to: t.pos, style: .heal, fromPos: e.pos))
            }
            if t !== e { e.dir = (t.pos - e.pos).normalized() == .zero ? e.dir : (t.pos - e.pos).normalized() }
            if case .attackMove = e.order { return }   // stay and heal
        }
        switch e.order {
        case let .move(p), let .attackMove(p):
            if moveTo(e, p) { e.order = .idle }
        case let .attack(tid):
            if let t = entity(tid) { _ = moveTo(e, t.pos, arrive: 60) } else { e.order = .idle }
        default:
            break
        }
    }

    // MARK: workers

    private func reach(_ e: Entity, _ b: Entity) -> Double {
        // gap between a unit and a building/crystal footprint (a square), or a circle for anything else
        let n = b.st.footprint
        if n == 0 { return e.gap(to: b) }
        let half = Double(n) * Defs.tile / 2
        let dx = max(0, abs(e.pos.x - b.pos.x) - half)
        let dy = max(0, abs(e.pos.y - b.pos.y) - half)
        return max(0, (dx * dx + dy * dy).squareRoot() - e.st.radius)
    }

    private func approach(_ e: Entity, _ b: Entity) -> Vec2 {
        let n = b.st.footprint
        if n == 0 { return b.pos }
        let half = Double(n) * Defs.tile / 2
        let cx = min(max(e.pos.x, b.pos.x - half), b.pos.x + half)
        let cy = min(max(e.pos.y, b.pos.y - half), b.pos.y + half)
        let edge = Vec2(cx, cy)
        var out = (e.pos - edge).normalized()
        if out == .zero { out = (e.pos - b.pos).normalized() }
        if out == .zero { out = Vec2(0, -1) }
        return edge + out * (e.st.radius + 5)
    }

    private func updateGather(_ e: Entity, _ cid: Int) {
        if e.cargo >= Defs.carry { e.order = .returnCargo; return }
        guard var c = entity(cid), c.type == .crystal else {
            if let n = nearestCrystal(to: e.pos, within: 500, preferFree: true) {
                e.order = .gather(n.id)
            } else {
                e.order = e.cargo > 0 ? .returnCargo : .idle
            }
            return
        }
        // spread out: if this crystal is crowded and we have not started, pick a quieter one nearby
        if c.assigned > 2 && e.gatherTimer == 0, let alt = nearestCrystal(to: c.pos, within: 140, preferFree: true),
           alt.assigned + 1 < c.assigned {
            c.assigned -= 1
            alt.assigned += 1
            e.order = .gather(alt.id)
            c = alt
        }
        if reach(e, c) > 12 {
            e.gatherTimer = 0
            _ = moveTo(e, approach(e, c), arrive: 3)
            return
        }
        e.dir = (c.pos - e.pos).normalized() == .zero ? e.dir : (c.pos - e.pos).normalized()
        e.gatherTimer += dt
        e.lastShotTick = tick
        if e.gatherTimer >= Defs.gatherTime {
            let take = min(Defs.carry, c.amount)
            c.amount -= take
            e.cargo = take
            e.gatherTimer = 0
            e.lastCrystal = c.id
            if c.amount <= 0 { c.hp = 0 }
            e.order = .returnCargo
        }
    }

    private func updateReturn(_ e: Entity) {
        guard e.cargo > 0 else { e.order = e.lastCrystal != 0 ? .gather(e.lastCrystal) : .idle; return }
        guard let hq = nearestDropoff(for: e) else { e.order = .idle; return }
        if reach(e, hq) <= 12 {
            let p = players[e.owner]
            let amount = Double(e.cargo) * p.gatherMultiplier + p.crystalFrac
            let whole = Int(amount)
            p.crystalFrac = amount - Double(whole)
            p.crystals += whole
            p.gathered += whole
            e.cargo = 0
            e.order = .gather(e.lastCrystal)
            return
        }
        _ = moveTo(e, approach(e, hq), arrive: 3)
    }

    private func updateBuild(_ e: Entity, _ type: EntityType, _ origin: TilePoint) {
        let n = type.stats.footprint
        let half = Double(n) * Defs.tile / 2
        let center = Vec2(Double(origin.x) * Defs.tile + half, Double(origin.y) * Defs.tile + half)
        let dx = max(0, abs(e.pos.x - center.x) - half), dy = max(0, abs(e.pos.y - center.y) - half)
        let gap = (dx * dx + dy * dy).squareRoot() - e.st.radius
        if gap > 14 {
            // walk to the near edge of the footprint
            let cx = min(max(e.pos.x, center.x - half), center.x + half)
            let cy = min(max(e.pos.y, center.y - half), center.y + half)
            var out = (e.pos - Vec2(cx, cy)).normalized()
            if out == .zero { out = Vec2(0, -1) }
            if moveTo(e, Vec2(cx, cy) + out * (e.st.radius + 6), arrive: 4) && gap > 40 { e.order = .idle }
            return
        }
        let p = players[e.owner]
        guard requirementsMet(type, player: p), canPlace(type, at: origin) else {
            events.append(.notEnough(player: p.index, what: "room to build"))
            e.order = .idle
            return
        }
        guard p.crystals >= type.stats.cost else {
            events.append(.notEnough(player: p.index, what: "crystals"))
            e.order = .idle
            return
        }
        p.crystals -= type.stats.cost
        let b = placeBuilding(type, owner: e.owner, origin: origin, complete: false)
        e.order = .construct(b.id)
        resetMove(e)
    }

    private func updateConstruct(_ e: Entity, _ bid: Int) {
        guard let b = entity(bid), b.isBuilding, b.owner == e.owner else { e.order = .idle; return }
        if b.isComplete {
            if let c = nearestCrystal(to: e.pos, within: 350, preferFree: true) { e.order = .gather(c.id) } else { e.order = .idle }
            return
        }
        if reach(e, b) > 14 {
            _ = moveTo(e, approach(e, b), arrive: 3)
            return
        }
        e.dir = (b.pos - e.pos).normalized() == .zero ? e.dir : (b.pos - e.pos).normalized()
        e.lastShotTick = tick
        let step = dt / b.st.buildTime
        b.progress = min(1, b.progress + step)
        b.hp = min(b.maxHp, b.hp + b.maxHp * 0.9 * step)
        if b.isComplete {
            players[b.owner].buildingsMade += 1
            events.append(.completed(b))
        }
    }

    // MARK: movement

    /// Steers toward `goal` along a path. Returns true on arrival.
    @discardableResult
    private func moveTo(_ e: Entity, _ goal: Vec2, arrive: Double = 6) -> Bool {
        if e.sieged || e.siegeTimer > 0 { return false }
        let d = e.pos.dist(goal)
        if d <= max(arrive, 2) {
            e.path = []
            e.pathGoal = nil
            return true
        }
        var speed = e.st.speed
        if e.sprintTime > 0 { speed *= 1.5 }
        if e.isAir {
            e.vel = (goal - e.pos) / d * min(speed, d / dt)
            e.dir = (e.dir * 0.7 + (goal - e.pos) / d * 0.3).normalized()
            return false
        }
        if e.pathGoal == nil || e.pathGoal!.distSq(goal) > 28 * 28 || tick >= e.repathTick {
            if let p = pathfinder.path(from: e.pos, to: goal, tick: tick, halfWidth: max(4, e.st.radius - 3)) {
                e.path = p
                e.pathGoal = goal
                e.repathTick = tick + 60 + e.id % 23
            } else {
                // over the search budget this tick: keep going (old path or straight) and retry shortly
                if e.path.isEmpty { e.path = [goal] }
                e.repathTick = tick + 1 + e.id % 4
                if e.pathGoal == nil || e.pathGoal!.distSq(goal) > 28 * 28 { e.pathGoal = nil }
            }
            if e.progressCheckTick < tick - 40 { e.progressCheckTick = tick; e.progressCheckPos = e.pos }
        }
        while e.path.count > 1 && e.pos.distSq(e.path[0]) < 14 * 14 { e.path.removeFirst() }
        guard let wp = e.path.first else { return true }
        if e.path.count == 1 && e.pos.dist(wp) <= max(arrive, 3) {
            e.path = []
            e.pathGoal = nil
            return true
        }
        // stuck or crowded at the goal?
        if tick - e.progressCheckTick >= 24 {
            let moved = e.pos.dist(e.progressCheckPos)
            e.progressCheckTick = tick
            e.progressCheckPos = e.pos
            if moved < 8 {
                if d < 30 + 4 * e.st.radius { e.path = []; e.pathGoal = nil; return true }
                e.repathTick = tick
            }
        }
        let to = wp - e.pos
        let len = to.length
        if len > 0.001 {
            let v = to / len * min(speed, len / dt)
            e.vel = v
            let nd = (e.dir * 0.65 + v.normalized() * 0.35).normalized()
            if nd != .zero { e.dir = nd }
        }
        return false
    }

    private func isGhost(_ e: Entity) -> Bool {
        guard e.isWorker else { return false }
        switch e.order {
        case .gather, .returnCargo: return true
        default: return false
        }
    }

    private func moveUnits() {
        for e in entities where e.isUnit && e.alive && e.vel != .zero {
            e.pos += e.vel * dt
        }
        // push overlapping units apart (standing units give way to moving ones)
        for e in entities where e.isUnit && e.alive {
            let ghost = isGhost(e)
            grid.query(e.pos, e.st.radius + 2) { o in
                guard o.id > e.id, o.isUnit, o.isAir == e.isAir else { return }
                if ghost || isGhost(o) { return }
                let d = o.pos - e.pos
                let dist = d.length
                let minD = e.st.radius + o.st.radius
                guard dist < minD else { return }
                let n = dist > 0.01 ? d / dist : Vec2(Double(o.id % 7) - 3, Double(e.id % 5) - 2).normalized()
                let overlap = (minD - dist) * (e.isAir ? 0.25 : 0.5)
                let eMoving = e.vel != .zero, oMoving = o.vel != .zero
                var we = 0.5, wo = 0.5
                if eMoving && !oMoving { we = 0.2; wo = 0.8 }
                if oMoving && !eMoving { we = 0.8; wo = 0.2 }
                if e.sieged || e.type == .tank && !eMoving && o.type != .tank { we = 0; wo = 1 }
                if o.sieged || o.type == .tank && !oMoving && e.type != .tank { we = 1; wo = 0 }
                if e.sieged && o.sieged { we = 0; wo = 0 }
                e.pos -= n * (overlap * we)
                o.pos += n * (overlap * wo)
            }
        }
        for e in entities where e.isUnit && e.alive && !e.isAir {
            resolveTerrain(e)
        }
        for e in entities where e.isUnit && e.alive {
            e.pos = clampToMap(e.pos)
        }
    }

    private func resolveTerrain(_ e: Entity) {
        var t = map.tile(of: e.pos)
        if !map.walkable(t.x, t.y) {
            guard let w = map.nearestWalkable(t, maxRadius: 6) else { return }
            let c = map.center(w)
            let h = Defs.tile / 2 - 1
            e.pos = Vec2(min(max(e.pos.x, c.x - h), c.x + h), min(max(e.pos.y, c.y - h), c.y + h))
            t = w
        }
        let r = e.st.radius * 0.8
        for dy in -1...1 {
            for dx in -1...1 where dx != 0 || dy != 0 {
                let x = t.x + dx, y = t.y + dy
                if map.walkable(x, y) { continue }
                let lo = Vec2(Double(x) * Defs.tile, Double(y) * Defs.tile)
                let cx = min(max(e.pos.x, lo.x), lo.x + Defs.tile)
                let cy = min(max(e.pos.y, lo.y), lo.y + Defs.tile)
                let d = e.pos - Vec2(cx, cy)
                let dist = d.length
                if dist < r && dist > 0.001 {
                    e.pos += d / dist * (r - dist)
                }
            }
        }
    }

    // MARK: buildings and beacons

    private func updateBuilding(_ b: Entity) {
        guard b.isComplete else { return }
        b.cooldown -= dt
        if b.type == .turret {
            if let t = currentTarget(b, maxGap: b.st.range) ?? acquire(b, radius: b.st.range) {
                b.target = t.id
                let toT = (t.pos - b.pos).normalized()
                if toT != .zero { b.aimDir = toT }
                if b.cooldown <= 0 { fire(b, t) }
            } else {
                b.target = 0
            }
            return
        }
        guard let item = b.queue.first else { return }
        b.queueProgress += dt
        guard b.queueProgress >= item.time else { return }
        let p = players[b.owner]
        switch item {
        case let .unit(t):
            b.queue.removeFirst()
            b.queueProgress = 0
            p.pending[t.rawValue] = max(0, p.pending[t.rawValue] - 1)
            let u = spawn(t, owner: b.owner, at: exitPoint(of: b, size: t.stats.radius))
            p.unitsMade += 1
            if let rt = entity(b.rallyTarget), rt.type == .crystal, u.isWorker {
                u.order = .gather(rt.id)
            } else if let r = b.rally {
                u.order = .move(r)
            } else if u.isWorker, let c = nearestCrystal(to: u.pos, within: 400, preferFree: true) {
                u.order = .gather(c.id)
            }
            events.append(.trained(u))
        case let .research(up):
            b.queue.removeFirst()
            b.queueProgress = 0
            p.upgrades[up.rawValue] = true
            p.researching[up.rawValue] = false
            events.append(.researched(player: p.index, up))
        }
    }

    private func exitPoint(of b: Entity, size: Double) -> Vec2 {
        let n = b.st.footprint
        let toward = b.rally ?? Vec2(map.worldWidth / 2, map.worldHeight / 2)
        var best = b.pos + Vec2(0, -Double(n) * Defs.tile)
        var bestD = Double.infinity
        for ring in 0..<3 {
            let lo = TilePoint(x: b.origin.x - 1 - ring, y: b.origin.y - 1 - ring)
            let side = n + 2 + ring * 2
            for y in lo.y..<(lo.y + side) {
                for x in lo.x..<(lo.x + side) {
                    let onRing = x == lo.x || y == lo.y || x == lo.x + side - 1 || y == lo.y + side - 1
                    guard onRing, map.walkable(x, y) else { continue }
                    let c = map.center(TilePoint(x: x, y: y))
                    let d = c.distSq(toward)
                    if d < bestD { bestD = d; best = c }
                }
            }
            if bestD < .infinity { break }
        }
        return best
    }

    private func updateBeacon(_ b: Entity) {
        var present: [Int] = []
        var firstOwner: [Int: Int] = [:]
        grid.query(b.pos, Defs.beaconRadius) { u in
            guard u.isUnit, u.alive, u.owner >= 0 else { return }
            if !present.contains(u.team) { present.append(u.team) }
            if firstOwner[u.team] == nil { firstOwner[u.team] = u.owner }
        }
        let step = dt / Defs.beaconCaptureTime
        if present.count == 1 {
            let t = present[0]
            if b.team == t {
                b.captureProgress = 1
            } else if b.owner >= 0 {
                b.captureProgress -= step
                if b.captureProgress <= 0 {
                    b.owner = -1
                    b.team = -1
                    b.captureTeam = t
                    b.captureProgress = 0
                }
            } else {
                if b.captureTeam != t { b.captureTeam = t; b.captureProgress = 0 }
                b.captureProgress += step
                if b.captureProgress >= 1 {
                    b.captureProgress = 1
                    b.owner = firstOwner[t] ?? -1
                    b.team = t
                    events.append(.captured(beacon: b.id, team: t))
                }
            }
        } else if present.isEmpty && b.owner < 0 && b.captureProgress > 0 {
            b.captureProgress = max(0, b.captureProgress - step * 0.5)
        }
        if b.owner >= 0 {
            let p = players[b.owner]
            p.crystalFrac += Defs.beaconIncome * dt
            if p.crystalFrac >= 1 {
                let whole = Int(p.crystalFrac)
                p.crystals += whole
                p.gathered += whole
                p.crystalFrac -= Double(whole)
            }
        }
    }

    // MARK: bookkeeping

    private func removeDead() {
        var anyDead = false
        for e in entities where !e.alive {
            anyDead = true
            if e.isBuilding || e.type == .crystal {
                map.setOccupant(origin: e.origin, size: e.st.footprint, id: 0)
            }
            if e.isBuilding, e.owner >= 0 {
                for case let .unit(t) in e.queue {
                    players[e.owner].pending[t.rawValue] = max(0, players[e.owner].pending[t.rawValue] - 1)
                }
                for case let .research(u) in e.queue { players[e.owner].researching[u.rawValue] = false }
            }
            if e.isUnit && e.owner >= 0 { players[e.owner].unitsLost += 1 }
            events.append(.died(e))
            byId[e.id] = nil
        }
        if anyDead { entities.removeAll { !$0.alive } }
    }

    func recomputePlayers() {
        for p in players {
            p.supplyUsed = 0
            p.supplyCap = 0
            for i in 0..<p.counts.count { p.counts[i] = 0 }
        }
        for p in players {
            for i in 0..<p.pending.count where EntityType(rawValue: i)?.isBuilding == true { p.pending[i] = 0 }
        }
        for e in entities where e.owner >= 0 && e.alive && !e.type.isNeutral {
            let p = players[e.owner]
            if e.isUnit {
                p.supplyUsed += e.st.supply
                p.counts[e.type.rawValue] += 1
            } else if e.isBuilding {
                if e.isComplete {
                    p.counts[e.type.rawValue] += 1
                    p.supplyCap += e.st.supplyProvided
                } else {
                    p.pending[e.type.rawValue] += 1
                }
                for case let .unit(t) in e.queue { p.supplyUsed += t.stats.supply }
            }
            if e.isWorker, case let .build(t, _) = e.order { p.pending[t.rawValue] += 1 }
        }
        for p in players { p.supplyCap = min(Defs.maxSupply, p.supplyCap) }
    }

    private func defeat(_ p: Player) {
        guard !p.defeated else { return }
        p.defeated = true
        for e in entities where e.owner == p.index && !e.type.isNeutral { e.hp = 0 }
        events.append(.defeated(player: p.index))
    }

    private func checkDefeat() {
        var hasBuilding = Array(repeating: false, count: players.count)
        for e in entities where e.isBuilding && e.alive && e.owner >= 0 { hasBuilding[e.owner] = true }
        for p in players where !p.defeated && !hasBuilding[p.index] { defeat(p) }
        var aliveTeams: [Int] = []
        for p in players where !p.defeated && !aliveTeams.contains(p.team) { aliveTeams.append(p.team) }
        if aliveTeams.count <= 1 && teamCount > 1 { winningTeam = aliveTeams.first ?? -1 }
    }

    // MARK: sync

    /// Hash of the whole game state. Peers compare these to catch a desync.
    func checksum() -> UInt64 {
        var h = Hasher64()
        h.add(tick)
        h.add(rng.state)
        for e in entities {
            h.add(e.id)
            h.add(e.type.rawValue)
            h.add(e.owner)
            h.add(e.pos)
            h.add(e.hp)
            h.add(e.cargo)
            h.add(e.progress)
            h.add(e.queue.count)
            h.add(e.amount)
        }
        for p in players {
            h.add(p.crystals)
            h.add(p.supplyUsed)
            h.add(p.defeated)
        }
        return h.value
    }
}
