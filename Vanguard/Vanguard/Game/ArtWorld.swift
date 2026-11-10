import SpriteKit
import UIKit

/// Buildings, neutral map objects, terrain and ambient effects. Buildings are drawn in a 2.5D style: you look down
/// from slightly south, so each block shows its roof and its south wall, and casts a shadow to the south-east.
extension Art {
    // MARK: building drawing helpers

    static func buildingSize(_ t: EntityType) -> CGFloat { CGFloat(t.stats.footprint) * CGFloat(Defs.tile) + 18 }

    static func building(_ t: EntityType, _ team: TeamColor) -> SKTexture {
        cachedTexture("b2-\(t.rawValue)-\(team.rawValue)") { buildingImage(t, team) }
    }

    static func cachedTexture(_ key: String, _ make: () -> UIImage) -> SKTexture {
        if let t = worldCache[key] { return t }
        let t = SKTexture(image: make())
        t.filteringMode = .linear
        worldCache[key] = t
        return t
    }
    private static var worldCache: [String: SKTexture] = [:]

    /// A box: roof on top, the south wall below it, a shadow behind. (x, y) is the north-west corner of the roof.
    static func block(_ g: CGContext, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ d: CGFloat, wall: CGFloat,
                      roof: UIColor, wallColor: UIColor? = nil, r: CGFloat = 3) {
        let wc = wallColor ?? shade(roof, 0.62)
        fill(g, rect(x + wall * 0.7, y + wall * 0.6, w, d, r), rgb(0, 0, 0, 0.32))
        let face = rect(x, y + d - wall - r, w, wall + r, r)
        fill(g, face, wc)
        // light catches the top of the wall
        fill(g, rect(x + 1, y + d - wall, w - 2, 1.6), shade(wc, 1.35))
        let top = rect(x, y, w, d - wall, r)
        shaded(g, top, roof, light: 1.3, dark: 0.78)
        stroke(g, top, shade(roof, 0.45), 1)
        stroke(g, face, shade(wc, 0.5), 0.8)
    }

