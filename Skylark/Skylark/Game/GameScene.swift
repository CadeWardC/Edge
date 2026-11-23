import SpriteKit
import UIKit

/// The flying. Everything is laid out in a sky 400 units tall and scaled to the screen, so the game plays the same on
/// any device; wider screens just see further ahead.
final class GameScene: SKScene {
    enum Mode { case idle, flying, crashed }

    /// Distance in metres and stars so far, whenever either changes.
    var onProgress: ((Int, Int) -> Void)?
    var onCrash: ((Int, Int) -> Void)?

    private(set) var mode = Mode.idle

    private let sky = SKSpriteNode()
    private let root = SKNode()        // scaled to the screen
    private let sun = SKShapeNode(circleOfRadius: 26)
    private let farHills = SKShapeNode()
    private let world = SKNode()       // slides left as the aircraft flies
    private var clouds: [(node: SKNode, x: CGFloat, depth: CGFloat)] = []

    private var spec: AircraftSpec?
    private var aircraft = SKNode()
    private var hitbox = CGSize(width: 68, height: 20)
    private var flight: FlightModel = PlaneFlight(stats: AircraftSpec.Stats())
    private var stats = AircraftSpec.Stats()
    private var trailColor = UIColor.clear
    private var state = FlightState()

    private var terrain = Terrain()
    private var chunks: [Int: SKNode] = [:]
    private var entities: [Entity] = []
    private var nextSpawn: CGFloat = 700
    private var distance: CGFloat = 0
    private var stars = 0
    private var reported = (-1, -1)

    private var fingers = 0
    private var lastTime: TimeInterval = 0
    private var clock: CGFloat = 0
    private var trailTimer: CGFloat = 0
    /// A new flight stays level until the first touch (or a moment passes), so it does not start with a dive.
    private var armed = false
    private var runClock: CGFloat = 0
    private var viewWidth: CGFloat = 866   // in units
    private var aircraftX: CGFloat = 220   // where the aircraft sits on screen, in units

    private static let chunkWidth: CGFloat = 300
    private static let hillsPeriod: CGFloat = 1500

    override init(size: CGSize) {
        super.init(size: size)
        scaleMode = .resizeFill
        anchorPoint = .zero
        backgroundColor = UIColor(red: 0.45, green: 0.74, blue: 0.93, alpha: 1)
        build()
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("GameScene is made in code")
    }

    // MARK: Setting up

    private func build() {
        sky.texture = SKTexture(image: Self.skyImage())
        sky.anchorPoint = .zero
        sky.zPosition = -100
        addChild(sky)
        addChild(root)

        sun.fillColor = UIColor(red: 1, green: 0.93, blue: 0.6, alpha: 1)
        sun.strokeColor = UIColor(red: 1, green: 0.97, blue: 0.8, alpha: 0.6)
        sun.lineWidth = 8
        sun.zPosition = -50
        root.addChild(sun)

        for _ in 0..<7 {
            let cloud = Self.cloud(dark: false)
            let depth = CGFloat.random(in: 0.08...0.3)
            cloud.setScale(0.5 + depth * 2)
            cloud.alpha = 0.55 + depth
            cloud.position.y = CGFloat.random(in: 230...380)
            cloud.zPosition = -40
            root.addChild(cloud)
            clouds.append((cloud, CGFloat.random(in: 0..<2000), depth))
        }

        let hills = CGMutablePath()
        let length = Self.hillsPeriod + 1800
        hills.move(to: CGPoint(x: 0, y: -10))
        for x in stride(from: CGFloat(0), through: length, by: 20) {
            let turn = 2 * CGFloat.pi * x / Self.hillsPeriod
            hills.addLine(to: CGPoint(x: x, y: 105 + 45 * sin(turn * 3) + 22 * sin(turn * 7 + 1)))
        }
        hills.addLine(to: CGPoint(x: length, y: -10))
        hills.closeSubpath()
        farHills.path = hills
        farHills.fillColor = UIColor(red: 0.56, green: 0.76, blue: 0.78, alpha: 1)
        farHills.strokeColor = .clear
        farHills.zPosition = -30
        root.addChild(farHills)

        root.addChild(world)
        layout()
    }

    override func didChangeSize(_ oldSize: CGSize) {
        layout()
    }

