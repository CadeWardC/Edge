import Foundation

/// Every 2 ticks (100 ms) is a "turn". Each human sends the commands they gave for a turn a few turns ahead; a turn
/// only runs when every human's packet for it has arrived, and all devices apply the same commands in the same order.
/// The simulation is deterministic, so every device computes the same game. Bots run inside the simulation on every
/// device, so they cost no bandwidth.
struct TurnPacket: Codable, Equatable {
    var player: Int
    var turn: Int
    var commands: [Command]
    /// State hash at the start of `checksumTurn`, every 10 turns, to catch a desync.
    var checksum: UInt64?
    var checksumTurn: Int?
}

final class LockstepSession {
    let world: World
    /// Players controlled by people (one packet each per turn).
    let humans: [Int]
    /// The humans playing on this device.
    let local: [Int]
    let transport: NetTransport?
    let turnTicks = 2
    let delay: Int
    private(set) var turn = 0
    private var tickInTurn = 0
    private var outbox: [Command] = []
    private var inbox: [Int: [Int: TurnPacket]] = [:]
    private var current: [Command] = []
    private var accumulator: Double = 0
    private var myChecksums: [Int: UInt64] = [:]
    private var peerChecksums: [Int: [Int: UInt64]] = [:]
    var speed: Double = 1
    var paused = false
    private(set) var waiting = false
    private(set) var desyncTurn: Int?
    var onDesync: ((Int) -> Void)?
    var onPeerLeft: ((String) -> Void)?
    /// Every command that ran, in order: a replay of the match.
    private(set) var log: [(tick: Int, command: Command)] = []

    init(world: World, humans: [Int], local: [Int], transport: NetTransport?) {
        self.world = world
        self.humans = humans.sorted()
        self.local = local
        self.transport = transport
        delay = transport == nil ? 1 : 3
        for t in 0..<delay {
            for p in self.humans { inbox[t, default: [:]][p] = TurnPacket(player: p, turn: t, commands: []) }
        }
        transport?.onMessage = { [weak self] m in self?.receive(m) }
    }

    /// Queue a command from a local player; it runs `delay` turns from now on every device.
    func issue(_ c: Command) {
        guard local.contains(c.player) else { return }
        outbox.append(c)
    }

    func receive(_ m: NetMessage) {
        switch m {
        case let .turn(p):
            guard humans.contains(p.player), !local.contains(p.player), p.turn >= turn else { return }
            var clean = p
            clean.commands = p.commands.filter { $0.player == p.player }
            store(clean)
        case let .leave(clientId):
            onPeerLeft?(clientId)
        default:
            break
        }
    }

    private func store(_ p: TurnPacket) {
        inbox[p.turn, default: [:]][p.player] = p
        if let cs = p.checksum, let ct = p.checksumTurn {
            peerChecksums[ct, default: [:]][p.player] = cs
            compare(ct)
        }
    }

    private func compare(_ t: Int) {
        guard desyncTurn == nil, let mine = myChecksums[t], let theirs = peerChecksums[t] else { return }
        if theirs.values.contains(where: { $0 != mine }) {
            desyncTurn = t
            onDesync?(t)
        }
    }

    /// How far the next tick is (0...1), for smooth rendering between ticks.
    var alpha: Double { waiting || paused ? 1 : min(1, accumulator / Defs.dt) }

    /// Advance by real time. Returns the number of ticks run.
    @discardableResult
    func update(realDt: Double) -> Int {
        guard !paused, !world.isOver else { return 0 }
        accumulator += min(realDt, 0.25) * speed
        var ran = 0
        while accumulator >= Defs.dt && ran < 12 {
            guard stepTick() else { accumulator = min(accumulator, Defs.dt); break }
            accumulator -= Defs.dt
            ran += 1
        }
        return ran
    }

    /// Runs one tick if its turn's input is here. Returns false while waiting for other players.
    @discardableResult
    func stepTick() -> Bool {
        if world.isOver { return false }
        if tickInTurn == 0 {
            guard let packets = inbox[turn], humans.allSatisfy({ packets[$0] != nil }) else {
                waiting = true
                return false
            }
            waiting = false
            var checksum: UInt64?
            if turn % 10 == 0 {
                let c = world.checksum()
                myChecksums[turn] = c
                checksum = c
                myChecksums[turn - 200] = nil
                peerChecksums[turn - 200] = nil
                compare(turn)
            }
            for p in local {
                let pkt = TurnPacket(player: p, turn: turn + delay, commands: outbox.filter { $0.player == p },
                                     checksum: checksum, checksumTurn: checksum == nil ? nil : turn)
                inbox[pkt.turn, default: [:]][p] = pkt
                transport?.send(.turn(pkt))
            }
            outbox.removeAll()
            current = humans.flatMap { packets[$0]?.commands ?? [] }
            inbox[turn] = nil
            for c in current { log.append((world.tick, c)) }
        }
        world.step(tickInTurn == 0 ? current : [])
        tickInTurn += 1
        if tickInTurn == turnTicks {
            tickInTurn = 0
            turn += 1
        }
        return true
    }
}
