import CoreGraphics
import Foundation

/// Where the aircraft is in the air. The game moves it forward; a flight model moves it up and down.
struct FlightState {
    var y: CGFloat = 220
    var verticalSpeed: CGFloat = 0
    /// How far the nose points up, in radians. Only for looks.
    var pitch: CGFloat = 0
}

/// How a kind of aircraft answers a finger on the screen.
///
/// To add a new kind (a glider, a rocket, a balloon): write a type that conforms, then add it to `FlightModels.all`
/// under the name aircraft files will use for "type".
protocol FlightModel {
    init(stats: AircraftSpec.Stats)
    /// Moves the aircraft through `dt` seconds. `holding` is true while a finger is down.
    mutating func step(_ state: inout FlightState, holding: Bool, dt: CGFloat)
}

enum FlightModels {
    static let all: [String: (AircraftSpec.Stats) -> FlightModel] = [
        "plane": { PlaneFlight(stats: $0) },
        "helicopter": { HelicopterFlight(stats: $0) },
    ]
}

/// Hold to pull the nose up, let go to push it down. Height follows the nose.
struct PlaneFlight: FlightModel {
    static let maxPitch: CGFloat = 0.5
    private let climbRate: CGFloat
    private let pitchRate: CGFloat

    init(stats: AircraftSpec.Stats) {
        climbRate = 190 * CGFloat(stats.climb)
        pitchRate = 2.1 * CGFloat(stats.agility)
    }

    mutating func step(_ state: inout FlightState, holding: Bool, dt: CGFloat) {
        let target = holding ? Self.maxPitch : -Self.maxPitch
        let change = min(max(target - state.pitch, -pitchRate * dt), pitchRate * dt)
        state.pitch += change
        state.verticalSpeed = climbRate * state.pitch / Self.maxPitch
        state.y += state.verticalSpeed * dt
    }
}

/// Hold for lift, let go and gravity wins. It drifts, so it has to be caught early.
struct HelicopterFlight: FlightModel {
    private let lift: CGFloat
    private let gravity: CGFloat
    private let drag: CGFloat = 1.3
    private let maxSpeed: CGFloat

    init(stats: AircraftSpec.Stats) {
        let agility = CGFloat(stats.agility)
        lift = 520 * CGFloat(stats.climb) * agility
        gravity = 430 * agility
        maxSpeed = 230 * CGFloat(stats.climb).squareRoot()
    }

    mutating func step(_ state: inout FlightState, holding: Bool, dt: CGFloat) {
        state.verticalSpeed += (holding ? lift : -gravity) * dt
        state.verticalSpeed *= exp(-drag * dt)
        state.verticalSpeed = min(max(state.verticalSpeed, -maxSpeed), maxSpeed)
        state.y += state.verticalSpeed * dt
        // nose a little down, the way a helicopter leans into its flight
        state.pitch = -0.1 + min(max(state.verticalSpeed / 1400, -0.12), 0.12)
    }
}