    private func layout() {
        guard size.height > 0 else { return }
        let scale = size.height / Terrain.skyHeight
        root.setScale(scale)
        sky.size = size
        viewWidth = size.width / scale
        aircraftX = max(110, viewWidth * 0.27)
        sun.position = CGPoint(x: viewWidth - 110, y: 325)
    }

    func setAircraft(_ newSpec: AircraftSpec) {
        spec = newSpec
        stats = newSpec.tunedStats
        hitbox = AircraftArt.hitbox(newSpec)
        flight = (FlightModels.all[newSpec.type] ?? FlightModels.all["plane"]!)(stats)
        trailColor = AircraftArt.color(newSpec.trail)
        aircraft.removeFromParent()
        aircraft = AircraftArt.node(for: newSpec)
        aircraft.zPosition = 10
        aircraft.isHidden = mode == .crashed
        world.addChild(aircraft)
    }

    /// Flies by itself behind the menu.
    func showMenu() {
        reset()
        mode = .idle
    }

    func startRun() {
        reset()
        mode = .flying
        report()
    }

    private func reset() {
        entities.forEach { $0.node.removeFromParent() }
        entities = []
        chunks.values.forEach { $0.removeFromParent() }
        chunks = [:]
        world.children.filter { $0 !== aircraft }.forEach { $0.removeFromParent() }
        removeAllActions()   // a crash still waiting to be announced
        root.removeAllActions()
        root.position = .zero
        terrain = Terrain()
        distance = 0
        stars = 0
        reported = (-1, -1)
        nextSpawn = 700
        fingers = 0
        armed = false
        runClock = 0
        state = FlightState()
        if let spec { flight = (FlightModels.all[spec.type] ?? FlightModels.all["plane"]!)(stats) }
        aircraft.isHidden = false
        aircraft.zRotation = 0
    }

