import SceneKit
import UIKit

/// What the instruments show.
struct Telemetry: Equatable {
    var speed = 0          // knots
    var altitude = 0       // feet above the sea
    var aboveGround = 0    // feet
    var heading = 0        // degrees
    var climb = 0          // feet a minute
    var stalled = false
    var onGround = true
    var ringsDone = 0
    var ringsTotal = 0
}

enum CameraView: String, CaseIterable {
    case chase, cockpit
}

enum StartPlace {
    case runway(Int)
    case air(Int)
    /// Parked, with the camera circling: behind the menu.
    case showcase(Int)
}

/// Flies the aircraft: steps the physics, decides landings and crashes, and moves the 3D scene to match.
///
/// SceneKit calls `renderer(_:updateAtTime:)` on its own thread once a frame; everything that touches the scene or the
/// flight happens there. The screens talk to it only through the few locked properties and `send`.
final class FlightSimulator: NSObject, ObservableObject, SCNSceneRendererDelegate {
    @Published private(set) var telemetry = Telemetry()
    /// Why the flight ended, when it has.
    @Published private(set) var crash: String?
    /// A passing note: a landing, a ring.
    @Published private(set) var note: String?
    @Published private(set) var throttleName = "Throttle"

    let scene = SCNScene()
    let terrain = Terrain()
    let cameraNode = SCNNode()

    private let lock = NSLock()
    private var sharedInput = ControlInput()
    private var sharedPaused = false
    private var sharedView = CameraView.chase
    private var commands: [() -> Void] = []

    // everything below belongs to the render thread
    private var built: BuiltAircraft?
    private var model: FlightModel = PlaneFlight(AircraftSpec.Flight())
    private var state = AircraftState()
    private let shadow = SCNNode()
    private var sea = SCNNode()
    private var rings: [Ring] = []
    private var nextRing = 0
    private var ringSide: Float = -1
    private var ringClock: Float = 0
    private var showcase = false
    private var crashed = false
    private var airborneFor: Float = 0
    private var lastTime: TimeInterval = 0
    private var spin: Float = 0
    private var orbit: Float = 0
    private var cameraHeading = SIMD3<Float>(1, 0, 0)
    private var cameraPosition = SIMD3<Float>(0, 100, 0)
    private var sinceReport: Float = 1

    override init() {
        super.init()
        let world = WorldBuilder.build(scene, terrain: terrain)
        sea = world.sea
        rings = world.rings

        let camera = SCNCamera()
        camera.zNear = 3
        camera.zFar = 30000
        camera.fieldOfView = 62
        cameraNode.camera = camera
        scene.rootNode.addChildNode(cameraNode)

        let blob = SCNPlane(width: 1, height: 1)
        blob.cornerRadius = 0.5
        blob.firstMaterial?.diffuse.contents = UIColor.black
        blob.firstMaterial?.lightingModel = .constant
        blob.firstMaterial?.writesToDepthBuffer = false
        shadow.geometry = blob
        shadow.renderingOrder = 5
        scene.rootNode.addChildNode(shadow)
    }

    // MARK: From the screens (main thread)

    var input: ControlInput {
        get { lock.withLock { sharedInput } }
        set { lock.withLock { sharedInput = newValue } }
    }

    var paused: Bool {
        get { lock.withLock { sharedPaused } }
        set { lock.withLock { sharedPaused = newValue } }
    }

    var view: CameraView {
        get { lock.withLock { sharedView } }
        set { lock.withLock { sharedView = newValue } }
    }

    /// Puts an aircraft at a starting place. Returns the throttle the flight begins with, for the slider.
    @discardableResult
    func begin(_ spec: AircraftSpec, at place: StartPlace) -> Float {
        let fresh = FlightModels.make(spec)
        var throttle: Float = 0
        if case .air = place { throttle = fresh.cruise.throttle }
        crash = nil
        note = nil
        throttleName = fresh.throttleName
        lock.withLock {
            sharedInput = ControlInput(throttle: throttle)
            commands.append { [weak self] in self?.start(spec, model: fresh, at: place) }
        }
        return throttle
    }

    // MARK: Starting (render thread)

