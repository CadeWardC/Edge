import SwiftUI

/// Lobby over any NetTransport. The host owns the seat list and broadcasts it; everyone says hello until they see
/// themselves in it; the host's Start sends the MatchSetup (with the shared seed) and the lockstep game begins.
final class LobbyModel: ObservableObject {
    @Published var status = "Not connected"
    @Published var lobby: LobbyState?
    @Published var connected = false
    @Published var isHost = false
    let clientId = UUID().uuidString
    private var transport: WebSocketTransport?
    private var name = ""
    private var helloTimer: Timer?
    var onStart: ((MatchSetup, NetTransport, Int) -> Void)?

    func connect(server: String, room: String, name: String, host: Bool) {
        disconnect()
        self.name = name.isEmpty ? "Player" : name
        isHost = host
        do {
            let t = try WebSocketTransport(server: server, room: room)
            transport = t
            t.onStatus = { [weak self] s in self?.statusChanged(s) }
            t.onMessage = { [weak self] m in self?.handle(m) }
            t.connect()
        } catch {
            status = "That server address or room code doesn't look right."
        }
    }

    func disconnect() {
        helloTimer?.invalidate()
        helloTimer = nil
        transport?.close()
        transport = nil
        connected = false
        lobby = nil
    }

    private func statusChanged(_ s: TransportStatus) {
        switch s {
        case .connecting:
            status = "Connecting…"
        case .connected:
            connected = true
            if isHost {
                status = "Hosting. Share the room code."
                lobby = LobbyState(hostId: clientId, map: .crossroads, players: [
                    PlayerSetup(name: name, team: 0, color: .blue, isBot: false, clientId: clientId),
                ])
                broadcast()
            } else {
                status = "Connected. Waiting for the host…"
                sayHello()
                helloTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.sayHello() }
            }
        case let .disconnected(why):
            connected = false
            status = "Disconnected: \(why)"
        }
    }

    private func sayHello() {
        if let l = lobby, l.players.contains(where: { $0.clientId == clientId }) {
            helloTimer?.invalidate()
            return
        }
        transport?.send(.hello(clientId: clientId, name: name, version: Vanguard.protocolVersion))
    }

    private func handle(_ m: NetMessage) {
        switch m {
        case let .hello(id, n, version):
            guard isHost, var l = lobby else { return }
            if version != Vanguard.protocolVersion { status = "\(n) has a different version of Vanguard."; return }
            if !l.players.contains(where: { $0.clientId == id }) {
                guard l.players.count < l.map.maxPlayers else { broadcast(); return }
                let slot = l.players.count
                l.players.append(PlayerSetup(name: n, team: l.map.defaultTeam(slot: slot), color: freeColor(l), isBot: false, clientId: id))
                lobby = l
                status = "\(n) joined."
            }
            broadcast()
        case let .lobby(l):
            guard !isHost else { return }
            lobby = l
            if l.players.contains(where: { $0.clientId == clientId }) { status = "In the lobby. The host starts the game." }
        case let .start(setup):
            guard !isHost, let me = setup.players.firstIndex(where: { $0.clientId == clientId }), let t = transport else { return }
            helloTimer?.invalidate()
            onStart?(setup, t, me)
        case let .leave(id):
            guard isHost, var l = lobby else { return }
            l.players.removeAll { $0.clientId == id }
            lobby = l
            broadcast()
        default:
            break
        }
    }

    private func freeColor(_ l: LobbyState) -> TeamColor {
        TeamColor.allCases.first { c in !l.players.contains { $0.color == c } } ?? .teal
    }

    private func broadcast() {
        guard isHost, let l = lobby else { return }
        transport?.send(.lobby(l))
    }

    // host controls
    func setMap(_ m: MapID) {
        guard isHost, var l = lobby else { return }
        l.map = m
        l.players = Array(l.players.prefix(m.maxPlayers))
        for i in l.players.indices { l.players[i].team = m.defaultTeam(slot: i) }
        lobby = l
        broadcast()
    }

    func addBot(_ d: Difficulty) {
        guard isHost, var l = lobby, l.players.count < l.map.maxPlayers else { return }
        let slot = l.players.count
        l.players.append(PlayerSetup(name: "\(d.name) bot", team: l.map.defaultTeam(slot: slot), color: freeColor(l), isBot: true, difficulty: d))
        lobby = l
        broadcast()
    }

    func remove(_ i: Int) {
        guard isHost, var l = lobby, i > 0, i < l.players.count else { return }
        l.players.remove(at: i)
        lobby = l
        broadcast()
    }

    func cycleTeam(_ i: Int) {
        guard isHost, var l = lobby, i < l.players.count else { return }
        l.players[i].team = (l.players[i].team + 1) % 4
        lobby = l
        broadcast()
    }

    var canStart: Bool {
        guard isHost, let l = lobby else { return false }
        return l.players.count >= 2 && Set(l.players.map { $0.team }).count >= 2
    }

    func start() {
        guard canStart, let l = lobby, let t = transport else { return }
        let setup = MatchSetup(map: l.map, seed: UInt64.random(in: 1...UInt64.max / 2), players: l.players)
        t.send(.start(setup))
        onStart?(setup, t, 0)
    }
}

