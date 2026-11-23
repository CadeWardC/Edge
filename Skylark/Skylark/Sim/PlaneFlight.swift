import Foundation
import simd

/// A fixed-wing aircraft.
///
/// The wing's lift grows with the angle it meets the air at, until it stalls; drag grows with speed and with lift.
/// The numbers are worked out from the file's stall speed, top speed and power, so those three come out true:
/// it stops flying at the stall speed and tops out, level at full throttle, at the top speed.
struct PlaneFlight: FlightModel {
    private static let maxLift: Float = 1.4          // lift coefficient at the stall
    private static let stallAngle: Float = 0.26      // 15 degrees
    private static let restLift: Float = 0.25        // lift coefficient with the nose on the airflow

    private let stallSpeed: Float
    private let topSpeed: Float
    private let thrust: Float
    private let liftFactor: Float
    private let drag: Float
    private let inducedDrag: Float
    private let rollRate: Float
    private let pitchRate: Float
    private let yawRate: Float
    private(set) var isStalled = false

    let hardestLanding: Float = 5.5
    let throttleName = "Throttle"
    var cruise: (throttle: Float, speed: Float) { (0.7, stallSpeed + (topSpeed - stallSpeed) * 0.6) }

    init(_ flight: AircraftSpec.Flight) {
        stallSpeed = Float(min(max(flight.stallSpeed ?? 45, 20), 200)) * Units.knot
        topSpeed = max(Float(min(flight.topSpeed ?? 120, 700)) * Units.knot, stallSpeed * 1.5)
        thrust = Float(min(max(flight.power ?? 0.35, 0.1), 2)) * Units.gravity
        rollRate = Float(min(max(flight.rollRate ?? 80, 15), 360)) * .pi / 180
        pitchRate = Float(min(max(flight.pitchRate ?? 40, 10), 120)) * .pi / 180
        yawRate = Float(min(max(flight.yawRate ?? 20, 5), 90)) * .pi / 180
        // at the stall speed, full lift just holds the weight
        liftFactor = Units.gravity / (Self.maxLift * stallSpeed * stallSpeed)
        inducedDrag = liftFactor / (.pi * 6)
        // at the top speed, full thrust just balances the drag
        let liftAtTop = Self.maxLift * (stallSpeed / topSpeed) * (stallSpeed / topSpeed)
        let all = thrust / (topSpeed * topSpeed)
        drag = max(all - inducedDrag * liftAtTop * liftAtTop, all * 0.15)
    }

    mutating func fly(_ state: inout AircraftState, input: ControlInput, dt: Float) {
        let speed = simd_length(state.velocity)
        let local = state.orientation.inverse.act(state.velocity)
        let moving = speed > 3
        let attack: Float = moving ? atan2(-local.y, local.x) : 0
        let rawSlip: Float = atan2(local.z, max(abs(local.x), 0.1))
        let slip: Float = moving ? min(max(rawSlip, -0.6), 0.6) : 0

        let slope: Float = (Self.maxLift - Self.restLift) / Self.stallAngle
        var lift: Float = Self.restLift + slope * attack
        if attack > Self.stallAngle {
            lift = max(Self.maxLift - 2.8 * (attack - Self.stallAngle), 0.45)
            if attack > 1.2 { lift = 0.2 }
        }
        lift = max(lift, -0.9)
        if abs(attack) > 1.5 { lift = 0 }   // going backwards
        isStalled = moving && attack > Self.stallAngle && !state.onGround

        let push: Float = thrust * min(max(input.throttle, 0), 1)
        var acceleration = SIMD3<Float>(0, -Units.gravity, 0) + state.forward * push
        if moving {
            let direction = state.velocity / speed
            let pressure = speed * speed
            let liftDirection = simd_cross(state.right, direction)
            if simd_length(liftDirection) > 0.001 {
                let liftForce: Float = liftFactor * pressure * lift
                acceleration += simd_normalize(liftDirection) * liftForce
            }
            let sinAttack: Float = sin(attack), sinStall: Float = sin(Self.stallAngle)
            let broadside: Float = max(0, sinAttack * sinAttack - sinStall * sinStall)
            let dragFactor: Float = drag + inducedDrag * lift * lift + liftFactor * 1.5 * broadside
            let dragForce: Float = dragFactor * pressure
            let sideForce: Float = liftFactor * 2 * pressure * sin(slip)
            acceleration -= direction * dragForce
            acceleration -= state.right * sideForce
        }
        state.velocity += acceleration * dt
        state.position += state.velocity * dt

        // the controls bite harder the faster the air flows over them, and pitch is held to about 6 g
        let relative: Float = speed / (0.9 * stallSpeed)
        let grip: Float = min(1, relative * relative)
        let steady: Float = min(1, speed / stallSpeed)
        let pitchLimit: Float = min(pitchRate, 6 * Units.gravity / max(speed, 1))
        let wantedRoll: Float = curve(input.roll) * rollRate * grip
        let wantedYaw: Float = -curve(input.yaw) * yawRate * grip
        let wantedPitch: Float = curve(input.pitch) * pitchLimit * grip
        var wanted = SIMD3<Float>(wantedRoll, wantedYaw, wantedPitch)
        if moving && !state.onGround {
            // past the stall the nose drops; a sideslip swings the nose into the wind, which is what turns a banked plane
            let excess = attack - min(max(attack, -0.1), 0.17)
            wanted.z -= 2 * excess * steady
            wanted.y -= 1.6 * slip * steady
        }
        state.angularVelocity += (wanted - state.angularVelocity) * min(1, 8 * dt)
        let turn = simd_length(state.angularVelocity) * dt
        if turn > 1e-6 {
            state.orientation = simd_normalize(state.orientation * simd_quatf(angle: turn, axis: simd_normalize(state.angularVelocity)))
        }
    }

    mutating func taxi(_ state: inout AircraftState, input: ControlInput, dt: Float) {
        var (heading, pitch, roll) = Attitude.angles(state.orientation)
        roll *= exp(-10 * dt)
        pitch = min(max(pitch, 0), 0.28)   // the nose can lift to take off, not dig in
        var ground = SIMD3<Float>(state.velocity.x, 0, state.velocity.z)
        let speed = simd_length(ground)
        if speed < stallSpeed * 0.5 { pitch *= exp(-3 * dt) }
        // rudder steers the wheels; the stick helps
        let steer: Float = min(max(input.yaw + 0.6 * input.roll, -1), 1)
        heading -= steer * 0.7 * min(1, speed / 4) * dt
        state.orientation = Attitude.orientation(heading: heading, pitch: pitch, roll: roll)
        state.angularVelocity.x = 0
        state.angularVelocity.y = 0

        // wheels do not slide sideways; they roll, and brake when the throttle is closed
        let side = SIMD3<Float>(sin(heading), 0, cos(heading))
        ground -= side * simd_dot(ground, side) * min(1, 12 * dt)
        let braking: Float = input.throttle < 0.05 ? 5.4 : 0.4
        let slowing: Float = braking * dt
        let left = simd_length(ground)
        ground = left > slowing ? ground * ((left - slowing) / left) : .zero
        state.velocity.x = ground.x
        state.velocity.z = ground.z
    }

    /// Gentle near the middle of the stick, full at its edge.
    private func curve(_ value: Float) -> Float {
        let v = min(max(value, -1), 1)
        return v * (0.45 + 0.55 * abs(v))
    }
}
