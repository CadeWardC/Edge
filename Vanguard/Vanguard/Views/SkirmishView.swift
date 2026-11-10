import SwiftUI

struct SlotConfig: Identifiable {
    var id = UUID()
    var name: String
    var isBot: Bool
    var difficulty: Difficulty = .normal
    var personality: Personality? = nil
    var team: Int
    var color: TeamColor
}

enum MapPreview {
    private static var cache: [MapID: UIImage] = [:]
    static func image(_ id: MapID) -> UIImage {
        if let i = cache[id] { return i }
        let i = Art.minimap(MapGen.build(id))
        cache[id] = i
        return i
    }
}

struct SkirmishView: View {
    @ObservedObject var app: AppModel
    @AppStorage("playerName") private var playerName = "Commander"
    @State private var map: MapID = .crossroads
    @State private var slots: [SlotConfig] = []
    @State private var watchOnly = false

    static func quickSetup() -> MatchSetup {
        let name = UserDefaults.standard.string(forKey: "playerName") ?? "Commander"
        return MatchSetup(map: .crossroads, seed: UInt64.random(in: 1...UInt64.max / 2), players: [
            PlayerSetup(name: name, team: 0, color: .blue, isBot: false),
            PlayerSetup(name: "Normal bot", team: 1, color: .red, isBot: true, difficulty: .normal),
        ])
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                header
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(MapID.allCases, id: \.self) { m in mapCard(m) }
                    }
                }
            }
            .frame(width: 290)
            VStack(alignment: .leading, spacing: 10) {
                Text("Players").font(.headline)
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach($slots) { $s in slotRow($s) }
                        if slots.count < map.maxPlayers {
                            Button {
                                let i = slots.count
                                slots.append(SlotConfig(name: "Bot \(i)", isBot: true, team: map.defaultTeam(slot: i), color: TeamColor.allCases[i % 6]))
                            } label: {
                                Label("Add bot", systemImage: "plus.circle.fill").frame(maxWidth: .infinity).padding(10).panel()
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                Toggle("Watch only (all players are bots)", isOn: $watchOnly).font(.callout)
                HStack {
                    Button("Back") { app.screen = .menu }.buttonStyle(SecondaryButtonStyle())
                    Spacer()
                    Button {
                        start()
                    } label: {
                        Label("Start Battle", systemImage: "play.fill").font(.headline).padding(.horizontal, 20).padding(.vertical, 6)
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(slots.count < 2 || Set(slots.map { $0.team }).count < 2)
                }
            }
        }
        .padding(20)
        .onAppear { if slots.isEmpty { resetSlots() } }
        .onChange(of: map) { _, _ in resetSlots() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScreenTitle("Skirmish")
            TextField("Your name", text: $playerName).textFieldStyle(.roundedBorder)
        }
    }

    private func mapCard(_ m: MapID) -> some View {
        Button { map = m } label: {
            HStack(spacing: 10) {
                Image(uiImage: MapPreview.image(m)).interpolation(.none).resizable().frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 3) {
                    Text(m.name).font(.headline)
                    Text(m.blurb).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .panel()
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(map == m ? Theme.accent : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
    }

    private func slotRow(_ s: Binding<SlotConfig>) -> some View {
        let idx = slots.firstIndex { $0.id == s.wrappedValue.id } ?? 0
        return HStack(spacing: 10) {
            Circle().fill(Color(Art.color(s.wrappedValue.color))).frame(width: 18, height: 18)
                .onTapGesture {
                    let all = TeamColor.allCases
                    s.wrappedValue.color = all[(all.firstIndex(of: s.wrappedValue.color)! + 1) % all.count]
                }
            if s.wrappedValue.isBot {
                Image(systemName: "cpu").foregroundStyle(.secondary)
                Picker("Difficulty", selection: s.difficulty) {
                    ForEach(Difficulty.allCases, id: \.self) { Text($0.name).tag($0) }
                }
                .pickerStyle(.menu)
                Picker("Style", selection: s.personality) {
                    Text("Random").tag(Personality?.none)
                    ForEach(Personality.allCases, id: \.self) { Text($0.name).tag(Personality?.some($0)) }
                }
                .pickerStyle(.menu)
            } else {
                Image(systemName: "person.fill")
                Text(playerName.isEmpty ? "You" : playerName).font(.headline)
            }
            Spacer()
            Picker("Team", selection: s.team) {
                ForEach(0..<4, id: \.self) { Text("Team \($0 + 1)").tag($0) }
            }
            .pickerStyle(.menu)
            if idx > 0 {
                Button { slots.removeAll { $0.id == s.wrappedValue.id } } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .panel()
    }

    private func resetSlots() {
        var s = [SlotConfig(name: playerName, isBot: false, team: 0, color: .blue)]
        for i in 1..<map.maxPlayers {
            s.append(SlotConfig(name: "Bot \(i)", isBot: true, team: map.defaultTeam(slot: i), color: TeamColor.allCases[i % 6]))
        }
        if map.maxPlayers == 2 { s[1].color = .red }
        slots = s
    }

    private func start() {
        var players: [PlayerSetup] = []
        for (i, s) in slots.enumerated() {
            let bot = s.isBot || watchOnly
            let name = bot ? "\(s.difficulty.name) bot\(i > 0 ? " \(i)" : "")" : (playerName.isEmpty ? "You" : playerName)
            players.append(PlayerSetup(name: name, team: s.team, color: s.color, isBot: bot,
                                       difficulty: s.isBot ? s.difficulty : (watchOnly ? .hard : .normal), personality: s.personality))
        }
        let setup = MatchSetup(map: map, seed: UInt64.random(in: 1...UInt64.max / 2), players: players)
        app.start(setup, localPlayer: watchOnly ? -1 : 0)
    }
}