    /// An upright cylinder (tanks, silos, stacks). (cx, cy) is the center of its base.
    static func cylinder(_ g: CGContext, _ cx: CGFloat, _ cy: CGFloat, _ rad: CGFloat, _ hgt: CGFloat, _ c: UIColor, band: UIColor? = nil) {
        fill(g, CGPath(ellipseIn: CGRect(x: cx - rad + hgt * 0.5, y: cy - rad * 0.45 + hgt * 0.35, width: rad * 2.2, height: rad), transform: nil), rgb(0, 0, 0, 0.3))
        let body = CGMutablePath()
        body.addRect(CGRect(x: cx - rad, y: cy - hgt, width: rad * 2, height: hgt))
        body.addEllipse(in: CGRect(x: cx - rad, y: cy - rad * 0.45, width: rad * 2, height: rad * 0.9))
        g.saveGState()
        g.addPath(body)
        g.clip()
        let colors = [shade(c, 0.55).cgColor, shade(c, 1.35).cgColor, c.cgColor, shade(c, 0.45).cgColor] as CFArray
        let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.3, 0.6, 1])!
        g.drawLinearGradient(grad, start: CGPoint(x: cx - rad, y: 0), end: CGPoint(x: cx + rad, y: 0), options: [])
        g.restoreGState()
        if let band {
            fill(g, rect(cx - rad, cy - hgt * 0.55, rad * 2, hgt * 0.18), band)
        }
        let top = CGPath(ellipseIn: CGRect(x: cx - rad, y: cy - hgt - rad * 0.45, width: rad * 2, height: rad * 0.9), transform: nil)
        shaded(g, top, shade(c, 1.15), light: 1.4, dark: 0.8)
        stroke(g, top, shade(c, 0.5), 0.8)
    }

    static func windows(_ g: CGContext, _ x0: CGFloat, _ y: CGFloat, count: Int, gap: CGFloat, w: CGFloat = 4, h: CGFloat = 3,
                        lit: UIColor = rgb(0.55, 0.9, 1, 0.95)) {
        for i in 0..<count {
            let x = x0 + CGFloat(i) * gap
            fill(g, rect(x, y, w, h, 0.8), lit)
            fill(g, rect(x, y, w, 1, 0.4), rgb(1, 1, 1, 0.5))
        }
    }

    static func foundation(_ g: CGContext, _ h: CGFloat, _ c: UIColor) {
        let base = rect(-h + 1, -h + 1, 2 * h - 2, 2 * h - 2, 4)
        fill(g, rect(-h + 4, -h + 5, 2 * h - 2, 2 * h - 2, 4), rgb(0, 0, 0, 0.25))
        shaded(g, base, concrete, light: 1.15, dark: 0.8)
        stroke(g, base, rgb(0.22, 0.22, 0.22, 0.85), 1.2)
        stroke(g, rect(-h + 3.5, -h + 3.5, 2 * h - 7, 2 * h - 7, 3), shade(c, 0.95).withAlphaComponent(0.9), 1.4)
        // corner bolts
        for (x, y) in [(-1, -1), (1, -1), (1, 1), (-1, 1)] as [(CGFloat, CGFloat)] {
            fill(g, circle(x * (h - 6), y * (h - 6), 1.6), darkSteel)
        }
        // panel seams
        g.setStrokeColor(rgb(0, 0, 0, 0.12).cgColor)
        g.setLineWidth(0.7)
        var k = -h + 16
        while k < h - 8 {
            g.move(to: CGPoint(x: k, y: -h + 4)); g.addLine(to: CGPoint(x: k, y: h - 4))
            k += 16
        }
        g.strokePath()
    }

    static func buildingImage(_ t: EntityType, _ team: TeamColor, iconScale: CGFloat? = nil) -> UIImage {
        let s = buildingSize(t)
        let c = color(team)
        return image(s, s, scale: iconScale ?? scale) { g in
            g.translateBy(x: s / 2, y: s / 2)
            let h = CGFloat(t.stats.footprint) * CGFloat(Defs.tile) / 2
            switch t {
            case .hq: drawHQ2(g, c, h)
            case .depot: drawDepot2(g, c, h)
            case .barracks: drawBarracks2(g, c, h)
            case .factory: drawFactory2(g, c, h)
            case .lab: drawLab2(g, c, h)
            case .turret: drawBunker(g, c, h)
            case .radar: drawRadarBase(g, c, h)
            case .shield: drawShieldBase(g, c, h)
            default: break
            }
        }
    }

    // MARK: buildings

    private static func drawHQ2(_ g: CGContext, _ c: UIColor, _ h: CGFloat) {
        foundation(g, h, c)
        // landing pad markings in the corners
        g.setStrokeColor(hazard.withAlphaComponent(0.85).cgColor)
        g.setLineWidth(2)
        for (x, y) in [(-1, -1), (1, -1)] as [(CGFloat, CGFloat)] {
            g.move(to: CGPoint(x: x * (h - 9), y: y * (h - 14)))
            g.addLine(to: CGPoint(x: x * (h - 9), y: y * (h - 24)))
        }
        g.strokePath()
        // side wings
        block(g, -h + 6, -10, 18, 34, wall: 8, roof: steel, r: 2)
        block(g, h - 24, -10, 18, 34, wall: 8, roof: steel, r: 2)
        windows(g, -h + 9, 18, count: 3, gap: 5, w: 3, h: 2.5)
        windows(g, h - 21, 18, count: 3, gap: 5, w: 3, h: 2.5)
        // main hall
        block(g, -28, -38, 56, 66, wall: 14, roof: rgb(0.66, 0.69, 0.73), r: 5)
        // big door with team frame and lit windows on the south wall
        fill(g, rect(-11, 16, 22, 12, 2), shade(c, 0.8))
        fill(g, rect(-8, 18, 16, 10, 1.5), rgb(0.08, 0.09, 0.11))
        fill(g, rect(-8, 18, 16, 1.6), hazard)
        windows(g, -25, 19, count: 2, gap: 6)
        windows(g, 15, 19, count: 2, gap: 6)
        // roof: central dome in team color, vents, antenna
        fill(g, circle(2, -9, 19), rgb(0, 0, 0, 0.25))
        let dome = circle(0, -11, 17)
        shaded(g, dome, c, light: 1.7, dark: 0.45)
        stroke(g, dome, shade(c, 0.35), 1.3)
        stroke(g, circle(0, -11, 11), shade(c, 1.4).withAlphaComponent(0.6), 1)
        fill(g, circle(-5, -16, 4), rgb(1, 1, 1, 0.4))
        for x: CGFloat in [-22, 16] {
            shaded(g, rect(x, -34, 7, 7, 1.5), darkSteel, light: 1.6)
            fill(g, rect(x + 1.5, -32.5, 4, 1), rgb(0, 0, 0, 0.5))
            fill(g, rect(x + 1.5, -30.5, 4, 1), rgb(0, 0, 0, 0.5))
        }
        fill(g, rect(19, -44, 2.4, 14, 1), darkSteel)
        fill(g, rect(15, -40, 10, 1.6), darkSteel)
    }

    private static func drawDepot2(_ g: CGContext, _ c: UIColor, _ h: CGFloat) {
        foundation(g, h, c)
        // energy cells in a row, the back ones taller
        cylinder(g, -12, -2, 9, 20, steel, band: c)
        cylinder(g, 12, -2, 9, 20, steel, band: c)
        cylinder(g, -12, 20, 8, 14, steel, band: c)
        cylinder(g, 12, 20, 8, 14, steel, band: c)
        // glowing bus bars
        g.setStrokeColor(rgb(1, 0.85, 0.3, 0.95).cgColor)
        g.setLineWidth(2)
        g.move(to: CGPoint(x: -3, y: -16)); g.addLine(to: CGPoint(x: 3, y: -16))
        g.move(to: CGPoint(x: -4, y: 5)); g.addLine(to: CGPoint(x: 4, y: 5))
        g.strokePath()
        fill(g, circle(0, -16, 2.6), rgb(1, 0.95, 0.6))
        fill(g, circle(0, 5, 2.4), rgb(1, 0.95, 0.6))
    }

    private static func drawBarracks2(_ g: CGContext, _ c: UIColor, _ h: CGFloat) {
        foundation(g, h, c)
        // sandbags by the door
        for i in 0..<5 {
            fill(g, rect(-26 + CGFloat(i) * 6.5, h - 10, 6, 4, 2), rgb(0.72, 0.64, 0.45))
            fill(g, rect(4 + CGFloat(i) * 6.5, h - 10, 6, 4, 2), rgb(0.72, 0.64, 0.45))
        }
        block(g, -38, -36, 76, 62, wall: 15, roof: rgb(0.36, 0.40, 0.38), r: 3)
        // roof ridges
        g.setStrokeColor(rgb(0, 0, 0, 0.28).cgColor)
        g.setLineWidth(1)
        var y: CGFloat = -31
        while y < 8 {
            g.move(to: CGPoint(x: -34, y: y)); g.addLine(to: CGPoint(x: 34, y: y))
            y += 5
        }
        g.strokePath()
        // team stripe and chevrons on the roof
        fill(g, rect(-38, -16, 76, 8), shade(c, 0.9))
        for i in 0..<3 {
            let x = CGFloat(-12 + i * 10)
            fill(g, poly([(x, -15), (x + 6, -12), (x, -9), (x + 2, -12)]), rgb(1, 1, 1, 0.85))
        }
        // south wall: door, windows, banner
        fill(g, rect(-9, 15, 18, 11, 1.5), rgb(0.08, 0.09, 0.1))
        fill(g, rect(-9, 15, 18, 1.8), hazard)
        windows(g, -33, 17, count: 3, gap: 7)
        windows(g, 13, 17, count: 3, gap: 7)
        fill(g, rect(30, 12, 5, 13, 1), c)
        // vents
        shaded(g, rect(-34, -33, 8, 7, 1.5), steel)
        shaded(g, rect(26, -33, 8, 7, 1.5), steel)
    }

    /// Smoke stack positions (relative to the building center, y up) for the renderer's smoke.
    static let factoryStacks: [CGPoint] = [CGPoint(x: -30, y: 40), CGPoint(x: -19, y: 40)]

    private static func drawFactory2(_ g: CGContext, _ c: UIColor, _ h: CGFloat) {
        foundation(g, h, c)
        block(g, -40, -32, 80, 64, wall: 16, roof: rgb(0.50, 0.51, 0.54), r: 3)
        // sawtooth skylights
        for i in 0..<5 {
            let x = -36 + CGFloat(i) * 15
            fill(g, poly([(x, -28), (x + 11, -28), (x + 13, 6), (x + 2, 6)]), rgb(0.58, 0.82, 0.95, 0.65))
            fill(g, poly([(x + 11, -28), (x + 14, -28), (x + 16, 6), (x + 13, 6)]), rgb(0.25, 0.27, 0.3, 0.8))
        }
        // gear emblem
        let gx: CGFloat = 26, gy: CGFloat = -14
        let gear = CGMutablePath()
        for i in 0..<8 {
            let a = CGFloat(i) * .pi / 4
            gear.addRect(CGRect(x: -2, y: -10, width: 4, height: 5), transform: CGAffineTransform(translationX: gx, y: gy).rotated(by: a))
        }
        fill(g, gear, shade(c, 0.9))
        shaded(g, circle(gx, gy, 7.5), c)
        fill(g, circle(gx, gy, 2.6), rgb(0.3, 0.3, 0.33))
        // south wall: big garage door with hazard stripes
        g.saveGState()
        g.addPath(rect(-18, 18, 36, 14, 1))
        g.clip()
        fill(g, rect(-18, 18, 36, 14), hazard)
        g.setStrokeColor(rgb(0.1, 0.1, 0.1).cgColor)
        g.setLineWidth(3)
        var d: CGFloat = -40
        while d < 40 { g.move(to: CGPoint(x: d, y: 18)); g.addLine(to: CGPoint(x: d + 14, y: 32)); d += 7 }
        g.strokePath()
        g.restoreGState()
        fill(g, rect(-14, 21, 28, 11, 1), rgb(0.12, 0.13, 0.15))
        windows(g, -36, 20, count: 2, gap: 7)
        windows(g, 24, 20, count: 2, gap: 7)
        // stacks at the back
        cylinder(g, -30, -30, 5, 16, darkSteel, band: shade(c, 0.9))
        cylinder(g, -19, -30, 5, 16, darkSteel, band: shade(c, 0.9))
        fill(g, CGPath(ellipseIn: CGRect(x: -34, y: -48.5, width: 8, height: 3.5), transform: nil), rgb(0.05, 0.05, 0.05))
        fill(g, CGPath(ellipseIn: CGRect(x: -23, y: -48.5, width: 8, height: 3.5), transform: nil), rgb(0.05, 0.05, 0.05))
    }

    private static func drawLab2(_ g: CGContext, _ c: UIColor, _ h: CGFloat) {
        foundation(g, h, c)
        // drum wall
        cylinder(g, 0, 16, 23, 12, steel, band: c)
        // glass dome
        fill(g, circle(3, -2, 22), rgb(0, 0, 0, 0.2))
        let dome = CGPath(ellipseIn: CGRect(x: -21, y: -25, width: 42, height: 38), transform: nil)
        shaded(g, dome, rgb(0.35, 0.78, 0.98), light: 1.9, dark: 0.42)
        stroke(g, dome, rgb(0.2, 0.4, 0.55), 1)
        g.setStrokeColor(rgb(1, 1, 1, 0.35).cgColor)
        g.setLineWidth(0.8)
        g.move(to: CGPoint(x: -21, y: -6)); g.addQuadCurve(to: CGPoint(x: 21, y: -6), control: CGPoint(x: 0, y: 2))
        g.move(to: CGPoint(x: 0, y: -25)); g.addLine(to: CGPoint(x: 0, y: 13))
        g.strokePath()
        fill(g, CGPath(ellipseIn: CGRect(x: -13, y: -20, width: 10, height: 7), transform: nil), rgb(1, 1, 1, 0.55))
        // little dish
        cylinder(g, 22, -18, 3, 8, darkSteel)
        shaded(g, CGPath(ellipseIn: CGRect(x: 15, y: -32, width: 14, height: 9), transform: nil), rgb(0.88, 0.9, 0.92), light: 1.2)
    }

    private static func drawBunker(_ g: CGContext, _ c: UIColor, _ h: CGFloat) {
        fill(g, octagon(5, 6, h - 2), rgb(0, 0, 0, 0.28))
        // lower ring = wall, upper = roof
        shaded(g, octagon(0, 4, h - 2), shade(concrete, 0.7), light: 1.05, dark: 0.75)
        let top = octagon(0, -2, h - 4)
        shaded(g, top, concrete, light: 1.2, dark: 0.75)
        stroke(g, top, gunmetal, 1.2)
        stroke(g, octagon(0, -2, h - 8), shade(c, 0.9), 2)
        // firing slits on the south face
        for x: CGFloat in [-14, -4, 6] { fill(g, rect(x, h - 9, 8, 2.2, 1), rgb(0.05, 0.05, 0.05)) }
    }

    private static func drawRadarBase(_ g: CGContext, _ c: UIColor, _ h: CGFloat) {
        foundation(g, h, c)
        block(g, -18, -8, 36, 30, wall: 9, roof: steel, r: 3)
        windows(g, -14, 15, count: 4, gap: 7, w: 4, h: 2.5, lit: rgb(0.5, 1, 0.6, 0.95))
        fill(g, rect(-16, -6, 32, 4), shade(c, 0.9))
        // mast
        cylinder(g, 0, 2, 3.5, 22, darkSteel)
    }

    /// The radar dish (rotates). Faces +x.
    static func radarDish() -> SKTexture {
        cachedTexture("radardish") {
            image(40, 40) { g in
                g.translateBy(x: 20, y: 20)
                let dish = CGMutablePath()
                dish.addArc(center: CGPoint(x: -6, y: 0), radius: 16, startAngle: -1.1, endAngle: 1.1, clockwise: false)
                dish.addArc(center: CGPoint(x: -14, y: 0), radius: 14, startAngle: 0.9, endAngle: -0.9, clockwise: true)
                dish.closeSubpath()
                shaded(g, dish, rgb(0.9, 0.92, 0.95), light: 1.1, dark: 0.7)
                stroke(g, dish, darkSteel, 1)
                fill(g, rect(-4, -1, 14, 2), darkSteel)
                fill(g, circle(10, 0, 2.2), rgb(1, 0.3, 0.25))
                fill(g, circle(-4, 0, 3.5), gunmetal)
            }
        }
    }

    private static func drawShieldBase(_ g: CGContext, _ c: UIColor, _ h: CGFloat) {
        foundation(g, h, c)
        for (x, y) in [(-17, -12), (17, -12), (-17, 20), (17, 20)] as [(CGFloat, CGFloat)] {
            cylinder(g, x, y, 5, 12, darkSteel, band: c)
            fill(g, circle(x, y - 12, 2), rgb(0.6, 0.95, 1))
        }
        cylinder(g, 0, 10, 11, 14, steel, band: shade(c, 0.9))
    }

    /// The shield emitter (glows and pulses); white so the renderer can tint it.
    static func shieldOrb() -> SKTexture {
        cachedTexture("shieldorb") {
            image(36, 36) { g in
                let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                      colors: [rgb(1, 1, 1, 1).cgColor, rgb(0.85, 0.95, 1, 0.8).cgColor, rgb(0.7, 0.9, 1, 0).cgColor] as CFArray,
                                      locations: [0, 0.35, 1])!
                g.drawRadialGradient(grad, startCenter: CGPoint(x: 18, y: 18), startRadius: 0, endCenter: CGPoint(x: 18, y: 18), endRadius: 18, options: [])
            }
        }
    }

    /// The shield's area: a soft dome edge. White, tinted by team.
    static func shieldDome() -> SKTexture {
        cachedTexture("shielddome") {
            let s: CGFloat = 128
            return image(s, s, scale: 2) { g in
                let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                      colors: [rgb(1, 1, 1, 0.02).cgColor, rgb(1, 1, 1, 0.10).cgColor, rgb(1, 1, 1, 0.55).cgColor, rgb(1, 1, 1, 0).cgColor] as CFArray,
                                      locations: [0, 0.8, 0.96, 1])!
                g.drawRadialGradient(grad, startCenter: CGPoint(x: s / 2, y: s / 2), startRadius: 0,
                                     endCenter: CGPoint(x: s / 2, y: s / 2), endRadius: s / 2, options: [])
            }
        }
    }

    static func turretGun(_ team: TeamColor) -> SKTexture {
        cachedTexture("tg-\(team.rawValue)") {
            let s: CGFloat = 64
            let c = color(team)
            return image(s, s) { g in
                g.translateBy(x: s / 2, y: s / 2)
                for y: CGFloat in [-4.5, 2] {
                    shaded(g, rect(6, y, 22, 2.8, 1), darkSteel, light: 1.7)
                    fill(g, rect(25, y - 0.6, 4, 4, 1), gunmetal)
                }
                let head = rect(-11, -11, 22, 22, 6)
                shaded(g, head, c)
                stroke(g, head, shade(c, 0.35), 1.2)
                fill(g, rect(-7, -7, 9, 14, 3), shade(c, 0.65))
                fill(g, circle(-2.5, 0, 2), rgb(1, 0.3, 0.2))
            }
        }
    }

    /// Big gun for a Fortress command center.
    static func fortressGun(_ team: TeamColor) -> SKTexture {
        cachedTexture("fg-\(team.rawValue)") {
            let s: CGFloat = 70
            let c = color(team)
            return image(s, s) { g in
                g.translateBy(x: s / 2, y: s / 2)
                shaded(g, rect(6, -3.5, 26, 7, 2), darkSteel, light: 1.7)
                fill(g, rect(29, -4.5, 5, 9, 1.5), gunmetal)
                let head = octagon(0, 0, 12)
                shaded(g, head, shade(c, 0.85))
                stroke(g, head, shade(c, 0.35), 1.2)
                fill(g, rect(-8, -4, 10, 8, 2), shade(c, 0.55))
                fill(g, circle(-3, 0, 2), rgb(1, 0.4, 0.2))
            }
        }
    }

    /// Small badge showing a building's specialization.
    static func specBadge(_ sp: Spec) -> SKTexture {
        cachedTexture("badge\(sp.rawValue)") { specIcon(sp) }
    }

    static func specIcon(_ sp: Spec) -> UIImage {
        image(40, 40, scale: 2) { g in
            let bg = circle(20, 20, 17)
            let tint: UIColor
            switch sp {
            case .fortress, .armory, .reactor: tint = rgb(0.75, 0.35, 0.25)
            case .refinery: tint = rgb(0.2, 0.65, 0.8)
            case .drillYard, .assemblyLine: tint = rgb(0.85, 0.65, 0.15)
            }
            shaded(g, bg, tint, light: 1.6)
            stroke(g, bg, .white, 1.8)
            g.setStrokeColor(UIColor.white.cgColor)
            g.setFillColor(UIColor.white.cgColor)
            g.setLineWidth(2.4)
            switch sp {
            case .fortress:
                fill(g, poly([(11, 26), (11, 15), (15, 15), (15, 18), (18, 18), (18, 15), (22, 15), (22, 18), (25, 18), (25, 15), (29, 15), (29, 26)]), .white)
            case .refinery:
                fill(g, poly([(20, 9), (28, 20), (20, 31), (12, 20)]), .white)
                fill(g, poly([(20, 13), (24, 20), (20, 27), (16, 20)]), tint)
            case .drillYard, .assemblyLine:
                for k in 0..<3 {
                    let x = CGFloat(10 + k * 7)
                    fill(g, poly([(x, 12), (x + 8, 20), (x, 28), (x + 3, 20)]), .white)
                }
            case .armory, .reactor:
                fill(g, poly([(20, 9), (30, 13), (28, 25), (20, 32), (12, 25), (10, 13)]), .white)
                fill(g, rect(18, 15, 4, 11), tint)
                fill(g, rect(14.5, 18.5, 11, 4), tint)
            }
        }
    }

    // MARK: neutral objects

    static func crystal(_ variant: Int, rich: Bool = false) -> SKTexture {
        cachedTexture("cr\(variant % 4)-\(rich)") { crystalImage(variant, rich: rich, scale: scale) }
    }

    static func crystalImage(_ variant: Int, rich: Bool = false, scale sc: CGFloat) -> UIImage {
        let s: CGFloat = 40
        let base = rich ? rgb(0.72, 0.38, 0.98) : rgb(0.25, 0.85, 0.95)
        let edge = rich ? rgb(0.95, 0.8, 1, 0.9) : rgb(0.75, 1, 1, 0.9)
        return image(s, s, scale: sc) { g in
            g.translateBy(x: s / 2, y: s / 2)
            var r = Rng(seed: UInt64(variant % 4) * 977 + 5)
            fill(g, CGPath(ellipseIn: CGRect(x: -14, y: -7, width: 30, height: 18), transform: nil), rgb(0, 0, 0, 0.25))
            fill(g, circle(0, 2, 14), base.withAlphaComponent(0.14))
            let count = 4 + variant % 2
            var shards: [(CGFloat, CGFloat, CGFloat, CGFloat)] = []
            for i in 0..<count {
                let a = CGFloat(i) / CGFloat(count) * 2 * .pi + CGFloat(r.range(-0.4, 0.4))
                let d = CGFloat(r.range(2, 7))
                shards.append((cos(a) * d, sin(a) * d * 0.7, CGFloat(r.range(9, 15)), CGFloat(r.range(3, 4.5))))
            }
            shards.sort { $0.1 < $1.1 }
            for (x, y, len, w) in shards {
                let lean = x * 0.25
                let p = poly([(x - w, y + 3), (x - w * 0.6 + lean, y - len), (x + lean, y - len - 3),
                              (x + w * 0.6 + lean, y - len), (x + w, y + 3), (x, y + 5)])
                shaded(g, p, base, light: 1.9, dark: 0.45)
                stroke(g, p, edge, 0.7)
                g.setStrokeColor(rgb(1, 1, 1, 0.7).cgColor)
                g.setLineWidth(0.8)
                g.move(to: CGPoint(x: x + lean * 0.5, y: y - len))
                g.addLine(to: CGPoint(x: x - w * 0.3, y: y + 2))
                g.strokePath()
            }
        }
    }

    /// Watch tower: a stone base and a timber lookout. The lantern is a separate tinted sprite.
    static func watchTower() -> SKTexture {
        cachedTexture("watchtower") {
            image(64, 64) { g in
                g.translateBy(x: 32, y: 32)
                fill(g, octagon(6, 8, 22), rgb(0, 0, 0, 0.3))
                shaded(g, octagon(0, 4, 22), rgb(0.45, 0.43, 0.4), light: 1.1, dark: 0.75)
                let top = octagon(0, -2, 20)
                shaded(g, top, rgb(0.62, 0.6, 0.56), light: 1.25, dark: 0.75)
                stroke(g, top, rgb(0.25, 0.24, 0.22), 1.2)
                // stone courses
                g.setStrokeColor(rgb(0, 0, 0, 0.2).cgColor)
                g.setLineWidth(0.8)
                for k in stride(from: CGFloat(-12), through: 12, by: 6) {
                    g.move(to: CGPoint(x: -18, y: k)); g.addLine(to: CGPoint(x: 18, y: k))
                }
                g.strokePath()
                // timber lookout
                fill(g, rect(-10, -24, 20, 4, 1), rgb(0.42, 0.28, 0.16))
                shaded(g, rect(-11, -20, 22, 20, 2), rgb(0.55, 0.38, 0.22), light: 1.3)
                stroke(g, rect(-11, -20, 22, 20, 2), rgb(0.25, 0.16, 0.08), 1)
                fill(g, poly([(-14, -20), (0, -30), (14, -20)]), rgb(0.5, 0.22, 0.16))
                fill(g, rect(-4, -12, 8, 6, 1), rgb(0.1, 0.08, 0.06))
            }
        }
    }

    static func debris() -> SKTexture {
        cachedTexture("debris") {
            image(8, 8, scale: 2) { g in
                fill(g, poly([(1, 3), (4, 0.5), (7.5, 2.5), (6, 7), (2, 6.5)]), rgb(0.18, 0.17, 0.16))
                fill(g, poly([(2, 3), (4, 1.5), (6, 3)]), rgb(0.45, 0.43, 0.4))
            }
        }
    }

    static func rubble() -> SKTexture {
        cachedTexture("rubble") {
            image(64, 64, scale: 1.5) { g in
                var r = Rng(seed: 31)
                for _ in 0..<26 {
                    let x = CGFloat(r.range(10, 54)), y = CGFloat(r.range(10, 54)), s = CGFloat(r.range(2, 6))
                    let k = CGFloat(r.range(0.25, 0.5))
                    fill(g, poly([(x - s, y), (x - s * 0.3, y - s), (x + s, y - s * 0.4), (x + s * 0.6, y + s * 0.7)]), rgb(k, k * 0.95, k * 0.9, 0.9))
                }
            }
        }
    }

    // MARK: terrain

    struct Palette {
        var ground: (CGFloat, CGFloat, CGFloat)
        var groundVar: (CGFloat, CGFloat, CGFloat)
        var dirt: UIColor
        var dirtSpeck: UIColor
        var rock: (UIColor, UIColor, UIColor)
        var cliff: (UIColor, UIColor, UIColor)
        var shore: UIColor
        var shallow: UIColor
        var deep: UIColor
        var glint: UIColor
        var canopy: (UIColor, UIColor)
        var blotchLight: UIColor
        var blotchDark: UIColor
    }

    static func palette(_ b: Biome) -> Palette {
        switch b {
        case .grass:
            return Palette(ground: (0.24, 0.42, 0.18), groundVar: (0.08, 0.12, 0.05), dirt: rgb(0.53, 0.43, 0.29), dirtSpeck: rgb(0.38, 0.31, 0.22, 0.8),
                           rock: (rgb(0.68, 0.64, 0.56), rgb(0.46, 0.43, 0.38), rgb(0.27, 0.25, 0.23)),
                           cliff: (rgb(0.62, 0.58, 0.5), rgb(0.42, 0.38, 0.33), rgb(0.2, 0.18, 0.16)),
                           shore: rgb(0.80, 0.74, 0.52), shallow: rgb(0.22, 0.52, 0.64), deep: rgb(0.13, 0.36, 0.55), glint: rgb(0.85, 0.95, 1, 0.45),
                           canopy: (rgb(0.16, 0.42, 0.16), rgb(0.32, 0.6, 0.24)),
                           blotchLight: rgb(0.45, 0.62, 0.28, 0.12), blotchDark: rgb(0.12, 0.25, 0.1, 0.12))
        case .desert:
            return Palette(ground: (0.80, 0.68, 0.45), groundVar: (0.08, 0.07, 0.05), dirt: rgb(0.68, 0.48, 0.3), dirtSpeck: rgb(0.52, 0.36, 0.22, 0.8),
                           rock: (rgb(0.85, 0.6, 0.4), rgb(0.66, 0.42, 0.26), rgb(0.38, 0.22, 0.14)),
                           cliff: (rgb(0.86, 0.62, 0.42), rgb(0.66, 0.42, 0.26), rgb(0.32, 0.18, 0.11)),
                           shore: rgb(0.93, 0.86, 0.66), shallow: rgb(0.25, 0.68, 0.66), deep: rgb(0.12, 0.48, 0.55), glint: rgb(0.9, 1, 1, 0.5),
                           canopy: (rgb(0.24, 0.48, 0.2), rgb(0.42, 0.62, 0.26)),
                           blotchLight: rgb(0.98, 0.9, 0.7, 0.14), blotchDark: rgb(0.55, 0.42, 0.25, 0.12))
        case .snow:
            return Palette(ground: (0.86, 0.9, 0.95), groundVar: (0.05, 0.05, 0.03), dirt: rgb(0.62, 0.64, 0.66), dirtSpeck: rgb(0.45, 0.47, 0.5, 0.8),
                           rock: (rgb(0.7, 0.74, 0.8), rgb(0.48, 0.52, 0.58), rgb(0.26, 0.28, 0.33)),
                           cliff: (rgb(0.78, 0.82, 0.88), rgb(0.5, 0.55, 0.62), rgb(0.24, 0.27, 0.33)),
                           shore: rgb(0.94, 0.97, 1), shallow: rgb(0.66, 0.84, 0.94), deep: rgb(0.52, 0.74, 0.88), glint: rgb(1, 1, 1, 0.7),
                           canopy: (rgb(0.1, 0.3, 0.22), rgb(0.2, 0.42, 0.3)),
                           blotchLight: rgb(1, 1, 1, 0.2), blotchDark: rgb(0.6, 0.7, 0.85, 0.12))
        case .volcanic:
            return Palette(ground: (0.24, 0.21, 0.2), groundVar: (0.06, 0.04, 0.03), dirt: rgb(0.32, 0.25, 0.21), dirtSpeck: rgb(0.16, 0.12, 0.1, 0.9),
                           rock: (rgb(0.3, 0.28, 0.3), rgb(0.17, 0.16, 0.18), rgb(0.06, 0.05, 0.06)),
                           cliff: (rgb(0.36, 0.3, 0.28), rgb(0.2, 0.16, 0.15), rgb(0.07, 0.05, 0.05)),
                           shore: rgb(0.2, 0.08, 0.04), shallow: rgb(1, 0.45, 0.08), deep: rgb(0.95, 0.75, 0.2), glint: rgb(1, 0.95, 0.6, 0.7),
                           canopy: (rgb(0.14, 0.11, 0.1), rgb(0.26, 0.2, 0.17)),
                           blotchLight: rgb(0.45, 0.35, 0.3, 0.12), blotchDark: rgb(0.05, 0.04, 0.04, 0.2))
        }
    }

    static func hash(_ x: Int, _ y: Int, _ s: UInt64) -> Double {
        var h = UInt64(bitPattern: Int64(x)) &* 0x9E37_79B1_85EB_CA87 ^ UInt64(bitPattern: Int64(y)) &* 0xC2B2_AE3D_27D4_EB4F ^ s
        h ^= h >> 29
        h = h &* 0xBF58_476D_1CE4_E5B9
        h ^= h >> 32
        return Double(h & 0xFFFFFF) / Double(0xFFFFFF)
    }

    static func noise(_ x: Double, _ y: Double, _ s: UInt64) -> Double {
        let x0 = Int(floor(x)), y0 = Int(floor(y))
        let fx = x - Double(x0), fy = y - Double(y0)
        let sx = fx * fx * (3 - 2 * fx), sy = fy * fy * (3 - 2 * fy)
        let a = hash(x0, y0, s), b = hash(x0 + 1, y0, s), c = hash(x0, y0 + 1, s), d = hash(x0 + 1, y0 + 1, s)
        return (a + (b - a) * sx) + ((c + (d - c) * sx) - (a + (b - a) * sx)) * sy
    }

    static let chunkTiles = 16

    /// One chunk of ground art, drawn with the world's y-up convention.
    static func terrainChunk(_ map: GameMap, cx: Int, cy: Int) -> SKTexture {
        let T = CGFloat(Defs.tile)
        let n = chunkTiles
        let size = CGFloat(n) * T
        let seed = map.decoSeed
        let biome = map.id.biome
        let pal = palette(biome)
        let img = image(size, size, scale: 1.25) { g in
            g.translateBy(x: 0, y: size)
            g.scaleBy(x: 1, y: -1)
            let ox = cx * n, oy = cy * n
            func each(_ match: (Terrain) -> Bool, _ body: (CGFloat, CGFloat, Int, Int) -> Void) {
                for ty in -2...(n + 1) {
                    for tx in -2...(n + 1) {
                        let wx = ox + tx, wy = oy + ty
                        if match(map.terrainAt(wx, wy)) {
                            body((CGFloat(tx) + 0.5) * T, (CGFloat(ty) + 0.5) * T, wx, wy)
                        }
                    }
                }
            }
            // ground with large soft variation; high ground a little lighter
            for ty in -1...n {
                for tx in -1...n {
                    let wx = ox + tx, wy = oy + ty
                    let v = CGFloat(noise(Double(wx) / 6, Double(wy) / 6, seed) * 0.6 + noise(Double(wx) / 2.3, Double(wy) / 2.3, seed + 1) * 0.4)
                    let lift: CGFloat = map.elevationAt(wx, wy) == 1 ? 0.06 : 0
                    let col = rgb(pal.ground.0 + pal.groundVar.0 * v + lift, pal.ground.1 + pal.groundVar.1 * v + lift, pal.ground.2 + pal.groundVar.2 * v + lift)
                    g.setFillColor(col.cgColor)
                    g.fill(CGRect(x: CGFloat(tx) * T - 0.5, y: CGFloat(ty) * T - 0.5, width: T + 1, height: T + 1))
                }
            }
            for ty in -1...n {
                for tx in -1...n {
                    let wx = ox + tx, wy = oy + ty
                    for k in 0..<3 {
                        let h = hash(wx * 3 + k, wy, seed + 7)
                        let px = (CGFloat(tx) + CGFloat(hash(wx, wy * 5 + k, seed + 3))) * T
                        let py = (CGFloat(ty) + CGFloat(hash(wx * 7 + k, wy, seed + 4))) * T
                        let r = 6 + CGFloat(h) * 12
                        fill(g, circle(px, py, r), hash(wx, wy + k * 11, seed + 9) > 0.5 ? pal.blotchLight : pal.blotchDark)
                    }
                }
            }
            // desert: dune ripples; snow: soft drifts
            if biome == .desert || biome == .snow {
                g.setStrokeColor((biome == .desert ? rgb(0.6, 0.48, 0.3, 0.18) : rgb(0.7, 0.78, 0.9, 0.25)).cgColor)
                g.setLineWidth(1.2)
                for ty in stride(from: -1, through: n, by: 1) {
                    for tx in stride(from: -1, through: n, by: 2) where hash(ox + tx, oy + ty, seed + 61) > 0.55 {
                        let x = CGFloat(tx) * T, y = CGFloat(ty) * T + CGFloat(hash(ox + tx, oy + ty, seed + 62)) * T
                        g.move(to: CGPoint(x: x, y: y))
                        g.addQuadCurve(to: CGPoint(x: x + 2 * T, y: y + 4), control: CGPoint(x: x + T, y: y + 10))
                    }
                }
                g.strokePath()
            }
            // dirt and ramps
            // (each band is one flat layer, so overlapping tiles don't show as darker lobes)
            for (radius, alpha, dark) in [(0.9, 0.3, false), (0.76, 0.65, false), (0.6, 1.0, false)] as [(CGFloat, CGFloat, Bool)] {
                g.saveGState()
                g.setAlpha(alpha)
                g.beginTransparencyLayer(auxiliaryInfo: nil)
                g.setFillColor((dark ? shade(pal.dirt, 0.55) : pal.dirt).cgColor)
                each({ $0 == .dirt || $0 == .ramp }) { x, y, wx, wy in
                    let jx = CGFloat(hash(wx, wy, seed) - 0.5) * 14, jy = CGFloat(hash(wx, wy, seed + 5) - 0.5) * 14
                    g.fillEllipse(in: CGRect(x: x + jx - T * radius, y: y + jy - T * radius, width: T * radius * 2, height: T * radius * 2))
                }
                g.endTransparencyLayer()
                g.restoreGState()
            }
            // fine grain everywhere on open ground
            for ty in 0..<n {
                for tx in 0..<n {
                    let wx = ox + tx, wy = oy + ty
                    let t = map.terrainAt(wx, wy)
                    guard t == .grass || t == .dirt || t == .ramp else { continue }
                    for k in 0..<5 {
                        let px = (CGFloat(tx) + CGFloat(hash(wx * 5 + k, wy, seed + 111))) * T
                        let py = (CGFloat(ty) + CGFloat(hash(wx, wy * 5 + k, seed + 112))) * T
                        let light = hash(wx + k, wy - k, seed + 113) > 0.5
                        g.setFillColor((light ? UIColor(white: 1, alpha: 0.07) : UIColor(white: 0, alpha: 0.09)).cgColor)
                        g.fill(CGRect(x: px, y: py, width: 1.6, height: 1.6))
                    }
                }
            }
            each({ $0 == .dirt || $0 == .ramp }) { x, y, wx, wy in
                for k in 0..<3 {
                    let px = x + CGFloat(hash(wx + k, wy, seed + 21) - 0.5) * T
                    let py = y + CGFloat(hash(wx, wy + k, seed + 22) - 0.5) * T
                    fill(g, circle(px, py, 1.4 + CGFloat(hash(wx, wy, seed + UInt64(k))) * 1.4), pal.dirtSpeck)
                }
            }
            // ramps: step lines across the slope
            each({ $0 == .ramp }) { x, y, wx, wy in
                var hx = 0, hy = 0
                for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let t = map.terrainAt(wx + dx, wy + dy)
                    if map.elevationAt(wx + dx, wy + dy) == 1 && t != .ramp { hx += dx; hy += dy }
                }
                g.setStrokeColor(rgb(0, 0, 0, 0.18).cgColor)
                g.setLineWidth(1.5)
                for k in -1...1 {
                    let o = CGFloat(k) * 8
                    if abs(hx) >= abs(hy) {
                        g.move(to: CGPoint(x: x + o, y: y - T * 0.5)); g.addLine(to: CGPoint(x: x + o, y: y + T * 0.5))
                    } else {
                        g.move(to: CGPoint(x: x - T * 0.5, y: y + o)); g.addLine(to: CGPoint(x: x + T * 0.5, y: y + o))
                    }
                }
                g.strokePath()
            }
            // water (or lava, or ice)
            each({ $0 == .water }) { x, y, _, _ in fill(g, circle(x, y, T * 0.98), pal.shore) }
            each({ $0 == .water }) { x, y, _, _ in fill(g, circle(x, y, T * 0.82), pal.shallow) }
            each({ $0 == .water }) { x, y, wx, wy in
                let deep = [(1, 0), (-1, 0), (0, 1), (0, -1)].allSatisfy { map.terrainAt(wx + $0.0, wy + $0.1) == .water }
                fill(g, circle(x, y, T * (deep ? 0.8 : 0.6)), deep ? pal.deep : pal.shallow)
            }
            each({ $0 == .water }) { x, y, wx, wy in
                if hash(wx, wy, seed + 31) > 0.5 {
                    let px = x + CGFloat(hash(wx, wy, seed + 32) - 0.5) * T * 0.7
                    let py = y + CGFloat(hash(wx, wy, seed + 33) - 0.5) * T * 0.7
                    if biome == .volcanic {
                        // cooled crust plates on the lava
                        fill(g, poly([(px - 6, py - 2), (px - 1, py - 5), (px + 6, py - 1), (px + 3, py + 4), (px - 4, py + 3)]), rgb(0.25, 0.1, 0.05, 0.75))
                    } else if biome == .snow {
                        g.setStrokeColor(rgb(1, 1, 1, 0.6).cgColor)
                        g.setLineWidth(0.8)
                        g.move(to: CGPoint(x: px - 7, y: py - 3)); g.addLine(to: CGPoint(x: px, y: py + 1)); g.addLine(to: CGPoint(x: px + 6, y: py - 4))
                        g.strokePath()
                    } else {
                        g.setStrokeColor(pal.glint.cgColor)
                        g.setLineWidth(1.2)
                        g.move(to: CGPoint(x: px - 4, y: py))
                        g.addQuadCurve(to: CGPoint(x: px + 4, y: py), control: CGPoint(x: px, y: py + 2))
                        g.strokePath()
                    }
                }
            }
            // cliffs and rocks: each mass is drawn as one continuous body (shared shadow, one outline, soft lighting),
            // cliffs lit on the high side and dark at the foot, rocks lit from the top-left
            struct Lump { var x: CGFloat; var y: CGFloat; var r: CGFloat; var lx: CGFloat; var ly: CGFloat; var wx: Int; var wy: Int }
            func mass(_ lumps: [Lump], _ col: (UIColor, UIColor, UIColor), shadow: CGFloat, cliff: Bool) {
                guard !lumps.isEmpty else { return }
                // one even shadow under the whole mass
                g.saveGState()
                g.setAlpha(0.34)
                g.beginTransparencyLayer(auxiliaryInfo: nil)
                g.setFillColor(UIColor.black.cgColor)
                for l in lumps {
                    let ox = cliff ? -l.lx * shadow : shadow * 0.6, oy = cliff ? -l.ly * shadow : -shadow
                    g.fillEllipse(in: CGRect(x: l.x + ox - l.r - 2, y: l.y + oy - l.r - 2, width: l.r * 2 + 4, height: l.r * 2 + 4))
                }
                g.endTransparencyLayer()
                g.restoreGState()
                // outline, then the body on top of it: the outline only shows around the outside
                g.setFillColor(shade(col.2, 0.55).cgColor)
                for l in lumps { g.fillEllipse(in: CGRect(x: l.x - l.r - 1.6, y: l.y - l.r - 1.6, width: l.r * 2 + 3.2, height: l.r * 2 + 3.2)) }
                g.setFillColor(col.1.cgColor)
                for l in lumps { g.fillEllipse(in: CGRect(x: l.x - l.r, y: l.y - l.r, width: l.r * 2, height: l.r * 2)) }
                // lighting and texture, clipped to the body
                g.saveGState()
                let union = CGMutablePath()
                for l in lumps { union.addEllipse(in: CGRect(x: l.x - l.r, y: l.y - l.r, width: l.r * 2, height: l.r * 2)) }
                g.addPath(union)
                g.clip()
                let space = CGColorSpaceCreateDeviceRGB()
                let darkG = CGGradient(colorsSpace: space, colors: [col.2.withAlphaComponent(0.95).cgColor, col.2.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1])!
                let lightG = CGGradient(colorsSpace: space, colors: [col.0.withAlphaComponent(0.95).cgColor, col.0.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1])!
                for l in lumps {
                    let c = CGPoint(x: l.x - l.lx * l.r * 0.7, y: l.y - l.ly * l.r * 0.7)
                    g.drawRadialGradient(darkG, startCenter: c, startRadius: 0, endCenter: c, endRadius: l.r * 1.15, options: [])
                }
                for l in lumps {
                    let c = CGPoint(x: l.x + l.lx * l.r * 0.6, y: l.y + l.ly * l.r * 0.6)
                    g.drawRadialGradient(lightG, startCenter: c, startRadius: 0, endCenter: c, endRadius: l.r * 0.95, options: [])
                }
                // facets, cracks and speckles
                for l in lumps {
                    let h1 = CGFloat(hash(l.wx, l.wy, seed + 91)), h2 = CGFloat(hash(l.wx, l.wy, seed + 92)), h3 = CGFloat(hash(l.wx, l.wy, seed + 93))
                    // a lit facet
                    let fx = l.x + (h1 - 0.5) * l.r, fy = l.y + (h2 - 0.5) * l.r
                    fill(g, poly([(fx - 5 - h3 * 3, fy - 1), (fx - 1, fy + 4 + h1 * 2), (fx + 5 + h2 * 3, fy + 1), (fx + 1, fy - 3)]),
                         col.0.withAlphaComponent(0.22))
                    // a crack running across the slope
                    g.setStrokeColor(col.2.withAlphaComponent(0.55).cgColor)
                    g.setLineWidth(0.9)
                    let px = -l.ly, py = l.lx
                    let cx = l.x + (h2 - 0.5) * l.r * 0.8, cy = l.y + (h3 - 0.5) * l.r * 0.8
                    g.move(to: CGPoint(x: cx - px * 7, y: cy - py * 7))
                    g.addLine(to: CGPoint(x: cx + l.lx * 2, y: cy + l.ly * 2))
                    g.addLine(to: CGPoint(x: cx + px * 6, y: cy + py * 6))
                    g.strokePath()
                    for k in 0..<3 {
                        let sx = l.x + CGFloat(hash(l.wx * 3 + k, l.wy, seed + 94) - 0.5) * l.r * 1.6
                        let sy = l.y + CGFloat(hash(l.wx, l.wy * 3 + k, seed + 95) - 0.5) * l.r * 1.6
                        fill(g, circle(sx, sy, 0.9), (k == 0 ? col.0 : col.2).withAlphaComponent(0.5))
                    }
                    if biome == .volcanic && cliff && h1 > 0.72 {
                        g.setStrokeColor(rgb(1, 0.45, 0.1, 0.8).cgColor)
                        g.setLineWidth(1.3)
                        g.move(to: CGPoint(x: l.x - 6, y: l.y + 1)); g.addLine(to: CGPoint(x: l.x, y: l.y - 3)); g.addLine(to: CGPoint(x: l.x + 5, y: l.y + 2))
                        g.strokePath()
                    }
                }
                g.restoreGState()
            }
            var cliffs: [Lump] = []
            each({ $0 == .cliff }) { x, y, wx, wy in
                var hx: CGFloat = 0, hy: CGFloat = 0
                for dy in -1...1 {
                    for dx in -1...1 where dx != 0 || dy != 0 {
                        if map.elevationAt(wx + dx, wy + dy) == 1 && map.terrainAt(wx + dx, wy + dy) != .cliff { hx += CGFloat(dx); hy += CGFloat(dy) }
                    }
                }
                let l = max(0.001, (hx * hx + hy * hy).squareRoot())
                let jx = CGFloat(hash(wx, wy, seed + 74) - 0.5) * 5, jy = CGFloat(hash(wx, wy, seed + 75) - 0.5) * 5
                cliffs.append(Lump(x: x + jx, y: y + jy, r: T * (0.66 + CGFloat(hash(wx, wy, seed + 71)) * 0.1), lx: hx / l, ly: hy / l, wx: wx, wy: wy))
            }
            mass(cliffs, pal.cliff, shadow: 9, cliff: true)
            var rocks: [Lump] = []
            each({ $0 == .rock }) { x, y, wx, wy in
                let jx = CGFloat(hash(wx, wy, seed + 42) - 0.5) * 7, jy = CGFloat(hash(wx, wy, seed + 44) - 0.5) * 7
                rocks.append(Lump(x: x + jx, y: y + jy, r: T * (0.62 + CGFloat(hash(wx, wy, seed + 41)) * 0.2), lx: -0.6, ly: 0.8, wx: wx, wy: wy))
            }
            mass(rocks, pal.rock, shadow: 7, cliff: false)
            // forests
            each({ $0 == .forest }) { x, y, wx, wy in
                for k in 0..<2 {
                    let px = x + CGFloat(hash(wx + k, wy, seed + 81) - 0.5) * T * 0.6
                    let py = y + CGFloat(hash(wx, wy + k, seed + 82) - 0.5) * T * 0.6
                    fill(g, circle(px + 6, py - 7, T * 0.5), rgb(0, 0, 0, 0.3))
                }
            }
            each({ $0 == .forest }) { x, y, wx, wy in
                for k in 0..<2 {
                    let px = x + CGFloat(hash(wx + k, wy, seed + 81) - 0.5) * T * 0.6
                    let py = y + CGFloat(hash(wx, wy + k, seed + 82) - 0.5) * T * 0.6
                    let r = T * (0.38 + CGFloat(hash(wx, wy + k * 3, seed + 83)) * 0.16)
                    drawTree(g, px, py, r, biome: biome, pal: pal, h: hash(wx * 5 + k, wy, seed + 84))
                }
            }
            // ground details
            each({ $0 == .grass }) { x, y, wx, wy in
                let h = hash(wx, wy, seed + 51)
                let px = x + CGFloat(hash(wx, wy, seed + 52) - 0.5) * T * 0.8
                let py = y + CGFloat(hash(wx, wy, seed + 53) - 0.5) * T * 0.8
                if h > 0.74 {
                    switch biome {
                    case .grass:
                        g.setStrokeColor(rgb(0.16, 0.32, 0.12, 0.8).cgColor)
                        g.setLineWidth(1)
                        for k in -1...1 {
                            g.move(to: CGPoint(x: px + CGFloat(k) * 1.5, y: py)); g.addLine(to: CGPoint(x: px + CGFloat(k) * 3, y: py + 4.5))
                        }
                        g.strokePath()
                    case .desert:
                        fill(g, circle(px, py, 1.4), rgb(0.6, 0.5, 0.35, 0.7))
                    case .snow:
                        fill(g, circle(px, py, 2), rgb(1, 1, 1, 0.5))
                    case .volcanic:
                        fill(g, circle(px, py, 1.2), rgb(1, 0.45, 0.1, 0.55))
                    }
                } else if h < 0.05 {
                    let flower: UIColor
                    switch biome {
                    case .grass: flower = hash(wx, wy, seed + 56) > 0.5 ? rgb(1, 0.92, 0.4) : rgb(0.95, 0.6, 0.85)
                    case .desert: flower = rgb(0.45, 0.6, 0.3)
                    case .snow: flower = rgb(0.55, 0.6, 0.65)
                    case .volcanic: flower = rgb(0.55, 0.3, 0.2)
                    }
                    for k in 0..<3 { fill(g, circle(px + CGFloat(k) * 2.5 - 2.5, py + CGFloat(k % 2) * 2, 1.2), flower) }
                } else if h < 0.09 {
                    fill(g, circle(px + 0.8, py - 0.8, 2.2), rgb(0, 0, 0, 0.2))
                    fill(g, circle(px, py, 2), pal.rock.0)
                }
            }
        }
        let t = SKTexture(image: img)
        t.filteringMode = .linear
        return t
    }

    private static func drawTree(_ g: CGContext, _ x: CGFloat, _ y: CGFloat, _ r: CGFloat, biome: Biome, pal: Palette, h: Double) {
        switch biome {
        case .grass:
            let p = circle(x, y, r)
            shaded(g, p, h > 0.5 ? pal.canopy.0 : pal.canopy.1, light: 1.5, dark: 0.6)
            fill(g, circle(x - r * 0.3, y + r * 0.3, r * 0.45), rgb(1, 1, 1, 0.08))
            fill(g, circle(x + r * 0.45, y - r * 0.2, r * 0.5), shade(pal.canopy.0, 0.8).withAlphaComponent(0.6))
        case .snow:
            // pine seen from above: a star of branches with snow
            let star = CGMutablePath()
            for k in 0..<16 {
                let a = CGFloat(k) / 16 * 2 * .pi
                let rr = k % 2 == 0 ? r : r * 0.55
                let pt = CGPoint(x: x + cos(a) * rr, y: y + sin(a) * rr)
                if k == 0 { star.move(to: pt) } else { star.addLine(to: pt) }
            }
            star.closeSubpath()
            shaded(g, star, pal.canopy.0, light: 1.6, dark: 0.6)
            fill(g, circle(x - r * 0.2, y + r * 0.2, r * 0.35), rgb(1, 1, 1, 0.75))
        case .desert:
            // palm: fronds from a center
            g.setStrokeColor(pal.canopy.0.cgColor)
            g.setLineWidth(3)
            g.setLineCap(.round)
            for k in 0..<7 {
                let a = CGFloat(k) / 7 * 2 * .pi + CGFloat(h)
                g.move(to: CGPoint(x: x, y: y))
                g.addQuadCurve(to: CGPoint(x: x + cos(a) * r * 1.1, y: y + sin(a) * r * 1.1),
                               control: CGPoint(x: x + cos(a + 0.3) * r * 0.7, y: y + sin(a + 0.3) * r * 0.7))
            }
            g.strokePath()
            fill(g, circle(x, y, 2.5), rgb(0.45, 0.3, 0.15))
        case .volcanic:
            // charred dead tree
            g.setStrokeColor(rgb(0.08, 0.06, 0.06).cgColor)
            g.setLineWidth(2.2)
            g.setLineCap(.round)
            for k in 0..<5 {
                let a = CGFloat(k) / 5 * 2 * .pi + CGFloat(h) * 3
                g.move(to: CGPoint(x: x, y: y))
                g.addLine(to: CGPoint(x: x + cos(a) * r, y: y + sin(a) * r))
            }
            g.strokePath()
            fill(g, circle(x, y, 3), rgb(0.12, 0.09, 0.08))
        }
    }

    /// One pixel per tile, for the minimap.
    static func minimap(_ map: GameMap) -> UIImage {
        let w = CGFloat(map.width), h = CGFloat(map.height)
        let pal = palette(map.id.biome)
        return image(w, h, scale: 2) { g in
            for y in 0..<map.height {
                for x in 0..<map.width {
                    var c: UIColor
                    switch map.terrainAt(x, y) {
                    case .grass: c = rgb(pal.ground.0, pal.ground.1, pal.ground.2)
                    case .dirt, .ramp: c = pal.dirt
                    case .rock: c = pal.rock.1
                    case .cliff: c = pal.cliff.2
                    case .water: c = pal.deep
                    case .forest: c = pal.canopy.0
                    }
                    if map.elevationAt(x, y) == 1 && map.terrainAt(x, y) != .ramp { c = shade(c, 1.15) }
                    g.setFillColor(c.cgColor)
                    g.fill(CGRect(x: CGFloat(x), y: h - 1 - CGFloat(y), width: 1, height: 1))
                }
            }
        }
    }
}
