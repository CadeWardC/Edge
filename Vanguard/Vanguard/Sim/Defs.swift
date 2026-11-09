import Foundation

/// Everything in the game: units, buildings and neutral map objects.
enum EntityType: Int, Codable, CaseIterable {
    // units
    case worker, trooper, lancer, mender, skimmer, tank, gunship
    // buildings
    case hq, depot, barracks, factory, lab, turret, radar, shield
    // neutral
    case crystal, beacon, tower

    var isUnit: Bool { rawValue <= EntityType.gunship.rawValue }
    var isBuilding: Bool { rawValue >= EntityType.hq.rawValue && rawValue <= EntityType.shield.rawValue }
    var isNeutral: Bool { self == .crystal || self == .beacon || self == .tower }
    /// Vehicles and buildings: drones can repair them.
    var isMechanical: Bool { isBuilding || self == .skimmer || self == .tank || self == .gunship }
    var stats: Stats { Defs.table[rawValue] }

    static let units: [EntityType] = [.worker, .trooper, .lancer, .mender, .skimmer, .tank, .gunship]
    static let buildings: [EntityType] = [.hq, .depot, .barracks, .factory, .lab, .turret, .radar, .shield]
    static let army: [EntityType] = [.trooper, .lancer, .mender, .skimmer, .tank, .gunship]
}

enum ArmorClass: Int, Codable {
    case light, armored, structure

    var name: String {
        switch self {
        case .light: return "Light"
        case .armored: return "Armored"
        case .structure: return "Structure"
        }
    }
}

enum WeaponStyle: Int, Codable {
    case none, rifle, rocket, cannon, laser, heal, claw
}

enum Upgrade: Int, Codable, CaseIterable {
    case weapons1, weapons2, plating1, plating2, siegeMode, sprint

    var info: UpgradeInfo { Defs.upgrades[rawValue] }
}

/// One-time specialization of a production building: pick one of two, they exclude each other.
enum Spec: Int, Codable, CaseIterable {
    case fortress, refinery, drillYard, armory, assemblyLine, reactor

    var info: SpecInfo {
        switch self {
        case .fortress:
            return SpecInfo(name: "Fortress", building: .hq, cost: 150, time: 35,
                            blurb: "Arms this Command Center with a heavy gun (range 250, hits air), +600 HP and +1 armor.")
        case .refinery:
            return SpecInfo(name: "Refinery", building: .hq, cost: 150, time: 35,
                            blurb: "Crystals delivered to this Command Center are worth 25% more.")
        case .drillYard:
            return SpecInfo(name: "Drill Yard", building: .barracks, cost: 100, time: 30,
                            blurb: "This Barracks trains 60% faster.")
        case .armory:
            return SpecInfo(name: "Armory", building: .barracks, cost: 100, time: 30,
                            blurb: "Infantry from this Barracks have +25% HP.")
        case .assemblyLine:
            return SpecInfo(name: "Assembly Line", building: .factory, cost: 125, time: 35,
                            blurb: "This Factory builds 50% faster.")
        case .reactor:
            return SpecInfo(name: "Reactive Armor", building: .factory, cost: 125, time: 35,
                            blurb: "Vehicles from this Factory have +2 armor.")
        }
    }

    static func options(for t: EntityType) -> [Spec] { allCases.filter { $0.info.building == t } }
}

struct SpecInfo {
    var name: String
    var building: EntityType
    var cost: Int
    var time: Double
    var blurb: String
}

struct UpgradeInfo {
    var name: String
    var cost: Int
    var time: Double
    var requires: Upgrade?
    var requiresBuilding: EntityType?
    var blurb: String
}

struct Stats {
    var name: String
    var cost: Int = 0
    var supply: Int = 0
    var buildTime: Double = 10
    var hp: Double = 100
    var armor: Double = 0
    var speed: Double = 0
    var radius: Double = 10
    var range: Double = 0
    var damage: Double = 0
    var cooldown: Double = 1
    var armorClass: ArmorClass = .light
    var bonusVs: ArmorClass? = nil
    var bonusDamage: Double = 0
    var splash: Double = 0
    var sight: Double = 260
    var hitsAir = false
    var hitsGround = true
    var isAir = false
    var isBio = false
    var footprint = 0
    var supplyProvided = 0
    var requires: EntityType? = nil
    var requiresUpgrade: Upgrade? = nil
    var producedAt: EntityType? = nil
    var produces: [EntityType] = []
    var researches: [Upgrade] = []
    var weapon: WeaponStyle = .none
    var hotkeyRole: String = ""
    var blurb: String = ""
}

