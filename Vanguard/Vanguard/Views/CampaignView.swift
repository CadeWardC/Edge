import SwiftUI

/// Eight missions that teach the game and ramp up to a Brutal bot. Each is a skirmish with a story, set opponents and
/// handicaps; winning unlocks the next.
struct Mission: Identifiable {
    var id: Int
    var title: String
    var map: MapID
    var briefing: String
    var tip: String
    var enemies: [(Difficulty, Personality, Int)]          // difficulty, style, bonus crystals
    var allies: [(Difficulty, Personality)] = []
    var freeForAll = false

    func setup(playerName: String) -> MatchSetup {
        var players = [PlayerSetup(name: playerName, team: 0, color: .blue, isBot: false)]
        let colors: [TeamColor] = [.red, .gold, .purple, .teal, .green]
        var ci = 0
        for a in allies {
            players.append(PlayerSetup(name: "Ally (\(a.0.name))", team: 0, color: .green, isBot: true, difficulty: a.0, personality: a.1))
        }
        for (i, e) in enemies.enumerated() {
            players.append(PlayerSetup(name: "\(e.1.name) (\(e.0.name))", team: freeForAll ? i + 1 : 1, color: colors[ci % colors.count],
                                       isBot: true, difficulty: e.0, personality: e.1, bonusCrystals: e.2))
            ci += 1
        }
        // on 2v2 maps teammates take alternating slots
        if map == .frontier && players.count == 4 {
            players = [players[0], players[2], players[1], players[3]]
        }
        return MatchSetup(map: map, seed: UInt64(1000 + id * 37), players: players)
    }

    static let all: [Mission] = [
        Mission(id: 0, title: "First Contact", map: .crossroads,
                briefing: "A scout force has landed on the Crossroads. Build up and drive them off.",
                tip: "Keep training Drones. Build a Barracks when you have about 9, and a Power Depot before you run out of supply.",
                enemies: [(.easy, .balanced, 0)]),
        Mission(id: 1, title: "Cold Front", map: .frostbite,
                briefing: "Raiders strike early through the pine forests. Hold your plateau, then counterattack.",
                tip: "A Turret at the top of your ramp and a few Troopers will stop the first wave. Your ramp is a chokepoint.",
                enemies: [(.normal, .rusher, 0)]),
        Mission(id: 2, title: "Sand and Steel", map: .duneSea,
                briefing: "The enemy fields heavy armor in the open desert, and they have a head start.",
                tip: "Lancers wreck Tanks. Take the watch tower to see their army coming.",
                enemies: [(.normal, .mechanic, 250)]),
        Mission(id: 3, title: "River Crossing", map: .twinRivers,
                briefing: "A capable commander holds the far bank. Only three bridges cross the river.",
                tip: "Control the bridges and towers. Specialize your Barracks (Drill Yard) to out-produce them.",
                enemies: [(.hard, .balanced, 0)]),
        Mission(id: 4, title: "Two Against One", map: .highlands,
                briefing: "Two enemy commanders have joined forces against you.",
                tip: "Expand to your natural early and use Siege Mode Tanks on the high ground to hold it.",
                enemies: [(.normal, .turtle, 0), (.normal, .rusher, 0)]),
        Mission(id: 5, title: "Shoulder to Shoulder", map: .frontier,
                briefing: "An allied commander fights at your side on the Frontier. The enemy is strong.",
                tip: "Attack together with your ally. Rich (violet) crystals behind your lines are worth defending.",
                enemies: [(.hard, .mechanic, 0), (.hard, .rusher, 0)], allies: [(.hard, .balanced)]),
        Mission(id: 6, title: "Into the Fire", map: .caldera,
                briefing: "Three warlords fight over the volcanic crater. Be the last one standing.",
                tip: "Let them weaken each other. A Fortress Command Center and a Shield Generator make your base hard to crack.",
                enemies: [(.hard, .turtle, 0), (.hard, .mechanic, 0), (.normal, .rusher, 0)], freeForAll: true),
        Mission(id: 7, title: "Vanguard", map: .crossroads,
                briefing: "The enemy's best commander. Faster, richer and relentless. Win this and the war is over.",
                tip: "Scout, expand, upgrade, and never stop producing. Focus fire, and retreat before you lose your army.",
                enemies: [(.brutal, .balanced, 0)]),
    ]
}

enum CampaignProgress {
    static var completed: Set<Int> {
        get { Set(UserDefaults.standard.array(forKey: "campaignDone") as? [Int] ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: "campaignDone") }
    }
    static func best(_ id: Int) -> Int? { UserDefaults.standard.object(forKey: "campaignBest\(id)") as? Int }
    static func record(_ id: Int, seconds: Int) {
        completed.insert(id)
        if let b = best(id), b <= seconds { return }
        UserDefaults.standard.set(seconds, forKey: "campaignBest\(id)")
    }
    static func unlocked(_ id: Int) -> Bool { id == 0 || completed.contains(id - 1) }
}