    // MARK: Touches

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        fingers += touches.count
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        fingers = max(0, fingers - touches.count)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        fingers = 0
    }

    // MARK: Every frame

    override func update(_ currentTime: TimeInterval) {
        let dt = lastTime == 0 ? 0 : CGFloat(min(max(currentTime - lastTime, 0), 1.0 / 30))
        lastTime = currentTime
        clock += dt

        switch mode {
        case .idle:
            let pace = CGFloat(stats.speed) * 0.55
            distance += pace * dt
            let target = terrain.height(at: distance + 90) + 135 + 18 * sin(clock * 1.3)
            let newY = state.y + (target - state.y) * min(1, 2.5 * dt)
            if dt > 0 { state.pitch = atan2(newY - state.y, pace * dt) * 0.8 }
            state.y = newY
        case .flying:
            runClock += dt
            if fingers > 0 || runClock > 1.5 { armed = true }
            if armed { flight.step(&state, holding: fingers > 0, dt: dt) }
            let top = Terrain.ceiling - hitbox.height / 2
            if state.y > top {
                state.y = top
                state.verticalSpeed = min(state.verticalSpeed, 0)
            }
            // the further you get, the faster it goes
            distance += CGFloat(stats.speed) * (1 + min(distance / 14000, 0.6)) * dt
            spawn()
            updateEntities(dt)
            leaveTrail(dt)
            if touchesGround() { crash() }
            report()
        case .crashed:
            break
        }

        aircraft.position = CGPoint(x: distance, y: state.y)
        aircraft.zRotation = spec?.level == true ? 0 : state.pitch
        world.position.x = aircraftX - distance
        farHills.position.x = -(distance * 0.22).truncatingRemainder(dividingBy: Self.hillsPeriod)
        for cloud in clouds {
            let wrap = viewWidth + 400
            let x = (cloud.x - distance * cloud.depth).truncatingRemainder(dividingBy: wrap)
            cloud.node.position.x = (x < 0 ? x + wrap : x) - 200
        }
        updateGround()
    }

    private func report() {
        let now = (Int(distance / 10), stars)
        if now != reported {
            reported = now
            onProgress?(now.0, now.1)
        }
    }

    // MARK: Ground

    private func updateGround() {
        let left = distance - aircraftX - 40
        let first = Int(floor(left / Self.chunkWidth))
        let last = Int(floor((left + viewWidth + 80) / Self.chunkWidth))
        for index in first...last where chunks[index] == nil {
            let chunk = groundChunk(index)
            chunks[index] = chunk
            world.addChild(chunk)
        }
        for index in chunks.keys where index < first || index > last {
            chunks.removeValue(forKey: index)?.removeFromParent()
        }
    }

    private func groundChunk(_ index: Int) -> SKNode {
        let start = CGFloat(index) * Self.chunkWidth
        let surface = stride(from: CGFloat(0), through: Self.chunkWidth, by: 10).map { CGPoint(x: start + $0, y: terrain.height(at: start + $0)) }
        let body = CGMutablePath()
        body.move(to: CGPoint(x: start, y: -20))
        surface.forEach { body.addLine(to: $0) }
        body.addLine(to: CGPoint(x: start + Self.chunkWidth, y: -20))
        body.closeSubpath()
        let ground = SKShapeNode(path: body)
        ground.fillColor = UIColor(red: 0.30, green: 0.62, blue: 0.33, alpha: 1)
        ground.strokeColor = ground.fillColor
        ground.lineWidth = 1

        let top = CGMutablePath()
        top.addLines(between: surface)
        let grass = SKShapeNode(path: top)
        grass.strokeColor = UIColor(red: 0.55, green: 0.82, blue: 0.38, alpha: 1)
        grass.lineWidth = 6
        grass.lineCap = .round
        grass.fillColor = .clear
        ground.addChild(grass)
        ground.zPosition = 5
        return ground
    }

    private func touchesGround() -> Bool {
        let bottom = state.y - hitbox.height / 2
        let offsets: [CGFloat] = [-0.5, 0, 0.5]
        return offsets.contains { bottom < terrain.height(at: distance + hitbox.width * $0) }
    }

    // MARK: Things in the sky

    private final class Entity {
        enum Kind { case star, balloon, storm }
        let kind: Kind
        let node: SKNode
        var x: CGFloat
        var y: CGFloat
        let baseY: CGFloat
        let radius: CGFloat
        let phase = CGFloat.random(in: 0..<6.28)

        init(kind: Kind, node: SKNode, x: CGFloat, y: CGFloat, radius: CGFloat) {
            self.kind = kind
            self.node = node
            self.x = x
            self.y = y
            self.baseY = y
            self.radius = radius
        }
    }

    private func spawn() {
        let difficulty = min(distance / 25000, 1)
        while nextSpawn < distance + viewWidth {
            let x = nextSpawn
            nextSpawn += CGFloat.random(in: 260...420) * (1 - 0.35 * difficulty)
            let ground = terrain.height(at: x)
            let radius: CGFloat = 28
            let low = ground + 55 + radius, high = Terrain.ceiling - 8 - radius
            let room = Terrain.ceiling - ground - 2 * radius
            if CGFloat.random(in: 0..<1) < 0.4 + 0.3 * difficulty, high - low > 50, room > 120 {
                let y = CGFloat.random(in: low...high)
                if Bool.random() {
                    add(.balloon, Self.balloon(), x: x, y: y, radius: 21)
                } else {
                    add(.storm, Self.cloud(dark: true), x: x, y: y, radius: radius)
                }
                // a few stars in the open half, to show the way round
                if Bool.random() {
                    let above = y < (low + high) / 2
                    starRow(from: x - 34, count: 3, around: above ? min(y + 95, 372) : max(y - 95, ground + 45))
                }
            } else {
                starRow(from: x, count: 5, around: CGFloat.random(in: (ground + 60)...370))
            }
        }
    }

    private func starRow(from x: CGFloat, count: Int, around y: CGFloat) {
        let swing = CGFloat.random(in: -34...34)
        for index in 0..<count {
            let starX = x + CGFloat(index) * 34
            let starY = y + swing * sin(CGFloat(index) * 0.8)
            add(.star, Self.star(), x: starX, y: min(max(starY, terrain.height(at: starX) + 40), 376), radius: 12)
        }
    }

    private func add(_ kind: Entity.Kind, _ node: SKNode, x: CGFloat, y: CGFloat, radius: CGFloat) {
        node.position = CGPoint(x: x, y: y)
        node.zPosition = kind == .star ? 7 : 8
        world.addChild(node)
        entities.append(Entity(kind: kind, node: node, x: x, y: y, radius: radius))
    }

    /// Distance from a point to the nearest edge of the aircraft (0 inside it).
    private func gap(toX x: CGFloat, y: CGFloat) -> CGFloat {
        hypot(max(abs(x - distance) - hitbox.width / 2, 0), max(abs(y - state.y) - hitbox.height / 2, 0))
    }

    private func updateEntities(_ dt: CGFloat) {
        let reach = 26 + CGFloat(stats.magnet)
        var kept: [Entity] = []
        for entity in entities {
            if entity.x < distance - aircraftX - 80 {
                entity.node.removeFromParent()
                continue
            }
            switch entity.kind {
            case .star:
                let away = gap(toX: entity.x, y: entity.y)
                if away < 14 {
                    collect(entity)
                    continue
                }
                if away < reach {   // pulled in
                    let pull = min(1, 9 * dt)
                    entity.x += (distance - entity.x) * pull
                    entity.y += (state.y - entity.y) * pull
                }
            case .balloon:
                entity.y = entity.baseY + 14 * sin(clock * 1.5 + entity.phase)
            case .storm:
                break
            }
            entity.node.position = CGPoint(x: entity.x, y: entity.y)
            if entity.kind != .star, mode == .flying, gap(toX: entity.x, y: entity.y) < entity.radius * 0.82 {
                crash()
            }
            kept.append(entity)
        }
        entities = kept
    }

    private func collect(_ entity: Entity) {
        stars += 1
        entity.node.removeAllActions()
        entity.node.run(.sequence([.group([.scale(to: 2, duration: 0.18), .fadeOut(withDuration: 0.18)]), .removeFromParent()]))
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    // MARK: Effects

    private func puff(at point: CGPoint, color: UIColor, radius: CGFloat, grow: CGFloat, life: TimeInterval, drift: CGVector = .zero) {
        let dot = SKShapeNode(circleOfRadius: radius)
        dot.fillColor = color
        dot.strokeColor = .clear
        dot.position = point
        dot.zPosition = 9
        world.addChild(dot)
        dot.run(.sequence([.group([.scale(to: grow, duration: life), .fadeOut(withDuration: life), .move(by: drift, duration: life)]), .removeFromParent()]))
    }

    private func leaveTrail(_ dt: CGFloat) {
        trailTimer += dt
        guard trailTimer > 0.05, trailColor.cgColor.alpha > 0 else { return }
        trailTimer = 0
        let tail = CGPoint(x: distance - hitbox.width / 2 - 6, y: state.y - sin(state.pitch) * hitbox.width / 2)
        puff(at: tail, color: trailColor.withAlphaComponent(trailColor.cgColor.alpha * 0.6), radius: 3, grow: 2.6, life: 0.55)
    }

    private func crash() {
        guard mode == .flying else { return }
        mode = .crashed
        aircraft.isHidden = true
        let here = CGPoint(x: distance, y: state.y)
        let colors = [UIColor.orange, UIColor(red: 1, green: 0.85, blue: 0.3, alpha: 1), UIColor.darkGray, UIColor.white]
        for index in 0..<16 {
            let angle = CGFloat.random(in: 0..<(2 * .pi)), reach = CGFloat.random(in: 20...75)
            puff(at: here, color: colors[index % colors.count], radius: CGFloat.random(in: 6...12), grow: 2.4,
                 life: Double.random(in: 0.45...0.9), drift: CGVector(dx: cos(angle) * reach, dy: sin(angle) * reach))
        }
        let shake = (0..<6).map { _ in SKAction.moveBy(x: CGFloat.random(in: -7...7), y: CGFloat.random(in: -7...7), duration: 0.04) }
        root.run(.sequence(shake + [SKAction.move(to: .zero, duration: 0.05)]))
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        let metres = Int(distance / 10), collected = stars
        run(.sequence([.wait(forDuration: 0.8), .run { [weak self] in self?.onCrash?(metres, collected) }]))
    }

    // MARK: Drawings

    private static func skyImage() -> UIImage {
        let size = CGSize(width: 4, height: 256)
        return UIGraphicsImageRenderer(size: size).image { renderer in
            let colors = [UIColor(red: 0.27, green: 0.62, blue: 0.91, alpha: 1).cgColor, UIColor(red: 0.82, green: 0.93, blue: 0.99, alpha: 1).cgColor]
            guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1]) else { return }
            renderer.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
        }
    }

    private static func cloud(dark: Bool) -> SKNode {
        let cloud = SKNode()
        let color = dark ? UIColor(red: 0.29, green: 0.31, blue: 0.38, alpha: 1) : UIColor.white
        for (x, y, radius) in [(-20.0, -4.0, 15.0), (0.0, 5.0, 21.0), (21.0, -3.0, 16.0), (2.0, -9.0, 15.0)] {
            let blob = SKShapeNode(circleOfRadius: radius)
            blob.fillColor = color
            blob.strokeColor = .clear
            blob.position = CGPoint(x: x, y: y)
            cloud.addChild(blob)
        }
        if dark {
            let bolt = CGMutablePath()
            bolt.addLines(between: [CGPoint(x: 4, y: -14), CGPoint(x: -7, y: -32), CGPoint(x: 1, y: -31), CGPoint(x: -5, y: -48),
                                    CGPoint(x: 11, y: -26), CGPoint(x: 3, y: -27), CGPoint(x: 11, y: -14)])
            bolt.closeSubpath()
            let lightning = SKShapeNode(path: bolt)
            lightning.fillColor = UIColor(red: 1, green: 0.88, blue: 0.2, alpha: 1)
            lightning.strokeColor = .clear
            lightning.zPosition = -0.1
            lightning.run(.repeatForever(.sequence([.fadeAlpha(to: 0.15, duration: 0.12), .wait(forDuration: 0.5), .fadeAlpha(to: 1, duration: 0.05), .wait(forDuration: 0.25)])))
            cloud.addChild(lightning)
        }
        return cloud
    }

    private static func balloon() -> SKNode {
        let balloon = SKNode()
        let colors = [UIColor.systemPink, UIColor.systemPurple, UIColor.systemTeal, UIColor.systemOrange, UIColor.systemIndigo]
        let envelope = SKShapeNode(ellipseOf: CGSize(width: 40, height: 46))
        envelope.fillColor = colors.randomElement() ?? .systemPink
        envelope.strokeColor = UIColor.white.withAlphaComponent(0.8)
        envelope.lineWidth = 2
        let stripe = SKShapeNode(ellipseOf: CGSize(width: 16, height: 46))
        stripe.fillColor = UIColor.white.withAlphaComponent(0.35)
        stripe.strokeColor = .clear
        let ropes = CGMutablePath()
        ropes.move(to: CGPoint(x: -12, y: -19))
        ropes.addLine(to: CGPoint(x: -5, y: -32))
        ropes.move(to: CGPoint(x: 12, y: -19))
        ropes.addLine(to: CGPoint(x: 5, y: -32))
        let lines = SKShapeNode(path: ropes)
        lines.strokeColor = UIColor(red: 0.35, green: 0.27, blue: 0.2, alpha: 1)
        lines.lineWidth = 1.5
        let basket = SKShapeNode(rect: CGRect(x: -6, y: -40, width: 12, height: 9), cornerRadius: 2)
        basket.fillColor = UIColor(red: 0.55, green: 0.38, blue: 0.2, alpha: 1)
        basket.strokeColor = .clear
        [lines, basket, envelope, stripe].forEach { balloon.addChild($0) }
        return balloon
    }

    private static func star() -> SKNode {
        let path = CGMutablePath()
        for index in 0..<10 {
            let angle = CGFloat(index) * .pi / 5 + .pi / 2
            let radius: CGFloat = index % 2 == 0 ? 11 : 5
            let point = CGPoint(x: cos(angle) * radius, y: sin(angle) * radius)
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        let star = SKShapeNode(path: path)
        star.fillColor = UIColor(red: 1, green: 0.84, blue: 0.1, alpha: 1)
        star.strokeColor = UIColor(red: 0.95, green: 0.6, blue: 0.1, alpha: 1)
        star.lineWidth = 1.5
        star.lineJoin = .round
        star.run(.repeatForever(.sequence([.scale(to: 1.18, duration: 0.4), .scale(to: 1, duration: 0.4)])))
        return star
    }
}