enum Defs {
    static let tile: Double = 32
    static let maxSupply = 100
    static let carry = 8
    static let gatherTime = 1.9
    static let crystalAmount = 1500
    static let richCarry = 12                // rich (violet) crystals give more per trip
    static let richAmount = 1100
    static let shieldRadius = 230.0          // Shield Generator: friendly things inside take less damage
    static let shieldReduction = 0.3
    static let towerRadius = 100.0           // stand this close to a watch tower to use it
    static let uphillPenalty = 0.75          // damage from low ground to high ground
    static let fortressRange = 250.0, fortressDamage = 16.0, fortressCooldown = 0.9
    static let repairRate = 0.05             // fraction of max HP per second, per drone
    static let startCrystals = 300
    static let beaconIncome = 1.5            // crystals per second per beacon
    static let beaconCaptureTime = 8.0
    static let beaconRadius = 110.0
    static let siegeTransition = 1.4
    static let sprintDuration = 6.0
    static let sprintCooldown = 22.0
    static let queueLimit = 5
    static let tickRate = 20
    static let dt = 1.0 / Double(tickRate)

    /// Sieged tank (replaces the tank's weapon while sieged).
    static let siegeRange = 330.0, siegeDamage = 42.0, siegeCooldown = 2.4, siegeSplash = 44.0, siegeMinRange = 70.0

    static let table: [Stats] = EntityType.allCases.map(make)

