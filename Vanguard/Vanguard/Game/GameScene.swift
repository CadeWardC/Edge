import SpriteKit
import UIKit

/// Sprites for one entity.
private final class EntityNode {
    let root = SKNode()
    let body: SKSpriteNode
    var gun: SKSpriteNode?
    var shadow: SKSpriteNode?
    var scaffold: SKSpriteNode?
    var core: SKSpriteNode?
    var captureRing: SKSpriteNode?
    var extra: SKSpriteNode?        // radar dish, shield orb, tower lantern, HQ beacon light
    var dome: SKSpriteNode?
    var badge: SKSpriteNode?
    var lastSmoke = 0
    var frame = 0
    var type: EntityType = .worker
    var team: TeamColor = .blue
    let ring: SKSpriteNode
    let hpBack: SKSpriteNode
    let hpFront: SKSpriteNode
    var lastOwner: Int
    var wasComplete: Bool
    var barWidth: CGFloat

    init(body: SKSpriteNode, owner: Int, complete: Bool, radius: CGFloat) {
        self.body = body
        lastOwner = owner
        wasComplete = complete
        barWidth = max(18, radius * 1.8)
        ring = SKSpriteNode(texture: Art.ring())
        ring.size = CGSize(width: radius * 2 + 10, height: radius * 2 + 10)
        ring.zPosition = 20
        ring.isHidden = true
        hpBack = SKSpriteNode(texture: Art.bar())
        hpBack.color = .black
        hpBack.colorBlendFactor = 1
        hpBack.alpha = 0.7
        hpBack.size = CGSize(width: barWidth + 2, height: 4.5)
        hpBack.position = CGPoint(x: 0, y: radius + 9)
        hpBack.zPosition = 21
        hpFront = SKSpriteNode(texture: Art.bar())
        hpFront.colorBlendFactor = 1
        hpFront.anchorPoint = CGPoint(x: 0, y: 0.5)
        hpFront.size = CGSize(width: barWidth, height: 3)
        hpFront.position = CGPoint(x: -barWidth / 2, y: radius + 9)
        hpFront.zPosition = 22
        root.addChild(ring)
        root.addChild(hpBack)
        root.addChild(hpFront)
        root.addChild(body)
    }
}

final class GameScene: SKScene, UIGestureRecognizerDelegate {
    let controller: GameController
    private var world: World { controller.world }
    private let worldNode = SKNode()
    private let effects = SKNode()
    private let cam = SKCameraNode()
    private var nodes: [Int: EntityNode] = [:]
    private var fogNode = SKSpriteNode()
    private var fogVersion = -1
    private var lastTime: TimeInterval = 0
    private let ghost = SKSpriteNode()
    private let box = SKShapeNode()
    private var boxStart: Vec2?
    private var remembered = Set<Int>()
    private var pinchStart: CGFloat = 1
    private var ready = false
    private var spectator: Bool { controller.localTeam < 0 }

