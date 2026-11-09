import Foundation

enum Order: Equatable {
    case idle
    case move(Vec2)
    case attackMove(Vec2)
    case attack(Int)
    case gather(Int)
    case returnCargo
    case build(EntityType, TilePoint)
    case construct(Int)
    case repair(Int)
    case hold
}

enum ProdItem: Equatable, Codable {
    case unit(EntityType)
    case research(Upgrade)
    case spec(Spec)

    var time: Double {
        switch self {
        case let .unit(t): return t.stats.buildTime
        case let .research(u): return u.info.time
        case let .spec(s): return s.info.time
        }
    }
    var cost: Int {
        switch self {
        case let .unit(t): return t.stats.cost
        case let .research(u): return u.info.cost
        case let .spec(s): return s.info.cost
        }
    }
}

final class Entity {
    let id: Int
    let type: EntityType
    let st: Stats
    var owner: Int                  // player index, -1 = neutral
    var team: Int
    var pos: Vec2
    var prevPos: Vec2
    var dir = Vec2(1, 0)            // facing (unit vector)
    var aimDir = Vec2(1, 0)         // tank and turret gun
    var hp: Double
    var vel = Vec2.zero

    // orders and movement
    var order: Order = .idle
    var path: [Vec2] = []
    var pathGoal: Vec2?
    var repathTick = 0
    var moveGoal: Vec2?             // where the unit is walking right now (nil = standing)
    var progressCheckPos = Vec2.zero
    var progressCheckTick = 0
    var arrived = false
    var formationOffset = Vec2.zero

    // combat
    var target: Int = 0
    var cooldown: Double = 0
    var lastShotTick = -1000
    var lastHitTick = -1000
    var lastAttackerTeam = -1
    var kills = 0

    // workers
    var cargo = 0
    var gatherTimer: Double = 0
    var lastCrystal = 0

    // buildings
    var origin = TilePoint(x: 0, y: 0)
    var progress: Double = 1        // construction, 0...1
    var queue: [ProdItem] = []
    var queueProgress: Double = 0
    var rally: Vec2?
    var rallyTarget = 0

    // neutral objects
    var amount = 0                  // crystals left
    var captureTeam = -1            // beacon: team making progress
    var captureProgress: Double = 0
    var assigned = 0                // crystals: workers mining it (recomputed each tick)
    var rich = false                // violet crystals: more per trip

    // specialization and per-unit bonuses
    var spec: Spec?
    var bonusHp: Double = 0
    var bonusArmor: Double = 0

    // abilities
    var sieged = false
    var siegeTimer: Double = 0      // >0 while switching
    var sprintTime: Double = 0
    var sprintCooldown: Double = 0

    init(id: Int, type: EntityType, owner: Int, team: Int, pos: Vec2) {
        self.id = id
        self.type = type
        self.st = type.stats
        self.owner = owner
        self.team = team
        self.pos = pos
        self.prevPos = pos
        self.hp = type.stats.hp
    }

    var alive: Bool { hp > 0 }
    var isUnit: Bool { type.isUnit }
    var isBuilding: Bool { type.isBuilding }
    var isComplete: Bool { progress >= 1 }
    var isAir: Bool { st.isAir }
    var maxHp: Double { st.hp + bonusHp }
    var isWorker: Bool { type == .worker }
    var isArmy: Bool { type.isUnit && type != .worker }

    /// Distance from my center to the edge of `o`.
    func gap(to o: Entity) -> Double { max(0, pos.dist(o.pos) - o.st.radius - st.radius) }
}

/// A player's order. Everything the players (and bots) do goes through these, so a match is fully described by its
/// setup and its command list; that is what multiplayer sends over the network.
enum Action: Codable, Equatable {
    case move(Vec2)
    case attackMove(Vec2)
    case attack(Int)
    case gather(Int)
    case repair(Int)
    case specialize(Spec)
    case stop
    case hold
    case build(EntityType, TilePoint)
    case train(EntityType)
    case research(Upgrade)
    case cancel
    case rally(Vec2)
    case siege
    case unsiege
    case sprint
    case surrender
}

struct Command: Codable, Equatable {
    var player: Int
    var units: [Int]
    var action: Action
}

/// Things that happened during a tick, for sound and effects. Not part of the game state.
enum GameEvent {
    case shot(from: Int, to: Vec2, style: WeaponStyle, fromPos: Vec2)
    case died(Entity)
    case completed(Entity)
    case trained(Entity)
    case researched(player: Int, Upgrade)
    case captured(beacon: Int, team: Int)
    case underAttack(player: Int, at: Vec2)
    case defeated(player: Int)
    case notEnough(player: Int, what: String)
}