struct CampaignView: View {
    @ObservedObject var app: AppModel
    @AppStorage("playerName") private var playerName = "Commander"
    @State private var selected = 0
    @State private var refresh = 0

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                ScreenTitle("Campaign")
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(Mission.all) { m in row(m) }
                    }
                }
                Button("Back") { app.screen = .menu }.buttonStyle(SecondaryButtonStyle())
            }
            .frame(width: 300)
            briefing(Mission.all[selected])
        }
        .padding(20)
        .onAppear {
            refresh += 1
            selected = Mission.all.last(where: { CampaignProgress.unlocked($0.id) })?.id ?? 0
        }
    }

    private func row(_ m: Mission) -> some View {
        let open = CampaignProgress.unlocked(m.id)
        let done = CampaignProgress.completed.contains(m.id)
        return Button { if open { selected = m.id } } label: {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(done ? Theme.gold : (open ? Theme.accent : Color.gray.opacity(0.4))).frame(width: 30, height: 30)
                    if done { Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.black) }
                    else if !open { Image(systemName: "lock.fill").font(.caption) }
                    else { Text("\(m.id + 1)").font(.caption.bold()) }
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(m.title).font(.headline)
                    Text("\(m.map.name)" + (CampaignProgress.best(m.id).map { String(format: " · best %d:%02d", $0 / 60, $0 % 60) } ?? ""))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(8)
            .panel()
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected == m.id ? Theme.accent : .clear, lineWidth: 2))
            .opacity(open ? 1 : 0.5)
        }
        .buttonStyle(.plain)
        .id("\(m.id)-\(refresh)")
    }

    private func briefing(_ m: Mission) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                Image(uiImage: MapPreview.image(m.map)).interpolation(.none).resizable().frame(width: 76, height: 76)
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.edge, lineWidth: 1))
                VStack(alignment: .leading, spacing: 3) {
                    Text("MISSION \(m.id + 1) · \(m.map.name.uppercased())").font(.caption2.bold()).tracking(1.5).foregroundStyle(Theme.accent)
                    Text(m.title).font(.system(.title2, design: .rounded).weight(.heavy))
                }
                Spacer()
                Button {
                    Sound.shared.play(.click)
                    app.start(m.setup(playerName: playerName.isEmpty ? "Commander" : playerName), localPlayer: 0, mission: m.id)
                } label: {
                    Label("Start", systemImage: "play.fill")
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!CampaignProgress.unlocked(m.id))
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(m.briefing).font(.callout).fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("OPPOSITION").font(.caption2.bold()).tracking(1.5).foregroundStyle(.secondary)
                        ForEach(Array(m.enemies.enumerated()), id: \.offset) { _, e in
                            Label("\(e.0.name) bot, \(e.1.name) style" + (e.2 > 0 ? ", +\(e.2) crystals" : ""), systemImage: "scope")
                                .font(.callout)
                        }
                        ForEach(Array(m.allies.enumerated()), id: \.offset) { _, a in
                            Label("Ally: \(a.0.name) bot, \(a.1.name) style", systemImage: "person.2.fill").font(.callout).foregroundStyle(.green)
                        }
                    }
                    Label(m.tip, systemImage: "lightbulb.fill").font(.callout).foregroundStyle(Theme.gold)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(m.map.blurb).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .panel()
    }
}

struct SettingsView: View {
    var onBack: () -> Void
    @AppStorage("playerName") private var playerName = "Commander"
    @AppStorage("sfxVolume") private var sfx: Double = 0.8
    @AppStorage("musicVolume") private var music: Double = 0.45
    @AppStorage("haptics") private var haptics = true
    @AppStorage("alwaysHP") private var alwaysHP = false
    @State private var confirmReset = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                ScreenTitle("Settings")
                Spacer()
                Button("Back", action: onBack).buttonStyle(SecondaryButtonStyle())
            }
            Form {
                Section("Player") {
                    TextField("Name", text: $playerName)
                }
                Section("Sound") {
                    HStack { Text("Effects"); Slider(value: $sfx, in: 0...1) }
                    HStack {
                        Text("Music")
                        Slider(value: $music, in: 0...1) { _ in Sound.shared.updateVolumes() }
                    }
                }
                Section("Game") {
                    Toggle("Vibrate on alerts", isOn: $haptics)
                    Toggle("Always show health bars", isOn: $alwaysHP)
                }
                Section("Campaign") {
                    Button("Reset campaign progress", role: .destructive) { confirmReset = true }
                }
            }
            .scrollContentBackground(.hidden)
        }
        .padding(20)
        .onChange(of: music) { _, _ in Sound.shared.updateVolumes() }
        .alert("Reset all campaign progress?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive) {
                CampaignProgress.completed = []
                for m in Mission.all { UserDefaults.standard.removeObject(forKey: "campaignBest\(m.id)") }
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}
