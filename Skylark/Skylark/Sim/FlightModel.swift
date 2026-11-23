import Foundation
import simd

/// What the pilot is asking for.
struct ControlInput {
    /// 1 is the stick fully back (nose up), -1 fully forward.
    var pitch: Float = 0
    /// 1 is the stick fully right.
    var roll: Float = 0
    /// 1 is full right rudder or pedal.
    var yaw: Float = 0
    /// 0 to 1. The throttle of a plane, the collective (lift) of a helicopter.
    var throttle: Float = 0
}

/// Where the aircraft is and how it is moving. Metres and seconds; x east, y up, z south.
/// The aircraft's own axes are x forward, y up, z right.
struct AircraftState {
    var position = SIMD3<Float>(0, 0, 0)
    var velocity = SIMD3<Float>(0, 0, 0)
    var orientation = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
    /// Turning rates about the aircraft's own axes, radians a second.
    var angularVelocity = SIMD3<Float>(0, 0, 0)
    var onGround = false

    var forward: SIMD3<Float> { orientation.act(SIMD3<Float>(1, 0, 0)) }
    var up: SIMD3<Float> { orientation.act(SIMD3<Float>(0, 1, 0)) }
    var right: SIMD3<Float> { orientation.act(SIMD3<Float>(0, 0, 1)) }
}

/// A kind of aircraft: how it answers the controls in the air and on the ground.
///
/// To add a new kind (a glider, an airship): write a type that conforms and add it to `FlightModels.all` under the
/// name aircraft files will use for "type".
protocol FlightModel {
    init(_ flight: AircraftSpec.Flight)
    /// Moves the aircraft through `dt` seconds of flight. Also called on the ground, before `taxi`.
    mutating func fly(_ state: inout AircraftState, input: ControlInput, dt: Float)
    /// Called after `fly` while the wheels or skids are on the ground, to keep it there sensibly.
    mutating func taxi(_ state: inout AircraftState, input: ControlInput, dt: Float)
    /// The hardest touchdown it survives, metres a second downwards.
    var hardestLanding: Float { get }
    /// The wing has stopped flying.
    var isStalled: Bool { get }
    /// The throttle a flight that starts in the air begins with, and its speed in metres a second.
    var cruise: (throttle: Float, speed: Float) { get }
    /// What the left slider is called.
    var throttleName: String { get }
}

enum FlightModels {
    static let all: [String: (AircraftSpec.Flight) -> FlightModel] = [
        "plane": { PlaneFlight($0) },
        "helicopter": { HelicopterFlight($0) },
    ]

    static func make(_ spec: AircraftSpec) -> FlightModel {
        (all[spec.type] ?? all["plane"]!)(spec.flight ?? AircraftSpec.Flight())
    }
}

enum Units {
    static let gravity: Float = 9.81
    static let knot: Float = 0.5144   // metres a second
    static let foot: Float = 0.3048
}

/// Heading, nose-up and bank angles of an orientation, in radians.
/// Heading turns anticlockwise seen from above, starting from east (the world's x).
enum Attitude {
    static func angles(_ q: simd_quatf) -> (heading: Float, pitch: Float, roll: Float) {
        let forward = q.act(SIMD3<Float>(1, 0, 0)), up = q.act(SIMD3<Float>(0, 1, 0))
        let pitch = asin(min(max(forward.y, -1), 1))
        let heading = atan2(-forward.z, forward.x)
        var levelRight = simd_cross(forward, SIMD3<Float>(0, 1, 0))
        if simd_length(levelRight) < 0.001 { levelRight = q.act(SIMD3<Float>(0, 0, 1)) }
        levelRight = simd_normalize(levelRight)
        let levelUp = simd_cross(levelRight, forward)
        return (heading, pitch, atan2(simd_dot(up, levelRight), simd_dot(up, levelUp)))
    }

    static func orientation(heading: Float, pitch: Float, roll: Float) -> simd_quatf {
        simd_quatf(angle: heading, axis: SIMD3<Float>(0, 1, 0)) * simd_quatf(angle: pitch, axis: SIMD3<Float>(0, 0, 1))
            * simd_quatf(angle: roll, axis: SIMD3<Float>(1, 0, 0))
    }

    /// Compass heading in degrees: 0 north (the world's -z), 90 east.
    static func compass(_ q: simd_quatf) -> Float {
        let forward = q.act(SIMD3<Float>(1, 0, 0))
        let degrees = atan2(forward.x, -forward.z) * 180 / .pi
        return degrees < 0 ? degrees + 360 : degrees
    }
}
