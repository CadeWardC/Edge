import Combine
import SwiftUI

/// What the screens show and what is saved between flights: stars, best distance, the chosen and unlocked aircraft.
final class GameModel: ObservableObject {
    enum Phase { case menu, playing, crashed }

    @Published private(set) var phase = Phase.menu
    @Published private(set) var metres = 0
    @Published private(set) var runStars = 0
    @Published private(set) var isNewBest = false
    @Published var paused = false
    @Published private(set) var totalStars: Int
    @Published private(set) var best: Int
    @Published private(set) var selectedID: String
    @Published private(set) var unlocked: Set<String>

    let catalog = AircraftCatalog()
    let scene = GameScene(size: CGSize(width: 844, height: 390))

    private let defaults = UserDefaults.standard
    private var cancellables: Set<AnyCancellable> = []

    init() {
        totalStars = defaults.integer(forKey: "stars")
        best = defaults.integer(forKey: "best")
        selectedID = defaults.string(forKey: "selected") ?? "sky-hopper"
        unlocked = Set(defaults.stringArray(forKey: "unlocked") ?? [])

        scene.onProgress = { [weak self] metres, stars in
            self?.metres = metres
            self?.runStars = stars
        }
        scene.onCrash = { [weak self] metres, stars in self?.finish(metres: metres, stars: stars) }
        // aircraft files can change or vanish when the player reloads them
        catalog.$aircraft
            .sink { [weak self] list in self?.useSelected(from: list) }
            .store(in: &cancellables)
        scene.showMenu()
    }

    var selected: AircraftSpec? {
        catalog.aircraft.first { $0.id == selectedID } ?? catalog.aircraft.first { isUnlocked($0) }
    }

    func isUnlocked(_ spec: AircraftSpec) -> Bool {
        spec.cost == 0 || unlocked.contains(spec.id)
    }

    func select(_ spec: AircraftSpec) {
        guard isUnlocked(spec) else { return }
        selectedID = spec.id
        defaults.set(spec.id, forKey: "selected")
        scene.setAircraft(spec)
    }

    func unlock(_ spec: AircraftSpec) {
        guard !isUnlocked(spec), totalStars >= spec.cost else { return }
        totalStars -= spec.cost
        unlocked.insert(spec.id)
        defaults.set(totalStars, forKey: "stars")
        defaults.set(Array(unlocked), forKey: "unlocked")
        select(spec)
    }

    func play() {
        guard selected != nil else { return }
        metres = 0
        runStars = 0
        isNewBest = false
        paused = false
        phase = .playing
        scene.startRun()
    }

    func backToMenu() {
        paused = false
        phase = .menu
        scene.showMenu()
    }

    private func finish(metres: Int, stars: Int) {
        self.metres = metres
        runStars = stars
        totalStars += stars
        isNewBest = metres > best
        best = max(best, metres)
        defaults.set(totalStars, forKey: "stars")
        defaults.set(best, forKey: "best")
        phase = .crashed
    }

    private func useSelected(from list: [AircraftSpec]) {
        guard let spec = list.first(where: { $0.id == selectedID && isUnlocked($0) }) ?? list.first(where: { isUnlocked($0) }) else { return }
        if spec.id != selectedID { selectedID = spec.id }
        scene.setAircraft(spec)
    }
}
