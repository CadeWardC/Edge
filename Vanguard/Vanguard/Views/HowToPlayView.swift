import SwiftUI

struct HowToPlayView: View {
    var onBack: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("How to Play").font(.largeTitle.bold())
                Spacer()
                Button("Back", action: onBack).buttonStyle(.bordered)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    section("Goal", """
                    Destroy every enemy building. Drones mine crystals; crystals buy buildings and units. Supply (from \
                    Command Centers and Power Depots) caps your army at 100. Beacons on the map give crystals and vision \
                    to whoever holds them: stand next to one with no enemies around to capture it.
                    """)
                    section("Controls", """
                    • Drag with one finger to scroll, pinch to zoom, tap the minimap to jump.
                    • Tap a unit to select it. Tap it again quickly to select every unit of that type on screen.
                    • Press and hold, then drag, to draw a selection box (army first, then drones).
                    • With units selected: tap the ground to move, an enemy to attack, crystals to mine.
                    • Attack, then tap: attack-move (fight everything on the way).
                    • With a building selected: tap the ground to set its rally point.
                    • Army and Idle buttons on the left; 1–3 are control groups (press and hold to save the selection).
                    • Press and hold a command button to read what it does.
                    """)
                    section("Counters", """
                    • Troopers beat light units and hit air; tanks crush them.
                    • Lancers wreck tanks and gunships; troopers and skimmers beat lancers.
                    • Skimmers raid drones and infantry; tanks and lancers stop them.
                    • Tanks smash infantry and buildings with splash; Siege Mode doubles their reach. They can't hit air.
                    • Gunships fly over cliffs and hunt tanks; troopers, lancers and turrets shoot them down.
                    • Units with 4 kills become Veterans (+10% damage), 10 kills Elite (+20%).
                    """)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Units").font(.headline)
                        ForEach(EntityType.units, id: \.self) { t in row(t) }
                        Text("Buildings").font(.headline).padding(.top, 6)
                        ForEach(EntityType.buildings, id: \.self) { t in row(t) }
                    }
                    section("Bots", Difficulty.allCases.map { "• \($0.name): \($0.blurb)" }.joined(separator: "\n") +
                            "\nEach bot plays a style: Balanced, Rusher (early pressure), Turtle (turrets and tanks) or Mechanic (vehicles).")
                }
                .padding(.bottom, 20)
            }
        }
        .padding(20)
    }

    private func section(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            Text(body).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func row(_ t: EntityType) -> some View {
        let s = t.stats
        return HStack(alignment: .top, spacing: 10) {
            Image(uiImage: Art.icon(t, .blue)).resizable().frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(s.name) — \(s.cost) crystals\(s.supply > 0 ? ", \(s.supply) supply" : "")").font(.callout.bold())
                Text(s.blurb).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