    static func make(_ t: EntityType) -> Stats {
        switch t {
        case .worker:
            return Stats(name: "Drone", cost: 50, supply: 1, buildTime: 11, hp: 45, speed: 82, radius: 9, range: 10,
                         damage: 5, cooldown: 1.2, sight: 220, isBio: true, producedAt: .hq, weapon: .claw,
                         hotkeyRole: "Gathers crystals and builds", blurb: "Mines crystals and constructs buildings.")
        case .trooper:
            return Stats(name: "Trooper", cost: 50, supply: 1, buildTime: 13, hp: 55, speed: 74, radius: 9, range: 150,
                         damage: 6, cooldown: 0.6, bonusVs: .light, bonusDamage: 2, sight: 270, hitsAir: true,
                         isBio: true, producedAt: .barracks, weapon: .rifle, hotkeyRole: "Cheap all-rounder, hits air",
                         blurb: "Fast-firing rifle infantry. Strong against light units, hits air. Weak against tanks.")
        case .lancer:
            return Stats(name: "Lancer", cost: 75, supply: 1, buildTime: 17, hp: 62, speed: 68, radius: 9, range: 195,
                         damage: 11, cooldown: 1.6, bonusVs: .armored, bonusDamage: 20, sight: 280, hitsAir: true,
                         isBio: true, producedAt: .barracks, weapon: .rocket, hotkeyRole: "Anti-armor rockets",
                         blurb: "Rocket infantry. Wrecks tanks and gunships, poor against infantry.")
        case .mender:
            return Stats(name: "Mender", cost: 75, supply: 1, buildTime: 16, hp: 50, speed: 76, radius: 9, range: 130,
                         damage: 4, cooldown: 0.5, sight: 260, isBio: true, requires: .lab, producedAt: .barracks,
                         weapon: .heal, hotkeyRole: "Heals infantry",
                         blurb: "Field medic. Heals nearby infantry and drones. Needs a Lab.")
        case .skimmer:
            return Stats(name: "Skimmer", cost: 75, supply: 2, buildTime: 15, hp: 85, speed: 150, radius: 11,
                         range: 125, damage: 8, cooldown: 0.5, bonusVs: .light, bonusDamage: 6, sight: 300,
                         producedAt: .factory, weapon: .laser, hotkeyRole: "Fast raider",
                         blurb: "Very fast hover bike. Shreds drones and infantry; fragile against tanks and rockets.")
        case .tank:
            return Stats(name: "Tank", cost: 150, supply: 3, buildTime: 26, hp: 270, armor: 2, speed: 58, radius: 15,
                         range: 185, damage: 22, cooldown: 1.8, armorClass: .armored, bonusVs: .structure,
                         bonusDamage: 18, splash: 22, sight: 280, producedAt: .factory, weapon: .cannon,
                         hotkeyRole: "Heavy armor, siege mode",
                         blurb: "Armored tank with splash. Siege Mode (Lab) gives huge range, but it cannot move or hit air.")
        case .gunship:
            return Stats(name: "Gunship", cost: 175, supply: 3, buildTime: 30, hp: 200, armor: 1, speed: 105,
                         radius: 16, range: 165, damage: 13, cooldown: 0.9, armorClass: .armored, bonusVs: .armored,
                         bonusDamage: 10, sight: 320, hitsAir: true, isAir: true, requires: .lab, producedAt: .factory,
                         weapon: .laser, hotkeyRole: "Flying tank hunter",
                         blurb: "Flies over cliffs and water. Hunts tanks. Troopers, Lancers and Turrets shoot it down.")
        case .hq:
            return Stats(name: "Command Center", cost: 400, buildTime: 70, hp: 1500, armor: 2, radius: 46,
                         armorClass: .structure, sight: 340, footprint: 3, supplyProvided: 10, produces: [.worker],
                         hotkeyRole: "Trains drones, stores crystals",
                         blurb: "Trains Drones and stores crystals. Build more to expand. Lose them all and you lose.")
        case .depot:
            return Stats(name: "Power Depot", cost: 100, buildTime: 20, hp: 400, armor: 1, radius: 30,
                         armorClass: .structure, sight: 200, footprint: 2, supplyProvided: 8, hotkeyRole: "+8 supply",
                         blurb: "Raises your supply limit by 8.")
        case .barracks:
            return Stats(name: "Barracks", cost: 150, buildTime: 34, hp: 900, armor: 1, radius: 46,
                         armorClass: .structure, sight: 240, footprint: 3, requires: .hq,
                         produces: [.trooper, .lancer, .mender], hotkeyRole: "Trains infantry",
                         blurb: "Trains Troopers, Lancers and Menders.")
        case .factory:
            return Stats(name: "Factory", cost: 200, buildTime: 44, hp: 1100, armor: 1, radius: 46,
                         armorClass: .structure, sight: 240, footprint: 3, requires: .barracks,
                         produces: [.skimmer, .tank, .gunship], hotkeyRole: "Builds vehicles",
                         blurb: "Builds Skimmers, Tanks and Gunships. Needs a Barracks.")
        case .lab:
            return Stats(name: "Tech Lab", cost: 150, buildTime: 34, hp: 600, armor: 1, radius: 30,
                         armorClass: .structure, sight: 220, footprint: 2, requires: .barracks,
                         researches: [.weapons1, .weapons2, .plating1, .plating2, .siegeMode, .sprint],
                         hotkeyRole: "Upgrades",
                         blurb: "Researches upgrades and unlocks Menders and Gunships. Needs a Barracks.")
        case .turret:
            return Stats(name: "Turret", cost: 100, buildTime: 24, hp: 420, armor: 2, radius: 28, range: 240,
                         damage: 12, cooldown: 0.8, armorClass: .structure, sight: 300, hitsAir: true, footprint: 2,
                         requires: .barracks, weapon: .rifle, hotkeyRole: "Static defense",
                         blurb: "Defensive gun. Hits ground and air. Needs a Barracks.")
        case .radar:
            return Stats(name: "Radar Tower", cost: 75, buildTime: 22, hp: 320, radius: 26, armorClass: .structure,
                         sight: 640, footprint: 2, requires: .barracks, hotkeyRole: "Vision",
                         blurb: "Sees 640 around it, up cliffs too. Spot attacks coming and give your army vision of high ground.")
        case .shield:
            return Stats(name: "Shield Generator", cost: 150, buildTime: 32, hp: 520, armor: 1, radius: 28,
                         armorClass: .structure, sight: 240, footprint: 2, requires: .lab, hotkeyRole: "Damage shield",
                         blurb: "Friendly units and buildings within 230 take 30% less damage. Needs a Tech Lab.")
        case .crystal:
            return Stats(name: "Crystal", hp: 1, radius: 13, armorClass: .structure, sight: 0, footprint: 1,
                         blurb: "Mine with Drones. Violet crystals are rich: 12 per trip instead of 8.")
        case .beacon:
            return Stats(name: "Beacon", hp: 1, radius: 26, armorClass: .structure, sight: 300,
                         blurb: "Stand near it to capture. Gives crystals over time and vision.")
        case .tower:
            return Stats(name: "Watch Tower", hp: 1, radius: 18, armorClass: .structure, sight: 560,
                         blurb: "Keep a unit next to it to see far around it, including up cliffs.")
        }
    }

