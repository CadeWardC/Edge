import Foundation
import simd

/// A helicopter. The slider is the collective: how hard the rotor lifts, straight up out of the top of the aircraft.
/// The stick leans the aircraft, which leans the lift and so moves it; let go and it levels itself.
struct HelicopterFlight: FlightModel {
    private let lift: Float
    private let drag: Float
    private let agility: Float
    private let yawRate: Float
    private let topSpeed: Float
    private static let maxLean: Float = 0.44

    let hardestLanding: Float = 4
    let isStalled = false
    let throttleName = "Lift"
    var cruise: (throttle: Float, speed: Float) { (Units.gravity / lift, 0) }

    init(_ flight: AircraftSpec.Flight) {
        topSpeed = Float(min(max(flight.topSpeed ?? 100, 30), 500)) * Units.knot
        lift = Float(min(max(flight.power ?? 1.5, 1.15), 4)) * Units.gravity
        agility = Float(min(max(flight.agility ?? 1, 0.3), 3))
        yawRate = Float(min(max(flight.yawRate ?? 60, 10), 240)) * .pi / 180
        // leaning fully forward at hover lift, drag stops it at the top speed
        drag = Units.gravity * tan(Self.maxLean) / (topSpeed * topSpeed)
    }

    mutating func fly(_ state: inout AircraftState, input: ControlInput, dt: Float) {
        var (heading, pitch, roll) = Attitude.angles(state.orientation)
        if !state.onGround {
            let follow = min(1, 2.6 * agility * dt)
            let wantedPitch: Float = min(max(input.pitch, -1), 1) * Self.maxLean
            let wantedRoll: Float = min(max(input.roll, -1), 1) * 0.5
            let pedal: Float = min(max(input.yaw, -1), 1)
            pitch += (wantedPitch - pitch) * follow
            roll += (wantedRoll - roll) * follow
            heading -= pedal * yawRate * dt
            // in forward flight the tail swings round behind, like a weathervane
            let ground = SIMD3<Float>(state.velocity.x, 0, state.velocity.z)
            let speed = simd_length(ground)
            if speed > 8 {
                let sideways: Float = simd_dot(ground, state.right) / speed
                heading -= sideways * 0.9 * min(1, speed / 20) * dt
            }
        }
        state.orientation = Attitude.orientation(heading: heading, pitch: pitch, roll: roll)
        state.angularVelocity = .zero

        let speed = simd_length(state.velocity)
        let rotor: Float = lift * min(max(input.throttle, 0), 1)
        let resistance: Float = drag * speed
        var acceleration = SIMD3<Float>(0, -Units.gravity, 0) + state.up * rotor
        acceleration -= state.velocity * resistance
        acceleration.y -= 1.2 * state.velocity.y   // the rotor disc resists rising and sinking
        state.velocity += acceleration * dt
        state.position += state.velocity * dt
    }

    mutating func taxi(_ state: inout AircraftState, input: ControlInput, dt: Float) {
        var (heading, pitch, roll) = Attitude.angles(state.orientation)
        pitch *= exp(-8 * dt)
        roll *= exp(-8 * dt)
        let pedal: Float = min(max(input.yaw, -1), 1)
        heading -= pedal * yawRate * 0.5 * dt
        state.orientation = Attitude.orientation(heading: heading, pitch: pitch, roll: roll)
        let grip = exp(-6 * dt)
        state.velocity.x *= grip
        state.velocity.z *= grip
    }
}
