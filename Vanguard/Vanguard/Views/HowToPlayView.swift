import SwiftUI

struct HowToPlayView: View {
    var onBack: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                ScreenTitle("How to Play")
                Spacer()
                Button("Back", action: onBack).buttonStyle(SecondaryButtonStyle())
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
                    section("Command", """
                    • Auto-train: select a Barracks, Factory or Command Center, tap Auto, then a unit. It keeps training that \
                    unit whenever you can afford it (marked ↻). Tap Auto off to stop.
                    • Retreat: selected units run to your nearest Command Center 30% faster, without stopping to fight.
                    • Orbital Strike (bolt button, needs a Tech Lab, 125 crystals): tap it, then the map. After 2.5 s it hits \
                    enemies in a wide circle. Everyone who can see the spot gets a warning marker, so move out of it.
                    • Scan (eye button, needs a Radar Tower, 50 crystals): reveals an area for 12 s, cliffs included.
                    • Tap an "under attack" message to jump there. Select a turret or sieged tank to see its range.
                    """)
                    section("Terrain", """
                    • High ground: main bases sit on plateaus ringed by cliffs, reached by a ramp. Units below can't see \
                    up a cliff (so they can't shoot what's up there) unless something gives them vision: a unit on top, \
                    a gunship, a Radar Tower or a watch tower. Shooting uphill does 25% less damage.
                    • Watch towers: keep a ground unit next to one (and no enemy) to see far around it, cliffs included.
                    • Violet crystals are rich: 12 per trip instead of 8. They sit at exposed expansions.
                    • Forests, rocks, water and lava block movement; only gunships fly over them.
                    """)
                    section("Buildings", """
                    • Specialize each Command Center, Barracks and Factory once, choosing one of two options:
                      Command Center: Fortress (heavy gun, +600 HP) or Refinery (+25% crystals delivered there).
                      Barracks: Drill Yard (trains 60% faster) or Armory (infantry +25% HP).
                      Factory: Assembly Line (50% faster) or Reactive Armor (vehicles +2 armor).
                    • Radar Tower: sees 640 around it and up cliffs. Shield Generator: friends within 230 take 30% less damage.
                    • Drones repair buildings and vehicles: tap Repair, then the target (or tap a damaged building with drones selected).
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