    static let upgrades: [UpgradeInfo] = Upgrade.allCases.map { u in
        switch u {
        case .weapons1:
            return UpgradeInfo(name: "Weapons I", cost: 100, time: 45, requires: nil, requiresBuilding: nil,
                               blurb: "+15% damage for all units and turrets.")
        case .weapons2:
            return UpgradeInfo(name: "Weapons II", cost: 175, time: 60, requires: .weapons1, requiresBuilding: .factory,
                               blurb: "Another +15% damage. Needs a Factory.")
        case .plating1:
            return UpgradeInfo(name: "Plating I", cost: 100, time: 45, requires: nil, requiresBuilding: nil,
                               blurb: "+1 armor for all units.")
        case .plating2:
            return UpgradeInfo(name: "Plating II", cost: 175, time: 60, requires: .plating1, requiresBuilding: .factory,
                               blurb: "Another +1 armor. Needs a Factory.")
        case .siegeMode:
            return UpgradeInfo(name: "Siege Mode", cost: 125, time: 50, requires: nil, requiresBuilding: .factory,
                               blurb: "Tanks can siege: range 330, heavy splash, but immobile.")
        case .sprint:
            return UpgradeInfo(name: "Sprint", cost: 100, time: 40, requires: nil, requiresBuilding: nil,
                               blurb: "Troopers and Lancers can sprint: +50% speed and fire rate for 6 s, costs 10 HP.")
        }
    }
}

enum Difficulty: Int, Codable, CaseIterable {
    case easy, normal, hard, brutal

    var name: String {
        switch self {
        case .easy: return "Easy"
        case .normal: return "Normal"
        case .hard: return "Hard"
        case .brutal: return "Brutal"
        }
    }
    var blurb: String {
        switch self {
        case .easy: return "Slow, small attacks. Learn the ropes."
        case .normal: return "Solid build orders and timing attacks."
        case .hard: return "Expands, scouts, counters your army, focuses fire."
        case .brutal: return "Hard with sharp reactions and +30% mining. Good luck."
        }
    }
}

enum Personality: Int, Codable, CaseIterable {
    case balanced, rusher, turtle, mechanic

    var name: String {
        switch self {
        case .balanced: return "Balanced"
        case .rusher: return "Rusher"
        case .turtle: return "Turtle"
        case .mechanic: return "Mechanic"
        }
    }
}

enum TeamColor: Int, Codable, CaseIterable {
    case blue, red, green, gold, purple, teal

    var name: String {
        switch self {
        case .blue: return "Blue"
        case .red: return "Red"
        case .green: return "Green"
        case .gold: return "Gold"
        case .purple: return "Purple"
        case .teal: return "Teal"
        }
    }
    /// 0...1 RGB, used by the renderer.
    var rgb: (Double, Double, Double) {
        switch self {
        case .blue: return (0.20, 0.52, 1.00)
        case .red: return (0.93, 0.22, 0.20)
        case .green: return (0.25, 0.80, 0.30)
        case .gold: return (1.00, 0.76, 0.12)
        case .purple: return (0.65, 0.35, 0.95)
        case .teal: return (0.10, 0.82, 0.80)
        }
    }
}