    private func start(_ spec: AircraftSpec, model fresh: FlightModel, at place: StartPlace) {
        built?.node.removeFromParentNode()
        let aircraft = AircraftBuilder.build(spec)
        scene.rootNode.addChildNode(aircraft.node)
        built = aircraft
        model = fresh
        crashed = false
        airborneFor = 0
        showcase = false
        state = AircraftState()

        let index: Int
        switch place {
        case .runway(let i), .air(let i), .showcase(let i): index = i
        }
        let airport = terrain.airports[min(max(index, 0), terrain.airports.count - 1)]
        state.orientation = Attitude.orientation(heading: airport.heading, pitch: 0, roll: 0)
        switch place {
        case .runway, .showcase:
            state.position = airport.point(along: -airport.length / 2 + 70, across: 0, height: Terrain.runwayThickness + aircraft.gearHeight)
            state.onGround = true
            if case .showcase = place { showcase = true }
        case .air:
            state.position = airport.point(along: -2500, across: 0, height: 450)
            state.velocity = airport.axis * fresh.cruise.speed
        }
        cameraHeading = airport.axis
        cameraPosition = state.position - airport.axis * (aircraft.radius * 4) + SIMD3<Float>(0, aircraft.radius, 0)

        nextRing = 0
        ringClock = 0
        ringSide = -1
        paintRings()
        sinceReport = 1
    }

    private func paintRings() {
        for (index, ring) in rings.enumerated() {
            ring.node.isHidden = index < nextRing || showcase
            let color = index == nextRing ? UIColor(red: 0.2, green: 1, blue: 0.4, alpha: 1) : UIColor(red: 1, green: 0.82, blue: 0.2, alpha: 1)
            ring.node.geometry?.firstMaterial?.diffuse.contents = color
            ring.node.opacity = index == nextRing ? 1 : 0.45
        }
    }

    // MARK: Every frame (render thread)

    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        let frame = lastTime == 0 ? 0 : Float(min(max(time - lastTime, 0), 1.0 / 20))
        lastTime = time

        let (pending, input, paused, view): ([() -> Void], ControlInput, Bool, CameraView) = lock.withLock {
            let pending = commands
            commands = []
            return (pending, sharedInput, sharedPaused, sharedView)
        }
        pending.forEach { $0() }
        guard let built else { return }

        if !paused && !crashed && !showcase {
            let steps = 2
            for _ in 0..<steps {
                step(input, dt: frame / Float(steps), gear: built.gearHeight)
                if crashed { break }
            }
            checkRings(frame)
        }
        if !paused {
            spin += frame * (crashed ? 0 : (showcase ? 0.25 : 0.3 + 0.7 * input.throttle))
            orbit += frame * 0.2
        }

        built.node.simdPosition = state.position
        built.node.simdOrientation = state.orientation
        for spinner in built.spinners {
            spinner.node.simdOrientation = simd_quatf(angle: spin * spinner.rate, axis: spinner.axis)
        }
        placeShadow(built)
        placeCamera(built, view: view, dt: frame)
        sea.simdPosition = SIMD3<Float>(cameraNode.simdPosition.x, 0, cameraNode.simdPosition.z)