struct MultiplayerView: View {
    @ObservedObject var app: AppModel
    @StateObject private var lobby = LobbyModel()
    @AppStorage("playerName") private var playerName = "Commander"
    @AppStorage("relayServer") private var server = ""
    @State private var room = String((0..<4).map { _ in "ABCDEFGHJKLMNPQRSTUVWXYZ".randomElement()! })

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                ScreenTitle("Multiplayer")
                TextField("Your name", text: $playerName).textFieldStyle(.roundedBorder)
                TextField("Relay server, e.g. 192.168.1.20:8765", text: $server)
                    .textFieldStyle(.roundedBorder).textInputAutocapitalization(.never).autocorrectionDisabled()
                HStack {
                    TextField("Room", text: $room).textFieldStyle(.roundedBorder).textInputAutocapitalization(.characters)
                        .frame(width: 110)
                    Button("Host") { lobby.connect(server: server, room: room, name: playerName, host: true) }
                        .buttonStyle(PrimaryButtonStyle()).disabled(server.isEmpty || room.isEmpty)
                    Button("Join") { lobby.connect(server: server, room: room, name: playerName, host: false) }
                        .buttonStyle(SecondaryButtonStyle()).disabled(server.isEmpty || room.isEmpty)
                }
                Text(lobby.status).font(.callout).foregroundStyle(.secondary)
                Text("Run Vanguard/Server/relay.py on any computer (python3 relay.py), enter its address here on every device, and use the same room code. Games run in lockstep: only commands go over the network.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Back") {
                    lobby.disconnect()
                    app.screen = .menu
                }
                .buttonStyle(SecondaryButtonStyle())
            }
            .frame(width: 330)
            lobbyPanel
        }
        .padding(20)
        .onAppear {
            let model = app
            lobby.onStart = { [weak model] setup, transport, me in
                model?.start(setup, localPlayer: me, transport: transport)
            }
        }
    }

    @ViewBuilder private var lobbyPanel: some View {
        if let l = lobby.lobby {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Room \(room.uppercased())").font(.headline)
                    Spacer()
                    if lobby.isHost {
                        Picker("Map", selection: Binding(get: { l.map }, set: { lobby.setMap($0) })) {
                            ForEach(MapID.allCases, id: \.self) { Text($0.name).tag($0) }
                        }
                    } else {
                        Text(l.map.name).foregroundStyle(.secondary)
                    }
                }
                ForEach(Array(l.players.enumerated()), id: \.offset) { i, p in
                    HStack {
                        Circle().fill(Color(Art.color(p.color))).frame(width: 16, height: 16)
                        Image(systemName: p.isBot ? "cpu" : "person.fill")
                        Text(p.name + (p.clientId == lobby.clientId ? " (you)" : ""))
                        Spacer()
                        Button("Team \(p.team + 1)") { lobby.cycleTeam(i) }.disabled(!lobby.isHost).buttonStyle(SecondaryButtonStyle())
                        if lobby.isHost && i > 0 {
                            Button { lobby.remove(i) } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain)
                        }
                    }
                    .padding(8)
                    .panel()
                }
                if lobby.isHost {
                    HStack {
                        Menu {
                            ForEach(Difficulty.allCases, id: \.self) { d in Button(d.name) { lobby.addBot(d) } }
                        } label: { Label("Add bot", systemImage: "plus") }
                        .disabled(l.players.count >= l.map.maxPlayers)
                        Spacer()
                        Button { lobby.start() } label: { Label("Start", systemImage: "play.fill") }
                            .buttonStyle(PrimaryButtonStyle()).disabled(!lobby.canStart)
                    }
                }
            }
            .frame(maxWidth: .infinity)
        } else {
            VStack(spacing: 12) {
                Image(systemName: "network").font(.system(size: 50)).foregroundStyle(.secondary)
                Text("Host a room, or join one with its code.").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