    init(controller: GameController) {
        self.controller = controller
        super.init(size: CGSize(width: 1000, height: 600))
        scaleMode = .resizeFill
        backgroundColor = UIColor(red: 0.05, green: 0.06, blue: 0.08, alpha: 1)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func didMove(to view: SKView) {
        view.ignoresSiblingOrder = true
        view.isMultipleTouchEnabled = true
        if !ready { build() }
        if !controller.isBackdrop { addGestures(view) }
    }

    private func build() {
        ready = true
        addChild(worldNode)
        camera = cam
        addChild(cam)
        let map = world.map
        // terrain in chunks
        let cn = Art.chunkTiles
        let chunkSize = CGFloat(cn) * CGFloat(Defs.tile)
        for cy in 0..<((map.height + cn - 1) / cn) {
            for cx in 0..<((map.width + cn - 1) / cn) {
                let s = SKSpriteNode(texture: Art.terrainChunk(map, cx: cx, cy: cy))
                s.size = CGSize(width: chunkSize, height: chunkSize)
                s.anchorPoint = .zero
                s.position = CGPoint(x: CGFloat(cx) * chunkSize, y: CGFloat(cy) * chunkSize)
                s.zPosition = -10
                worldNode.addChild(s)
            }
        }
        effects.zPosition = 0
        worldNode.addChild(effects)
        fogNode.size = CGSize(width: map.worldWidth, height: map.worldHeight)
        fogNode.position = CGPoint(x: map.worldWidth / 2, y: map.worldHeight / 2)
        fogNode.zPosition = 18
        fogNode.isHidden = spectator
        worldNode.addChild(fogNode)
        ghost.zPosition = 30
        ghost.alpha = 0.65
        ghost.colorBlendFactor = 0.45
        ghost.isHidden = true
        worldNode.addChild(ghost)
        box.strokeColor = UIColor(red: 0.4, green: 1, blue: 0.5, alpha: 0.95)
        box.fillColor = UIColor(red: 0.4, green: 1, blue: 0.5, alpha: 0.12)
        box.lineWidth = 2
        box.zPosition = 31
        box.isHidden = true
        worldNode.addChild(box)

        if controller.localPlayer >= 0 {
            let start = map.starts[controller.localPlayer % map.starts.count].center
            cam.position = CGPoint(x: start.x, y: start.y + 60)
            cam.setScale(0.9)
        } else {
            cam.position = CGPoint(x: map.worldWidth / 2, y: map.worldHeight / 2)
            cam.setScale(1.8)
        }
        controller.scene = self
        updateFog()
        sync()
    }

    // MARK: gestures

    private func addGestures(_ view: SKView) {
        view.gestureRecognizers?.forEach { view.removeGestureRecognizer($0) }
        let tap = UITapGestureRecognizer(target: self, action: #selector(onTap(_:)))
        let pan = UIPanGestureRecognizer(target: self, action: #selector(onPan(_:)))
        pan.maximumNumberOfTouches = 2
        pan.delegate = self
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(onPinch(_:)))
        pinch.delegate = self
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(onHold(_:)))
        hold.minimumPressDuration = 0.28
        hold.allowableMovement = 12
        for g in [tap, pan, pinch, hold] as [UIGestureRecognizer] { view.addGestureRecognizer(g) }
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        (g is UIPinchGestureRecognizer && other is UIPanGestureRecognizer) || (g is UIPanGestureRecognizer && other is UIPinchGestureRecognizer)
    }

    private func worldPoint(_ p: CGPoint) -> Vec2 {
        guard let v = view else { return .zero }
        let s = cam.xScale
        return Vec2(Double(cam.position.x + (p.x - v.bounds.midX) * s), Double(cam.position.y - (p.y - v.bounds.midY) * s))
    }

    @objc private func onTap(_ g: UITapGestureRecognizer) {
        guard let v = view else { return }
        controller.tap(worldPoint(g.location(in: v)))
    }

    private var camVel = CGVector.zero
    private var backdropTime: Double = 0
    private let alwaysHP = UserDefaults.standard.bool(forKey: "alwaysHP")

    @objc private func onPan(_ g: UIPanGestureRecognizer) {
        guard let v = view else { return }
        if g.state == .began { camVel = .zero }
        if g.state == .ended {
            let vel = g.velocity(in: v)
            camVel = CGVector(dx: -vel.x * cam.xScale, dy: vel.y * cam.xScale)
        }
        let t = g.translation(in: v)
        g.setTranslation(.zero, in: v)
        cam.position = CGPoint(x: cam.position.x - t.x * cam.xScale, y: cam.position.y + t.y * cam.xScale)
        clampCamera()
    }

    @objc private func onPinch(_ g: UIPinchGestureRecognizer) {
        if g.state == .began { pinchStart = cam.xScale }
        let s = min(2.4, max(0.45, pinchStart / max(0.1, g.scale)))
        cam.setScale(s)
        clampCamera()
    }

    @objc private func onHold(_ g: UILongPressGestureRecognizer) {
        guard let v = view else { return }
        let p = worldPoint(g.location(in: v))
        switch g.state {
        case .began:
            boxStart = p
            UISelectionFeedbackGenerator().selectionChanged()
            box.isHidden = false
            updateBox(p)
        case .changed:
            updateBox(p)
        case .ended:
            if let a = boxStart {
                if a.dist(p) < 14 {
                    // a long press on one unit selects it alone
                    if let e = controller.entityAt(p), e.owner == controller.localPlayer { controller.select([e.id]) }
                } else {
                    controller.boxSelect(a, p)
                }
            }
            fallthrough
        default:
            boxStart = nil
            box.isHidden = true
        }
    }

    private func updateBox(_ p: Vec2) {
        guard let a = boxStart else { return }
        let r = CGRect(x: min(a.x, p.x), y: min(a.y, p.y), width: abs(p.x - a.x), height: abs(p.y - a.y))
        box.path = CGPath(rect: r, transform: nil)
    }

    private func clampCamera() {
        guard let v = view else { return }
        let hw = v.bounds.width * cam.xScale / 2, hh = v.bounds.height * cam.xScale / 2
        let W = CGFloat(world.map.worldWidth), H = CGFloat(world.map.worldHeight)
        let x = hw * 2 > W ? W / 2 : min(max(cam.position.x, hw - 40), W - hw + 40)
        let y = hh * 2 > H ? H / 2 : min(max(cam.position.y, hh - 120), H - hh + 40)
        cam.position = CGPoint(x: x, y: y)
    }

    // MARK: camera helpers for the controller

    var cameraCenter: Vec2 { Vec2(Double(cam.position.x), Double(cam.position.y)) }

    var visibleWorldRect: CGRect? {
        guard let v = view else { return nil }
        let w = v.bounds.width * cam.xScale, h = v.bounds.height * cam.xScale
        return CGRect(x: cam.position.x - w / 2, y: cam.position.y - h / 2, width: w, height: h)
    }

    func onScreen(_ p: Vec2) -> Bool { visibleWorldRect?.contains(CGPoint(x: p.x, y: p.y)) ?? false }

    func focus(_ p: Vec2) {
        camVel = .zero
        cam.removeAllActions()
        cam.run(SKAction.move(to: CGPoint(x: p.x, y: p.y), duration: 0.25)) { [weak self] in self?.clampCamera() }
    }

    func jump(toFraction fx: Double, _ fy: Double) {
        camVel = .zero
        cam.position = CGPoint(x: fx * world.map.worldWidth, y: (1 - fy) * world.map.worldHeight)
        clampCamera()
    }

    // MARK: frame

    override func update(_ currentTime: TimeInterval) {
        let dt = lastTime == 0 ? 1.0 / 60 : min(0.1, currentTime - lastTime)
        lastTime = currentTime
        controller.frame(dt)
        ambient(dt)
        if controller.isBackdrop {
            // drift slowly over the battle
            backdropTime += dt
            let W = CGFloat(world.map.worldWidth), H = CGFloat(world.map.worldHeight)
            cam.setScale(1.15)
            cam.position = CGPoint(x: W / 2 + CGFloat(cos(backdropTime * 0.045)) * W * 0.28, y: H / 2 + CGFloat(sin(backdropTime * 0.06)) * H * 0.28)
        } else if abs(camVel.dx) + abs(camVel.dy) > 5 {
            cam.position = CGPoint(x: cam.position.x + camVel.dx * CGFloat(dt), y: cam.position.y + camVel.dy * CGFloat(dt))
            let k = CGFloat(pow(0.04, dt))
            camVel = CGVector(dx: camVel.dx * k, dy: camVel.dy * k)
            clampCamera()
        }
        if world.fog.version != fogVersion { updateFog() }
        sync()
    }

    private func visibleToMe(_ p: Vec2) -> Bool { spectator || world.fog.visible(team: controller.localTeam, p) }

    private func makeNode(_ e: Entity) -> EntityNode {
        let r = CGFloat(e.st.radius)
        let colorOf: TeamColor = e.owner >= 0 ? world.players[e.owner].color : .blue
        let body: SKSpriteNode
        var n: EntityNode
        switch e.type {
        case .crystal:
            body = SKSpriteNode(texture: Art.crystal(e.id, rich: e.rich))
            body.size = CGSize(width: 40, height: 40)
            n = EntityNode(body: body, owner: -1, complete: true, radius: r)
            n.root.zPosition = 3
        case .beacon:
            body = SKSpriteNode(texture: Art.beaconPad())
            body.size = CGSize(width: 76, height: 76)
            n = EntityNode(body: body, owner: -2, complete: true, radius: r)
            let core = SKSpriteNode(texture: Art.beaconCore())
            core.size = CGSize(width: 40, height: 40)
            core.colorBlendFactor = 1
            core.color = .lightGray
            core.zPosition = 0.5
            core.run(.repeatForever(.sequence([.scale(to: 1.15, duration: 0.8), .scale(to: 0.9, duration: 0.8)])))
            body.addChild(core)
            n.core = core
            let ring = SKSpriteNode(texture: Art.beaconRing())
            let d = CGFloat(Defs.beaconRadius) * 2 + 8
            ring.size = CGSize(width: d, height: d)
            ring.zPosition = -0.5
            ring.alpha = 0.6
            ring.run(.repeatForever(.rotate(byAngle: .pi, duration: 12)))
            body.addChild(ring)
            n.captureRing = ring
            n.root.zPosition = 1
        case .tower:
            body = SKSpriteNode(texture: Art.watchTower())
            body.size = CGSize(width: 64, height: 64)
            n = EntityNode(body: body, owner: -2, complete: true, radius: r)
            let lamp = SKSpriteNode(texture: Art.glow())
            lamp.size = CGSize(width: 22, height: 22)
            lamp.position = CGPoint(x: 0, y: 14)
            lamp.colorBlendFactor = 1
            lamp.color = .lightGray
            lamp.blendMode = .add
            lamp.zPosition = 0.5
            lamp.run(.repeatForever(.sequence([.fadeAlpha(to: 0.5, duration: 0.7), .fadeAlpha(to: 1, duration: 0.7)])))
            body.addChild(lamp)
            n.extra = lamp
            n.root.zPosition = 3
        default:
            if e.isBuilding {
                body = SKSpriteNode(texture: Art.building(e.type, colorOf))
                let s = Art.buildingSize(e.type)
                body.size = CGSize(width: s, height: s)
                n = EntityNode(body: body, owner: e.owner, complete: e.isComplete, radius: r)
                n.root.zPosition = 2
                if e.type == .turret {
                    let g = SKSpriteNode(texture: Art.turretGun(colorOf))
                    g.size = CGSize(width: 64, height: 64)
                    g.position = CGPoint(x: 0, y: 2)
                    g.zPosition = 0.5
                    body.addChild(g)
                    n.gun = g
                }
                if e.type == .radar {
                    let d = SKSpriteNode(texture: Art.radarDish())
                    d.size = CGSize(width: 40, height: 40)
                    d.position = CGPoint(x: 0, y: 20)
                    d.zPosition = 0.6
                    d.run(.repeatForever(.rotate(byAngle: -.pi * 2, duration: 4)))
                    body.addChild(d)
                    n.extra = d
                }
                if e.type == .shield {
                    let o = SKSpriteNode(texture: Art.shieldOrb())
                    o.size = CGSize(width: 30, height: 30)
                    o.position = CGPoint(x: 0, y: 6)
                    o.color = Art.color(colorOf)
                    o.colorBlendFactor = 0.5
                    o.blendMode = .add
                    o.zPosition = 0.6
                    o.run(.repeatForever(.sequence([.scale(to: 1.25, duration: 0.6), .scale(to: 0.9, duration: 0.6)])))
                    body.addChild(o)
                    n.extra = o
                    let dome = SKSpriteNode(texture: Art.shieldDome())
                    let dd = CGFloat(Defs.shieldRadius) * 2
                    dome.size = CGSize(width: dd, height: dd)
                    dome.color = Art.color(colorOf)
                    dome.colorBlendFactor = 1
                    dome.alpha = 0.35
                    dome.zPosition = 9
                    dome.isHidden = !e.isComplete
                    dome.run(.repeatForever(.sequence([.fadeAlpha(to: 0.22, duration: 1.4), .fadeAlpha(to: 0.4, duration: 1.4)])))
                    n.root.addChild(dome)
                    n.dome = dome
                }
                if e.type == .hq {
                    let l = SKSpriteNode(texture: Art.glow())
                    l.size = CGSize(width: 10, height: 10)
                    l.position = CGPoint(x: 20, y: 44)
                    l.color = .red
                    l.colorBlendFactor = 1
                    l.blendMode = .add
                    l.zPosition = 0.7
                    l.run(.repeatForever(.sequence([.fadeAlpha(to: 1, duration: 0.1), .wait(forDuration: 0.3),
                                                    .fadeAlpha(to: 0.1, duration: 0.3), .wait(forDuration: 0.9)])))
                    body.addChild(l)
                    n.extra = l
                }
                let sc = SKSpriteNode(texture: Art.scaffold(e.st.footprint))
                sc.size = body.size
                sc.zPosition = 1
                sc.isHidden = e.isComplete
                body.addChild(sc)
                n.scaffold = sc
                n.barWidth = r * 1.6
            } else {
                body = SKSpriteNode(texture: Art.unit(e.type, colorOf))
                let s = Art.unitSize(e.type)
                body.size = CGSize(width: s, height: s)
                n = EntityNode(body: body, owner: e.owner, complete: true, radius: r)
                n.root.zPosition = e.isAir ? 12 : 5
                let sh = SKSpriteNode(texture: Art.shadow())
                sh.size = CGSize(width: r * 2.6, height: r * 2.2)
                sh.position = e.isAir ? CGPoint(x: 14, y: -26) : CGPoint(x: 2.5, y: -3.5)
                sh.zPosition = e.isAir ? -9 : -2
                sh.alpha = e.isAir ? 0.6 : 0.8
                n.root.addChild(sh)
                n.shadow = sh
                if e.type == .tank {
                    let g = SKSpriteNode(texture: Art.tankTurret(colorOf))
                    g.size = CGSize(width: 60, height: 60)
                    g.zPosition = 0.5
                    body.addChild(g)
                    n.gun = g
                }
                if e.isAir {
                    body.run(.repeatForever(.sequence([.moveBy(x: 0, y: 3, duration: 0.9), .moveBy(x: 0, y: -3, duration: 0.9)])))
                }
            }
        }
        n.type = e.type
        n.team = colorOf
        // re-layout bars now that the width is known
        n.hpBack.size = CGSize(width: n.barWidth + 2, height: 4.5)
        n.hpFront.size = CGSize(width: n.barWidth, height: 3)
        n.hpFront.position = CGPoint(x: -n.barWidth / 2, y: n.hpFront.position.y)
        worldNode.addChild(n.root)
        return n
    }

    private func sync() {
        let alpha = controller.session.alpha
        let selected = Set(controller.selection)
        var alive = Set<Int>()
        let rect = (visibleWorldRect ?? .zero).insetBy(dx: -120, dy: -120)
        for e in world.entities where e.alive {
            alive.insert(e.id)
            let p = e.prevPos + (e.pos - e.prevPos) * alpha
            let cp = CGPoint(x: p.x, y: p.y)
            var show: Bool
            if e.type.isNeutral || spectator || e.team == controller.localTeam {
                show = true
            } else if e.isBuilding {
                if world.fog.visible(team: controller.localTeam, e.pos) { remembered.insert(e.id) }
                show = remembered.contains(e.id)
            } else {
                show = world.fog.visible(team: controller.localTeam, e.pos)
            }
            if !rect.contains(cp) && !selected.contains(e.id) {
                if let n = nodes[e.id] { n.root.isHidden = true }
                continue
            }
            let n = nodes[e.id] ?? makeNode(e)
            nodes[e.id] = n
            n.root.isHidden = !show
            if !show { continue }
            n.root.position = cp
            if e.isUnit {
                n.body.zRotation = CGFloat(atan2(e.dir.y, e.dir.x))
                // animation frames: walk / roll / flicker while moving, idle engines flicker slowly
                let frames = Art.unitFrames(e.type)
                if frames > 1 {
                    let moving = e.pos.distSq(e.prevPos) > 0.01
                    let rate = e.type == .tank ? 2 : (e.isAir || e.type == .skimmer || e.isWorker ? 3 : 4)
                    let f = moving || e.isAir || e.isWorker ? (world.tick / rate) % frames : 0
                    if f != n.frame {
                        n.frame = f
                        n.body.texture = Art.unit(e.type, n.team, frame: f)
                    }
                }
                // sparks while mining or building
                if e.isWorker && world.tick - e.lastShotTick < 2 && Int.random(in: 0..<10) == 0 && rect.contains(cp) {
                    let tip = CGPoint(x: cp.x + CGFloat(e.dir.x) * 14, y: cp.y + CGFloat(e.dir.y) * 14)
                    var building = false
                    if case .construct = e.order { building = true }
                    if case .repair = e.order { building = true }
                    spark(tip, building ? UIColor(red: 1, green: 0.85, blue: 0.4, alpha: 1) : UIColor(red: 0.5, green: 1, blue: 1, alpha: 1), building ? 7 : 6)
                }
                if let g = n.gun { g.zRotation = CGFloat(atan2(e.aimDir.y, e.aimDir.x) - atan2(e.dir.y, e.dir.x)) }
                // worker at work: a little bob
                if e.isWorker && world.tick - e.lastShotTick < 2 {
                    n.body.position = CGPoint(x: 0, y: CGFloat(sin(Double(world.tick) * 0.9)) * 1.2)
                } else {
                    n.body.position = .zero
                }
                if e.type == .tank {
                    n.body.setScale(e.sieged ? 1.08 : 1)
                }
                n.body.colorBlendFactor = world.tick - e.lastHitTick < 2 ? 0.5 : 0
                n.body.color = .white
            } else if e.isBuilding {
                if let sp = e.spec, n.badge == nil {
                    let b = SKSpriteNode(texture: Art.specBadge(sp))
                    let h = CGFloat(e.st.footprint) * CGFloat(Defs.tile) / 2
                    b.size = CGSize(width: 18, height: 18)
                    b.position = CGPoint(x: h - 8, y: -h + 8)
                    b.zPosition = 1.5
                    n.body.addChild(b)
                    n.badge = b
                    if sp == .fortress {
                        let g = SKSpriteNode(texture: Art.fortressGun(world.players[max(0, e.owner)].color))
                        g.size = CGSize(width: 70, height: 70)
                        g.position = CGPoint(x: 0, y: 11)
                        g.zPosition = 0.8
                        n.body.addChild(g)
                        n.gun = g
                    }
                }
                if let g = n.gun { g.zRotation = CGFloat(atan2(e.aimDir.y, e.aimDir.x)) }
                n.dome?.isHidden = !e.isComplete
                // smoke from busy factories, a glow over busy buildings
                if e.isComplete && !e.queue.isEmpty && world.tick - n.lastSmoke > 16 {
                    n.lastSmoke = world.tick
                    if e.type == .factory {
                        for sp in Art.factoryStacks {
                            puff(CGPoint(x: cp.x + sp.x, y: cp.y + sp.y), 7, 1.2, dark: true)
                        }
                    } else if world.tick % 24 < 6 {
                        spark(CGPoint(x: cp.x + CGFloat.random(in: -10...10), y: cp.y - CGFloat(e.st.footprint) * 14), UIColor(red: 0.6, green: 1, blue: 1, alpha: 1), 8)
                    }
                }
                if n.wasComplete != e.isComplete || n.scaffold?.isHidden == e.isComplete {
                    n.wasComplete = e.isComplete
                    n.scaffold?.isHidden = e.isComplete
                }
                n.body.alpha = e.isComplete ? 1 : CGFloat(0.35 + 0.65 * e.progress)
                if e.team != controller.localTeam && !spectator && !world.fog.visible(team: controller.localTeam, e.pos) {
                    n.body.alpha = 0.55
                }
            } else if e.type == .tower {
                if n.lastOwner != e.owner {
                    n.lastOwner = e.owner
                    n.extra?.color = e.owner >= 0 ? Art.color(world.players[e.owner].color) : .lightGray
                }
            } else if e.type == .crystal {
                let f = CGFloat(Double(e.amount) / Double(e.rich ? Defs.richAmount : Defs.crystalAmount))
                n.body.setScale(0.65 + 0.35 * f)
            } else if e.type == .beacon {
                if n.lastOwner != e.owner {
                    n.lastOwner = e.owner
                    n.core?.color = e.owner >= 0 ? Art.color(world.players[e.owner].color) : .lightGray
                }
                n.captureRing?.alpha = e.captureProgress > 0 && e.captureProgress < 1 ? 1 : 0.45
                if e.owner < 0, e.captureTeam >= 0, let p = world.players.first(where: { $0.team == e.captureTeam }) {
                    n.captureRing?.color = Art.color(p.color)
                    n.captureRing?.colorBlendFactor = CGFloat(e.captureProgress)
                } else {
                    n.captureRing?.colorBlendFactor = 0
                }
            }
            // selection ring and health bar
            let isSel = selected.contains(e.id)
            n.ring.isHidden = !isSel
            if isSel {
                n.ring.color = e.owner == controller.localPlayer ? .green : (e.type.isNeutral ? .yellow : .red)
                n.ring.colorBlendFactor = 1
            }
            let damaged = e.hp < e.maxHp - 0.5
            let showBar = !e.type.isNeutral && !controller.isBackdrop && ((isSel && selected.count <= 12) || damaged || alwaysHP || (e.isBuilding && !e.isComplete))
            n.hpBack.isHidden = !showBar
            n.hpFront.isHidden = !showBar
            if showBar {
                let f = CGFloat(max(0, min(1, e.isBuilding && !e.isComplete ? e.progress : e.hp / e.maxHp)))
                n.hpFront.size = CGSize(width: max(1, n.barWidth * f), height: 3)
                n.hpFront.color = e.isBuilding && !e.isComplete ? UIColor(red: 1, green: 0.8, blue: 0.2, alpha: 1)
                    : (f > 0.6 ? UIColor(red: 0.3, green: 0.95, blue: 0.35, alpha: 1) : (f > 0.3 ? .yellow : .red))
            }
        }
        for (id, n) in nodes where !alive.contains(id) {
            n.root.removeFromParent()
            nodes[id] = nil
            remembered.remove(id)
        }
        // building placement ghost
        if let t = controller.placing, let o = controller.placeOrigin {
            let colorOf: TeamColor = controller.me?.color ?? .blue
            ghost.texture = Art.building(t, colorOf)
            let s = Art.buildingSize(t)
            ghost.size = CGSize(width: s, height: s)
            let half = Double(t.stats.footprint) * Defs.tile / 2
            ghost.position = CGPoint(x: Double(o.x) * Defs.tile + half, y: Double(o.y) * Defs.tile + half)
            ghost.color = controller.placementValid ? .green : .red
            ghost.isHidden = false
        } else {
            ghost.isHidden = true
        }
    }

    private func updateFog() {
        fogVersion = world.fog.version
        guard !spectator else { return }
        let w = world.map.width, h = world.map.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { return }
        let px = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        let team = controller.localTeam
        for y in 0..<h {
            let row = (h - 1 - y) * w
            for x in 0..<w {
                let a: UInt8
                switch world.fog.state(team: team, x: x, y: y) {
                case 2: a = 0
                case 1: a = 135
                default: a = 238
                }
                let i = (row + x) * 4
                px[i] = UInt8(Int(a) * 8 / 255)
                px[i + 1] = UInt8(Int(a) * 10 / 255)
                px[i + 2] = UInt8(Int(a) * 16 / 255)
                px[i + 3] = a
            }
        }
        guard let img = ctx.makeImage() else { return }
        let t = SKTexture(cgImage: img)
        t.filteringMode = .linear
        fogNode.texture = t
    }

    // MARK: effects

    func marker(at p: Vec2, attack: Bool) {
        let m = SKSpriteNode(texture: Art.moveMarker())
        m.size = CGSize(width: 34, height: 34)
        m.position = CGPoint(x: p.x, y: p.y)
        m.color = attack ? .red : .green
        m.colorBlendFactor = 1
        m.zPosition = 32
        m.setScale(1.4)
        effects.addChild(m)
        m.run(.sequence([.group([.scale(to: 0.6, duration: 0.35), .fadeOut(withDuration: 0.45)]), .removeFromParent()]))
    }

    func ping(_ p: Vec2) {
        let r = SKSpriteNode(texture: Art.ring())
        r.size = CGSize(width: 60, height: 60)
        r.position = CGPoint(x: p.x, y: p.y)
        r.color = .red
        r.colorBlendFactor = 1
        r.zPosition = 32
        effects.addChild(r)
        r.run(.sequence([.group([.scale(to: 4, duration: 0.9), .fadeOut(withDuration: 0.9)]), .removeFromParent()]))
    }

    /// Louder near the middle of the screen, quieter toward the edges and when zoomed out.
    private func soundGain(_ p: Vec2) -> Float {
        guard !controller.isBackdrop, let r = visibleWorldRect else { return 0 }
        let d = Vec2(Double(r.midX), Double(r.midY)).dist(p)
        let reach = Double(max(r.width, r.height)) * 0.75
        return Float(max(0.15, 1 - d / reach)) * Float(min(1, 1.3 / max(0.6, Double(cam.xScale))))
    }

    private func near(_ p: Vec2) -> Bool {
        guard let r = visibleWorldRect else { return false }
        return r.insetBy(dx: -80, dy: -80).contains(CGPoint(x: p.x, y: p.y))
    }

    func play(_ events: [GameEvent]) {
        var budget = 60
        for ev in events {
            switch ev {
            case let .shot(from, to, style, fromPos):
                guard budget > 0, near(fromPos) || near(to), visibleToMe(fromPos) || visibleToMe(to) else { continue }
                budget -= 1
                shot(from: from, fromPos: fromPos, to: to, style: style)
                let gain = soundGain(fromPos)
                switch style {
                case .rifle: Sound.shared.play(.rifle, gain: gain * 0.6)
                case .laser: Sound.shared.play(.laser, gain: gain * 0.6)
                case .rocket: Sound.shared.play(.rocket, gain: gain)
                case .cannon: Sound.shared.play(.cannon, gain: gain)
                case .heal: Sound.shared.play(.heal, gain: gain * 0.5)
                case .claw: Sound.shared.play(.claw, gain: gain * 0.5)
                case .none: break
                }
            case let .died(e):
                guard near(e.pos), visibleToMe(e.pos) || e.team == controller.localTeam else { continue }
                if e.type == .crystal { continue }
                Sound.shared.play(e.isBuilding || e.type == .tank || e.type == .gunship ? .boomBig : .boomSmall, gain: soundGain(e.pos))
                if e.st.isBio {
                    collapse(e)
                } else if e.isBuilding {
                    for k in 0..<4 {
                        let off = Vec2(Double.random(in: -1...1), Double.random(in: -1...1)) * (e.st.radius * 0.6)
                        run(.wait(forDuration: Double(k) * 0.14)) { [weak self] in
                            self?.explode(e.pos + off, size: CGFloat(e.st.radius) * (k == 3 ? 1.5 : 0.8), big: k == 3)
                        }
                    }
                } else {
                    explode(e.pos, size: CGFloat(e.st.radius) * 1.6, big: e.type == .tank || e.type == .gunship || e.type == .skimmer)
                }
                scorch(e.pos, size: e.isBuilding ? 110 : CGFloat(e.st.radius) * 3)
                wreck(e)
                if e.isBuilding || e.type == .tank || e.type == .gunship { shake(e.isBuilding ? 7 : 4) }
            case let .trained(u):
                guard near(u.pos), u.team == controller.localTeam || spectator else { continue }
                flash(CGPoint(x: u.pos.x, y: u.pos.y), 30, UIColor(red: 0.6, green: 0.9, blue: 1, alpha: 1))
            case let .captured(bid, _):
                if let b = world.entity(bid), near(b.pos) {
                    let r = SKSpriteNode(texture: Art.ring())
                    r.size = CGSize(width: 60, height: 60)
                    r.position = CGPoint(x: b.pos.x, y: b.pos.y)
                    r.color = b.owner >= 0 ? Art.color(world.players[b.owner].color) : .white
                    r.colorBlendFactor = 1
                    r.zPosition = 12
                    effects.addChild(r)
                    r.run(.sequence([.group([.scale(to: 4, duration: 0.7), .fadeOut(withDuration: 0.7)]), .removeFromParent()]))
                }
            case let .completed(b):
                guard near(b.pos), b.team == controller.localTeam || spectator else { continue }
                sparkle(b.pos, CGFloat(b.st.radius))
            default:
                break
            }
        }
    }

    private func shot(from id: Int, fromPos: Vec2, to: Vec2, style: WeaponStyle) {
        let shooter = world.entity(id)
        let dir = (to - fromPos).normalized()
        let reach = (shooter?.st.radius ?? 8) + (shooter?.type == .tank || shooter?.type == .turret ? 14 : 4)
        let a = fromPos + dir * reach
        let start = CGPoint(x: a.x, y: a.y), end = CGPoint(x: to.x, y: to.y)
        let len = CGFloat(a.dist(to))
        let angle = CGFloat(atan2(dir.y, dir.x))
        switch style {
        case .rifle, .laser:
            let tr = SKSpriteNode(texture: Art.tracer())
            tr.size = CGSize(width: max(8, len), height: style == .laser ? 4 : 2.2)
            tr.position = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
            tr.zRotation = angle
            tr.zPosition = 9
            tr.colorBlendFactor = 1
            tr.color = style == .laser ? UIColor(red: 0.4, green: 0.9, blue: 1, alpha: 1) : UIColor(red: 1, green: 0.9, blue: 0.5, alpha: 1)
            tr.blendMode = .add
            effects.addChild(tr)
            tr.run(.sequence([.fadeOut(withDuration: style == .laser ? 0.14 : 0.07), .removeFromParent()]))
            flash(start, 7, UIColor(red: 1, green: 0.85, blue: 0.4, alpha: 1))
            spark(end, style == .laser ? UIColor(red: 0.5, green: 0.9, blue: 1, alpha: 1) : .yellow, 5)
        case .rocket:
            let r = SKSpriteNode(texture: Art.rocket())
            r.size = CGSize(width: 14, height: 7)
            r.position = start
            r.zRotation = angle
            r.zPosition = 9
            effects.addChild(r)
            let t = TimeInterval(len / 520)
            let trail = SKAction.repeat(.sequence([.run { [weak self, weak r] in
                guard let self, let r else { return }
                self.puff(r.position, 6, 0.35)
            }, .wait(forDuration: 0.04)]), count: max(1, Int(t / 0.04)))
            r.run(.group([trail, .move(to: end, duration: t)])) { [weak self, weak r] in
                r?.removeFromParent()
                self?.explode(Vec2(Double(end.x), Double(end.y)), size: 10, big: false)
            }
        case .cannon:
            flash(start, 14, UIColor(red: 1, green: 0.8, blue: 0.4, alpha: 1))
            let sh = SKSpriteNode(texture: Art.glow())
            sh.size = CGSize(width: 9, height: 9)
            sh.color = UIColor(red: 1, green: 0.8, blue: 0.4, alpha: 1)
            sh.colorBlendFactor = 1
            sh.blendMode = .add
            sh.position = start
            sh.zPosition = 9
            effects.addChild(sh)
            sh.run(.sequence([.move(to: end, duration: TimeInterval(len / 900)), .removeFromParent()])) { [weak self] in
                self?.explode(Vec2(Double(end.x), Double(end.y)), size: shooter?.sieged == true ? 22 : 14, big: false)
            }
        case .heal:
            let g = SKSpriteNode(texture: Art.glow())
            g.size = CGSize(width: 26, height: 26)
            g.color = UIColor(red: 0.4, green: 1, blue: 0.5, alpha: 1)
            g.colorBlendFactor = 1
            g.blendMode = .add
            g.position = end
            g.zPosition = 9
            effects.addChild(g)
            g.run(.sequence([.group([.scale(to: 1.6, duration: 0.3), .fadeOut(withDuration: 0.3)]), .removeFromParent()]))
            let tr = SKSpriteNode(texture: Art.tracer())
            tr.size = CGSize(width: max(8, len), height: 3)
            tr.position = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
            tr.zRotation = angle
            tr.zPosition = 9
            tr.color = UIColor(red: 0.4, green: 1, blue: 0.5, alpha: 1)
            tr.colorBlendFactor = 1
            tr.blendMode = .add
            tr.alpha = 0.6
            effects.addChild(tr)
            tr.run(.sequence([.fadeOut(withDuration: 0.25), .removeFromParent()]))
        case .claw:
            spark(end, .yellow, 4)
        case .none:
            break
        }
    }

    private func flash(_ p: CGPoint, _ size: CGFloat, _ c: UIColor) {
        let f = SKSpriteNode(texture: Art.glow())
        f.size = CGSize(width: size, height: size)
        f.position = p
        f.color = c
        f.colorBlendFactor = 1
        f.blendMode = .add
        f.zPosition = 10
        effects.addChild(f)
        f.run(.sequence([.fadeOut(withDuration: 0.08), .removeFromParent()]))
    }

    private func spark(_ p: CGPoint, _ c: UIColor, _ size: CGFloat) {
        let s = SKSpriteNode(texture: Art.glow())
        s.size = CGSize(width: size, height: size)
        s.position = CGPoint(x: p.x + CGFloat.random(in: -4...4), y: p.y + CGFloat.random(in: -4...4))
        s.color = c
        s.colorBlendFactor = 1
        s.blendMode = .add
        s.zPosition = 10
        effects.addChild(s)
        s.run(.sequence([.group([.scale(to: 0.2, duration: 0.15), .fadeOut(withDuration: 0.15)]), .removeFromParent()]))
    }

    private func puff(_ p: CGPoint, _ size: CGFloat, _ life: TimeInterval, dark: Bool = false) {
        let s = SKSpriteNode(texture: Art.smoke())
        s.size = CGSize(width: size, height: size)
        s.position = p
        s.alpha = 0.55
        if dark {
            s.alpha = 0.35
            s.color = UIColor(white: 0.3, alpha: 1)
            s.colorBlendFactor = 1
            s.zPosition = 15
        }
        s.zPosition = dark ? 15 : 8
        s.zRotation = CGFloat.random(in: 0...6.28)
        effects.addChild(s)
        s.run(.sequence([.group([.scale(to: 2.4, duration: life), .fadeOut(withDuration: life),
                                 .moveBy(x: CGFloat.random(in: -6...6), y: CGFloat.random(in: 4...12), duration: life)]),
                         .removeFromParent()]))
    }

    private func explode(_ v: Vec2, size: CGFloat, big: Bool) {
        let p = CGPoint(x: v.x, y: v.y)
        // white flash
        let core = SKSpriteNode(texture: Art.glow())
        core.size = CGSize(width: size * 2.2, height: size * 2.2)
        core.position = p
        core.color = UIColor(red: 1, green: 0.97, blue: 0.85, alpha: 1)
        core.colorBlendFactor = 1
        core.blendMode = .add
        core.zPosition = 11.5
        effects.addChild(core)
        core.run(.sequence([.fadeOut(withDuration: 0.12), .removeFromParent()]))
        // a cluster of fireballs that swell, redden and fade
        for i in 0..<(big ? 5 : 2) {
            let f = SKSpriteNode(texture: Art.glow())
            let s = size * CGFloat.random(in: 1.1...1.8)
            f.size = CGSize(width: s, height: s)
            f.position = CGPoint(x: p.x + CGFloat.random(in: -size...size) * 0.45, y: p.y + CGFloat.random(in: -size...size) * 0.45)
            f.color = UIColor(red: 1, green: 0.62, blue: 0.18, alpha: 1)
            f.colorBlendFactor = 1
            f.blendMode = .add
            f.zPosition = 11
            f.setScale(0.35)
            f.alpha = 0.95
            effects.addChild(f)
            let life = big ? 0.55 : 0.32
            f.run(.sequence([.wait(forDuration: Double(i) * 0.04),
                             .group([.scale(to: 1.25, duration: life * 0.5),
                                     .colorize(with: UIColor(red: 0.8, green: 0.2, blue: 0.05, alpha: 1), colorBlendFactor: 1, duration: life),
                                     .sequence([.wait(forDuration: life * 0.4), .fadeOut(withDuration: life * 0.6)])]),
                             .removeFromParent()]))
        }
        // shockwave
        if big {
            let r = SKSpriteNode(texture: Art.ring())
            r.size = CGSize(width: size, height: size)
            r.position = p
            r.color = UIColor(red: 1, green: 0.85, blue: 0.6, alpha: 1)
            r.colorBlendFactor = 1
            r.blendMode = .add
            r.alpha = 0.7
            r.zPosition = 10.5
            effects.addChild(r)
            r.run(.sequence([.group([.scale(to: 4, duration: 0.35), .fadeOut(withDuration: 0.35)]), .removeFromParent()]))
        }
        // smoke rising
        for _ in 0..<(big ? 6 : 2) {
            puff(CGPoint(x: p.x + CGFloat.random(in: -size...size) * 0.5, y: p.y + CGFloat.random(in: -size...size) * 0.5), size * 0.9, big ? 1.6 : 0.8, dark: big)
        }
        // debris: hot sparks and dark chunks thrown out
        for i in 0..<(big ? 12 : 4) {
            let chunk = i % 2 == 0
            let d = SKSpriteNode(texture: chunk ? Art.debris() : Art.glow())
            d.size = chunk ? CGSize(width: 5, height: 5) : CGSize(width: 4, height: 4)
            if !chunk {
                d.color = UIColor(red: 1, green: 0.75, blue: 0.3, alpha: 1)
                d.colorBlendFactor = 1
                d.blendMode = .add
            }
            d.position = p
            d.zPosition = 11
            effects.addChild(d)
            let a = CGFloat.random(in: 0...(2 * .pi)), r = CGFloat.random(in: size * 0.8...(size * (big ? 2.8 : 1.8)))
            let t = Double.random(in: 0.35...0.65)
            d.run(.sequence([.group([.moveBy(x: cos(a) * r, y: sin(a) * r, duration: t),
                                     .rotate(byAngle: CGFloat.random(in: -8...8), duration: t),
                                     .sequence([.wait(forDuration: t * 0.6), .fadeOut(withDuration: t * 0.4)])]),
                             .removeFromParent()]))
        }
    }

    /// Infantry and drones: the body tips over, darkens and fades.
    private func collapse(_ e: Entity) {
        let colorOf: TeamColor = e.owner >= 0 ? world.players[e.owner].color : .blue
        let s = SKSpriteNode(texture: Art.unit(e.type, colorOf))
        let sz = Art.unitSize(e.type)
        s.size = CGSize(width: sz, height: sz)
        s.position = CGPoint(x: e.pos.x, y: e.pos.y)
        s.zRotation = CGFloat(atan2(e.dir.y, e.dir.x))
        s.zPosition = 4
        effects.addChild(s)
        s.run(.sequence([.group([.rotate(byAngle: CGFloat.random(in: -1.2...1.2), duration: 0.25),
                                 .scale(to: 0.8, duration: 0.25),
                                 .colorize(with: UIColor(white: 0.1, alpha: 1), colorBlendFactor: 0.7, duration: 0.4)]),
                         .wait(forDuration: 6), .fadeOut(withDuration: 2), .removeFromParent()]))
        if e.isWorker { explode(e.pos, size: 10, big: false) } else { puff(CGPoint(x: e.pos.x, y: e.pos.y), 14, 0.6) }
    }

    /// What's left behind: burnt hulls for vehicles, rubble for buildings.
    private func wreck(_ e: Entity) {
        let w: SKSpriteNode
        if e.isBuilding {
            w = SKSpriteNode(texture: Art.rubble())
            let s = CGFloat(e.st.footprint) * CGFloat(Defs.tile)
            w.size = CGSize(width: s, height: s)
        } else if e.type == .tank || e.type == .skimmer {
            w = SKSpriteNode(texture: Art.unit(e.type, .blue))
            let s = Art.unitSize(e.type)
            w.size = CGSize(width: s, height: s)
            w.color = UIColor(white: 0.08, alpha: 1)
            w.colorBlendFactor = 0.85
            w.zRotation = CGFloat(atan2(e.dir.y, e.dir.x))
        } else {
            return
        }
        w.position = CGPoint(x: e.pos.x, y: e.pos.y)
        w.zPosition = -4
        w.alpha = 0.85
        effects.addChild(w)
        w.run(.sequence([.wait(forDuration: 40), .fadeOut(withDuration: 5), .removeFromParent()]))
    }

    private var shaking = false
    private func shake(_ amount: CGFloat) {
        guard !shaking else { return }
        shaking = true
        var seq: [SKAction] = []
        var a = amount
        for _ in 0..<5 {
            let dx = CGFloat.random(in: -a...a), dy = CGFloat.random(in: -a...a)
            seq.append(.moveBy(x: dx, y: dy, duration: 0.03))
            seq.append(.moveBy(x: -dx, y: -dy, duration: 0.03))
            a *= 0.7
        }
        worldNode.run(.sequence(seq)) { [weak self] in
            self?.worldNode.position = .zero
            self?.shaking = false
        }
    }

    // MARK: ambience: weather and shimmer

    private var ambientTimer: Double = 0
    private var liquidTiles: [TilePoint] = []

    private func ambient(_ dt: Double) {
        ambientTimer += dt
        guard ambientTimer > 0.08, let r = visibleWorldRect else { return }
        ambientTimer = 0
        let biome = world.map.id.biome
        // weather drifting across the view
        let p = CGPoint(x: CGFloat.random(in: r.minX...r.maxX), y: CGFloat.random(in: r.minY...r.maxY))
        let s = SKSpriteNode(texture: Art.glow())
        s.blendMode = biome == .volcanic ? .add : .alpha
        s.zPosition = 40
        var drift = CGVector(dx: 0, dy: 0)
        var show = true
        switch biome {
        case .snow:
            s.size = CGSize(width: 5, height: 5); s.color = .white; drift = CGVector(dx: -30, dy: -60)
        case .desert:
            s.size = CGSize(width: 4, height: 4); s.color = UIColor(red: 0.95, green: 0.85, blue: 0.6, alpha: 1); drift = CGVector(dx: 80, dy: -10)
        case .volcanic:
            s.size = CGSize(width: 4, height: 4); s.color = UIColor(red: 1, green: 0.5, blue: 0.15, alpha: 1); drift = CGVector(dx: 10, dy: 50)
        case .grass:
            guard Int.random(in: 0..<3) == 0 else { show = false; break }
            s.size = CGSize(width: 4, height: 3); s.color = UIColor(red: 0.85, green: 1, blue: 0.5, alpha: 1); drift = CGVector(dx: 20, dy: 12)
        }
        if show {
            s.colorBlendFactor = 1
            s.alpha = 0
            s.position = p
            effects.addChild(s)
            let life = 2.6
            s.run(.sequence([.group([.move(by: CGVector(dx: drift.dx * life, dy: drift.dy * life), duration: life),
                                     .sequence([.fadeAlpha(to: biome == .grass ? 0.7 : 0.8, duration: 0.5), .wait(forDuration: life - 1.2), .fadeOut(withDuration: 0.7)])]),
                             .removeFromParent()]))
        }
        // glints on water, bubbling lava
        if liquidTiles.isEmpty {
            for y in 0..<world.map.height {
                for x in 0..<world.map.width where world.map.terrainAt(x, y) == .water { liquidTiles.append(TilePoint(x: x, y: y)) }
            }
            if liquidTiles.isEmpty { liquidTiles = [TilePoint(x: -1, y: -1)] }
        }
        for _ in 0..<2 {
            let t = liquidTiles[Int.random(in: 0..<liquidTiles.count)]
            guard t.x >= 0 else { break }
            let c = world.map.center(t)
            let cp = CGPoint(x: c.x + Double.random(in: -12...12), y: c.y + Double.random(in: -12...12))
            guard r.contains(cp) else { continue }
            let gl = SKSpriteNode(texture: Art.glow())
            gl.blendMode = .add
            gl.colorBlendFactor = 1
            gl.zPosition = -3
            gl.position = cp
            gl.alpha = 0
            if biome == .volcanic {
                gl.size = CGSize(width: 26, height: 26); gl.color = UIColor(red: 1, green: 0.55, blue: 0.1, alpha: 1)
            } else {
                gl.size = CGSize(width: 10, height: 4); gl.color = UIColor(white: 1, alpha: 1)
            }
            effects.addChild(gl)
            gl.run(.sequence([.fadeAlpha(to: biome == .volcanic ? 0.7 : 0.6, duration: 0.5), .fadeOut(withDuration: 0.9), .removeFromParent()]))
        }
    }

    private func scorch(_ v: Vec2, size: CGFloat) {
        let s = SKSpriteNode(texture: Art.scorch())
        s.size = CGSize(width: size, height: size)
        s.position = CGPoint(x: v.x, y: v.y)
        s.zPosition = -5
        s.zRotation = CGFloat.random(in: 0...6.28)
        effects.addChild(s)
        s.run(.sequence([.wait(forDuration: 25), .fadeOut(withDuration: 4), .removeFromParent()]))
    }

    private func sparkle(_ v: Vec2, _ r: CGFloat) {
        for i in 0..<6 {
            let a = CGFloat(i) / 6 * 2 * .pi
            spark(CGPoint(x: v.x + cos(a) * r, y: v.y + sin(a) * r), UIColor(red: 0.6, green: 1, blue: 1, alpha: 1), 10)
        }
    }
}