        sinceReport += frame
        if sinceReport >= 0.1 {
            sinceReport = 0
            report(built)
        }
    }

    private func step(_ input: ControlInput, dt: Float, gear: Float) {
        guard dt > 0 else { return }
        let before = state.velocity
        model.fly(&state, input: input, dt: dt)
        let ground = terrain.ground(state.position.x, state.position.z)
        let floor = ground.height + gear

        if state.position.y <= floor {
            if !state.onGround {
                let sink = max(-simd_dot(before, ground.normal), 0)
                if let reason = whyCrashed(ground, sink: sink) {
                    state.position.y = floor
                    end(reason)
                    return
                }
                if airborneFor > 2 { announceLanding(sink) }
            } else if ground.isWater {
                state.position.y = floor
                end("Rolled into the sea")
                return
            }
            state.position.y = floor
            if state.velocity.y < 0 { state.velocity.y = 0 }
            state.onGround = true
            airborneFor = 0
            model.taxi(&state, input: input, dt: dt)
        } else if state.position.y > floor + 0.3 {
            state.onGround = false
            airborneFor += dt
        }
    }

    private func whyCrashed(_ ground: Ground, sink: Float) -> String? {
        let attitude = Attitude.angles(state.orientation)
        if ground.isWater { return "Went into the sea" }
        if ground.normal.y < 0.9 { return "Flew into a hillside" }
        if sink > model.hardestLanding { return "Hit the ground too hard: \(Int(sink / Units.foot * 60)) feet a minute" }
        if abs(attitude.roll) > 0.45 { return "A wing hit the ground" }
        if attitude.pitch < -0.2 { return "Landed on the nose" }
        if attitude.pitch > 0.5 { return "Landed on the tail" }
        return nil
    }

    private func end(_ reason: String) {
        crashed = true
        state.velocity = .zero
        state.angularVelocity = .zero
        DispatchQueue.main.async {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            self.crash = reason
        }
    }

    private func announceLanding(_ sink: Float) {
        let rate = Int(sink / Units.foot * 60)
        let how = rate < 150 ? "smooth as butter" : (rate < 350 ? "a good one" : "firm")
        let place = terrain.isOnRunway(state.position.x, state.position.z) ? "on the runway" : "off the runway"
        show("Landed \(place) at \(rate) feet a minute: \(how)")
    }

    private func show(_ text: String) {
        DispatchQueue.main.async {
            self.note = text
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                if self?.note == text { self?.note = nil }
            }
        }
    }

    private func checkRings(_ dt: Float) {
        guard nextRing < rings.count else { return }
        if nextRing > 0 || !state.onGround { ringClock += dt }
        let ring = rings[nextRing]
        let offset = state.position - ring.center
        let side = simd_dot(offset, ring.direction)
        if ringSide < 0, side >= 0, simd_length(offset - ring.direction * side) < Ring.radius {
            nextRing += 1
            paintRings()
            DispatchQueue.main.async { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
            if nextRing == rings.count {
                show(String(format: "All %d rings in %d:%02d. Now land it.", rings.count, Int(ringClock) / 60, Int(ringClock) % 60))
            }
            ringSide = -1
            return
        }
        ringSide = side
    }

    private func report(_ built: BuiltAircraft) {
        let ground = terrain.ground(state.position.x, state.position.z)
        var now = Telemetry()
        now.speed = Int((simd_length(state.velocity) / Units.knot).rounded())
        now.altitude = Int((state.position.y / Units.foot / 10).rounded()) * 10
        now.aboveGround = max(0, Int(((state.position.y - built.gearHeight - ground.height) / Units.foot).rounded()))
        now.heading = Int(Attitude.compass(state.orientation).rounded()) % 360
        now.climb = Int((state.velocity.y / Units.foot * 60 / 50).rounded()) * 50
        now.stalled = model.isStalled && !crashed
        now.onGround = state.onGround
        now.ringsDone = nextRing
        now.ringsTotal = rings.count
        DispatchQueue.main.async {
            if self.telemetry != now { self.telemetry = now }
        }
    }

    // MARK: Shadow and camera

    /// A soft dark patch straight below: the best cue for how high the wheels are.
    private func placeShadow(_ built: BuiltAircraft) {
        let ground = terrain.ground(state.position.x, state.position.z)
        let above = state.position.y - built.gearHeight - ground.height
        let heading = Attitude.angles(state.orientation).heading
        shadow.simdPosition = SIMD3<Float>(state.position.x, ground.height + 0.2, state.position.z)
        shadow.simdOrientation = simd_quatf(angle: heading, axis: SIMD3<Float>(0, 1, 0)) * simd_quatf(angle: -.pi / 2, axis: SIMD3<Float>(1, 0, 0))
        let spread = 1 + max(above, 0) / 80
        shadow.simdScale = SIMD3<Float>(built.length * spread, built.span * spread, 1)
        shadow.opacity = CGFloat(0.4 * max(0, 1 - above / 200))
    }

    private func placeCamera(_ built: BuiltAircraft, view: CameraView, dt: Float) {
        let up = SIMD3<Float>(0, 1, 0)
        if showcase || crashed {
            built.node.isHidden = false
            let distance = built.radius * (crashed ? 5 : 3.2)
            cameraPosition = state.position + SIMD3<Float>(cos(orbit) * distance, built.radius * 1.1 + 1, sin(orbit) * distance)
            cameraNode.simdPosition = aboveGround(cameraPosition)
            cameraNode.simdLook(at: state.position, up: up, localFront: SIMD3<Float>(0, 0, -1))
            return
        }
        switch view {
        case .cockpit:
            built.node.isHidden = true
            cameraNode.simdPosition = state.position + state.orientation.act(built.cockpit)
            cameraNode.simdOrientation = state.orientation * simd_quatf(angle: -.pi / 2, axis: up)
        case .chase:
            built.node.isHidden = false
            // follow the way it points over the ground, so banks and climbs can be seen
            let flat = SIMD3<Float>(state.forward.x, 0, state.forward.z)
            if simd_length(flat) > 0.2 {
                cameraHeading = simd_normalize(cameraHeading + (simd_normalize(flat) - cameraHeading) * min(1, 3 * dt))
            }
            let wanted = state.position - cameraHeading * (built.radius * 3.4 + 4) + SIMD3<Float>(0, built.radius * 0.9 + 1.5, 0)
            cameraPosition += (wanted - cameraPosition) * min(1, 6 * dt)
            cameraNode.simdPosition = aboveGround(cameraPosition)
            cameraNode.simdLook(at: state.position + SIMD3<Float>(0, built.radius * 0.35, 0), up: up, localFront: SIMD3<Float>(0, 0, -1))
        }
    }

    private func aboveGround(_ point: SIMD3<Float>) -> SIMD3<Float> {
        var point = point
        point.y = max(point.y, terrain.ground(point.x, point.z).height + 2)
        return point
    }
}
