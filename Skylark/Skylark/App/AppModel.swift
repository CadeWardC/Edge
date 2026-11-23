import Combine
import SwiftUI

/// Which screen is up, which aircraft and airport are chosen, and the controls' positions.
final class AppModel: ObservableObject {
    enum Phase { case menu, flying }

    @Published private(set) var phase = Phase.menu
    @Published private(set) var selectedID: String
    @Published var airport: Int { didSet { defaults.set(airport, forKey: "airport"); if phase == .menu { park() } } }
    @Published var paused = false { didSet { simulator.paused = paused } }
    @Published var view = CameraView.chase { didSet { simulator.view = view } }
    @Published var throttle: Float = 0 { didSet { push() } }

    let catalog = AircraftCatalog()
    let simulator = FlightSimulator()

    private var stick = CGPoint.zero
    private var rudder: Float = 0
    private var lastStart = StartPlace.runway(0)
    private let defaults = UserDefaults.standard
    private var cancellables: Set<AnyCancellable> = []

    init() {
        selectedID = defaults.string(forKey: "selected") ?? "sky-hopper"
        airport = defaults.integer(forKey: "airport")
        // aircraft files can change or vanish when the player reloads them
        catalog.$aircraft
            .sink { [weak self] list in
                guard let self, self.phase == .menu else { return }
                if !list.contains(where: { $0.id == self.selectedID }), let first = list.first { self.selectedID = first.id }
                self.park(from: list)
            }
            .store(in: &cancellables)
    }

    var selected: AircraftSpec? {
        catalog.aircraft.first { $0.id == selectedID } ?? catalog.aircraft.first
    }

    func select(_ spec: AircraftSpec) {
        selectedID = spec.id
        defaults.set(spec.id, forKey: "selected")
        if phase == .menu { park() }
    }

    /// Shows the chosen aircraft parked on the runway behind the menu.
    private func park(from list: [AircraftSpec]? = nil) {
        let aircraft = list ?? catalog.aircraft
        guard let spec = aircraft.first(where: { $0.id == selectedID }) ?? aircraft.first else { return }
        simulator.begin(spec, at: .showcase(airport))
    }

    func fly(inTheAir: Bool) {
        start(inTheAir ? .air(airport) : .runway(airport))
    }

    func again() {
        start(lastStart)
    }

    private func start(_ place: StartPlace) {
        guard let spec = selected else { return }
        lastStart = place
        stick = .zero
        rudder = 0
        paused = false
        phase = .flying
        throttle = simulator.begin(spec, at: place)
    }

    func backToMenu() {
        paused = false
        phase = .menu
        stick = .zero
        rudder = 0
        throttle = 0
        park()
    }

    // MARK: Controls

    /// The stick: x is right, y is back (towards the pilot), each -1 to 1.
    func moveStick(_ point: CGPoint) {
        stick = point
        push()
    }

    func moveRudder(_ value: Float) {
        rudder = value
        push()
    }

    private func push() {
        guard phase == .flying else { return }
        simulator.input = ControlInput(pitch: Float(stick.y), roll: Float(stick.x), yaw: rudder, throttle: throttle)
    }
}
