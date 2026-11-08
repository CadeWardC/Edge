import SpriteKit
import UIKit

/// All of Vanguard's art, drawn in code at launch: units and buildings in every team color, terrain, crystals,
/// effects and HUD icons. Sprites are drawn facing +x in world units and rendered at `scale` pixels per unit.
enum Art {
    static let scale: CGFloat = 2.5
    private static var cache: [String: SKTexture] = [:]
    private static var imageCache: [String: UIImage] = [:]

    // MARK: helpers

    static func image(_ w: CGFloat, _ h: CGFloat, scale s: CGFloat = scale, _ draw: (CGContext) -> Void) -> UIImage {
        let f = UIGraphicsImageRendererFormat()
        f.scale = s
        f.opaque = false
        return UIGraphicsImageRenderer(size: CGSize(width: w, height: h), format: f).image { ctx in
            let g = ctx.cgContext
            g.setAllowsAntialiasing(true)
            g.setShouldAntialias(true)
            draw(g)
        }
    }

    private static func texture(_ key: String, _ make: () -> UIImage) -> SKTexture {
        if let t = cache[key] { return t }
        let t = SKTexture(image: make())
        t.filteringMode = .linear
        cache[key] = t
        return t
    }

    static func color(_ c: TeamColor) -> UIColor {
        let (r, g, b) = c.rgb
        return UIColor(red: r, green: g, blue: b, alpha: 1)
    }

    static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> UIColor {
        UIColor(red: r, green: g, blue: b, alpha: a)
    }

    static func shade(_ c: UIColor, _ k: CGFloat) -> UIColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getRed(&r, green: &g, blue: &b, alpha: &a)
        if k < 1 { return UIColor(red: r * k, green: g * k, blue: b * k, alpha: a) }
        let t = k - 1
        return UIColor(red: r + (1 - r) * t, green: g + (1 - g) * t, blue: b + (1 - b) * t, alpha: a)
    }

    private static func fill(_ g: CGContext, _ p: CGPath, _ c: UIColor) {
        g.addPath(p)
        g.setFillColor(c.cgColor)
        g.fillPath()
    }

    private static func stroke(_ g: CGContext, _ p: CGPath, _ c: UIColor, _ w: CGFloat) {
        g.addPath(p)
        g.setStrokeColor(c.cgColor)
        g.setLineWidth(w)
        g.setLineJoin(.round)
        g.setLineCap(.round)
        g.strokePath()
    }

    /// Fills a shape with a radial gradient lit from the top-left.
    private static func shaded(_ g: CGContext, _ p: CGPath, _ c: UIColor, light: CGFloat = 1.45, dark: CGFloat = 0.62) {
        let box = p.boundingBox
        g.saveGState()
        g.addPath(p)
        g.clip()
        let colors = [shade(c, light).cgColor, c.cgColor, shade(c, dark).cgColor] as CFArray
        let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.45, 1])!
        let start = CGPoint(x: box.minX + box.width * 0.3, y: box.minY + box.height * 0.28)
        let end = CGPoint(x: box.midX, y: box.midY)
        g.drawRadialGradient(grad, startCenter: start, startRadius: 0, endCenter: end,
                             endRadius: max(box.width, box.height) * 0.75, options: [.drawsAfterEndLocation])
        g.restoreGState()
    }

    private static func circle(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) -> CGPath {
        CGPath(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r), transform: nil)
    }

    private static func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat = 0) -> CGPath {
        CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerWidth: min(r, w / 2), cornerHeight: min(r, h / 2), transform: nil)
    }

    private static func poly(_ pts: [(CGFloat, CGFloat)]) -> CGPath {
        let p = CGMutablePath()
        guard let f = pts.first else { return p }
        p.move(to: CGPoint(x: f.0, y: f.1))
        for q in pts.dropFirst() { p.addLine(to: CGPoint(x: q.0, y: q.1)) }
        p.closeSubpath()
        return p
    }

    private static func octagon(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) -> CGPath {
        let k = r * 0.414
        return poly([(cx - k, cy - r), (cx + k, cy - r), (cx + r, cy - k), (cx + r, cy + k),
                     (cx + k, cy + r), (cx - k, cy + r), (cx - r, cy + k), (cx - r, cy - k)])
    }

    // palette
    static let steel = rgb(0.55, 0.58, 0.62)
    static let darkSteel = rgb(0.24, 0.26, 0.30)
    static let gunmetal = rgb(0.16, 0.17, 0.20)
    static let glass = rgb(0.45, 0.85, 1.0)
    static let hazard = rgb(1.0, 0.78, 0.15)
    static let concrete = rgb(0.62, 0.60, 0.55)

    // MARK: units (canvas centered on the unit, facing +x)

    static func unitSize(_ t: EntityType) -> CGFloat { CGFloat(t.stats.radius) * 2 + 12 }

    static func unit(_ t: EntityType, _ team: TeamColor) -> SKTexture {
        texture("u\(t.rawValue)-\(team.rawValue)") { unitImage(t, team) }
    }

    static func unitImage(_ t: EntityType, _ team: TeamColor, iconScale: CGFloat? = nil) -> UIImage {
        let s = unitSize(t)
        let c = color(team)
        return image(s, s, scale: iconScale ?? scale) { g in
            g.translateBy(x: s / 2, y: s / 2)
            switch t {
            case .worker: drawWorker(g, c)
            case .trooper: drawInfantry(g, c, kind: 0)
            case .lancer: drawInfantry(g, c, kind: 1)
            case .mender: drawInfantry(g, c, kind: 2)
            case .skimmer: drawSkimmer(g, c)
            case .tank: drawTankHull(g, c)
            case .gunship: drawGunship(g, c)
            default: break
            }
        }
    }

    private static func drawWorker(_ g: CGContext, _ c: UIColor) {
        for side: CGFloat in [-1, 1] {
            shaded(g, rect(-6, side * 7 - 2.2, 9, 4.4, 2), steel)
            fill(g, circle(-5.5, side * 7, 1.3), rgb(0.4, 0.95, 1, 0.9))
        }
        fill(g, rect(5, -3.6, 5.5, 2.2, 1), hazard)
        fill(g, rect(5, 1.4, 5.5, 2.2, 1), hazard)
        let body = circle(0, 0, 7)
        shaded(g, body, c)
        stroke(g, body, shade(c, 0.45), 1.1)
        fill(g, circle(-1, 0, 3.6), shade(c, 0.7))
        fill(g, circle(2.4, 0, 2), glass)
        fill(g, circle(2.9, -0.6, 0.7), .white)
    }

    private static func drawInfantry(_ g: CGContext, _ c: UIColor, kind: Int) {
        // gear on the back
        let pack = kind == 2 ? rgb(0.92, 0.94, 0.95) : shade(c, 0.5)
        shaded(g, rect(-8, -4.5, 5, 9, 2), pack)
        if kind == 1 {
            // rocket tube over the right shoulder
            shaded(g, rect(-9, 2.2, 22, 4.6, 2), rgb(0.42, 0.45, 0.30))
            fill(g, rect(11, 2.2, 3, 4.6, 1), rgb(0.95, 0.35, 0.15))
            fill(g, rect(-9.5, 2.6, 2, 3.8, 0.8), gunmetal)
        } else if kind == 0 {
            fill(g, rect(1, 1.2, 12, 2.4, 0.8), gunmetal)
            fill(g, rect(9, 1.5, 4.5, 1.8, 0.6), darkSteel)
        } else {
            fill(g, circle(8, -4, 2.8), rgb(0.4, 1, 0.5, 0.35))
            fill(g, circle(8, -4, 1.6), rgb(0.6, 1, 0.65))
        }
        // shoulders
        let shoulders = CGPath(ellipseIn: CGRect(x: -5, y: -8, width: 10, height: 16), transform: nil)
        shaded(g, shoulders, kind == 2 ? rgb(0.95, 0.96, 0.97) : c)
        stroke(g, shoulders, shade(c, 0.4), 0.9)
        if kind == 2 {
            fill(g, rect(-1.2, -7, 2.4, 14), c)
        }
        // arms forward
        fill(g, rect(1, -6.5, 6, 3, 1.5), shade(kind == 2 ? rgb(0.9, 0.9, 0.9) : c, 0.8))
        fill(g, rect(1, 3.5, 5, 3, 1.5), shade(kind == 2 ? rgb(0.9, 0.9, 0.9) : c, 0.8))
        // helmet
        let helmet = circle(0.5, 0, 4.6)
        shaded(g, helmet, kind == 2 ? rgb(0.96, 0.97, 0.98) : shade(c, 0.62))
        stroke(g, helmet, rgb(0, 0, 0, 0.35), 0.7)
        if kind == 2 {
            fill(g, rect(-0.6, -2.8, 2.2, 5.6), rgb(0.2, 0.8, 0.35))
            fill(g, rect(-2.3, -1.1, 5.6, 2.2), rgb(0.2, 0.8, 0.35))
        } else {
            fill(g, rect(2.5, -2.4, 2, 4.8, 1), rgb(0.4, 0.9, 1, 0.85))
        }
    }

    private static func drawSkimmer(_ g: CGContext, _ c: UIColor) {
        // engine glow
        fill(g, circle(-11, -4, 3.2), rgb(1, 0.55, 0.15, 0.5))
        fill(g, circle(-11, 4, 3.2), rgb(1, 0.55, 0.15, 0.5))
        fill(g, circle(-10.5, -4, 1.7), rgb(1, 0.9, 0.5))
        fill(g, circle(-10.5, 4, 1.7), rgb(1, 0.9, 0.5))
        // side fins
        shaded(g, poly([(-6, -6), (2, -11), (5, -10), (-1, -4)]), darkSteel)
        shaded(g, poly([(-6, 6), (2, 11), (5, 10), (-1, 4)]), darkSteel)
        let body = poly([(15, 0), (4, -6), (-10, -7), (-7, 0), (-10, 7), (4, 6)])
        shaded(g, body, c)
        stroke(g, body, shade(c, 0.4), 1)
        fill(g, poly([(13, 0), (4, -2.2), (-6, -1.5), (-6, 1.5), (4, 2.2)]), shade(c, 1.35))
        let cockpit = CGPath(ellipseIn: CGRect(x: -1, y: -2.8, width: 8, height: 5.6), transform: nil)
        shaded(g, cockpit, rgb(0.2, 0.45, 0.75), light: 1.9)
        fill(g, circle(4, -1, 0.9), rgb(1, 1, 1, 0.8))
    }

    private static func drawTankHull(_ g: CGContext, _ c: UIColor) {
        // treads
        for side: CGFloat in [-1, 1] {
            let y = side > 0 ? 8.5 : -14.5
            shaded(g, rect(-16, y, 32, 6, 2.5), gunmetal, light: 1.6)
            g.setStrokeColor(rgb(0, 0, 0, 0.45).cgColor)
            g.setLineWidth(0.8)
            var x: CGFloat = -14
            while x < 15 {
                g.move(to: CGPoint(x: x, y: y + 0.6))
                g.addLine(to: CGPoint(x: x, y: y + 5.4))
                x += 3
            }
            g.strokePath()
        }
        let hull = rect(-14.5, -9.5, 29, 19, 3.5)
        shaded(g, hull, shade(c, 0.85))
        stroke(g, hull, shade(c, 0.35), 1.1)
        // front glacis and engine deck
        fill(g, poly([(10, -8), (14, -6), (14, 6), (10, 8)]), shade(c, 1.25))
        fill(g, rect(-13, -5, 5, 10, 1), shade(c, 0.55))
        g.setStrokeColor(rgb(0, 0, 0, 0.35).cgColor)
        g.setLineWidth(0.7)
        for i in 0..<3 {
            let y = CGFloat(-3.5 + Double(i) * 3.5)
            g.move(to: CGPoint(x: -12.5, y: y))
            g.addLine(to: CGPoint(x: -8.5, y: y))
        }
        g.strokePath()
    }

    static func tankTurret(_ team: TeamColor) -> SKTexture {
        texture("tt-\(team.rawValue)") {
            let s: CGFloat = 56
            let c = color(team)
            return image(s, s) { g in
                g.translateBy(x: s / 2, y: s / 2)
                shaded(g, rect(4, -2.2, 22, 4.4, 1.5), darkSteel, light: 1.7)
                fill(g, rect(23, -3, 4, 6, 1), gunmetal)
                let tur = octagon(0, 0, 8)
                shaded(g, tur, c)
                stroke(g, tur, shade(c, 0.35), 1)
                fill(g, circle(-2, -2.5, 2.2), shade(c, 0.6))
                fill(g, circle(-2, -2.5, 1.1), glass)
            }
        }
    }

    private static func drawGunship(_ g: CGContext, _ c: UIColor) {
        // wings with engine pods
        let wing = poly([(4, -3), (8, -3), (2, -19), (-3, -19), (-6, -3)])
        let wing2 = poly([(4, 3), (8, 3), (2, 19), (-3, 19), (-6, 3)])
        shaded(g, wing, shade(c, 0.75))
        shaded(g, wing2, shade(c, 0.75))
        stroke(g, wing, shade(c, 0.35), 0.8)
        stroke(g, wing2, shade(c, 0.35), 0.8)
        for side: CGFloat in [-1, 1] {
            shaded(g, rect(-6, side * 18 - 3, 12, 6, 3), steel)
            fill(g, circle(-6.5, side * 18, 2.6), rgb(0.4, 0.9, 1, 0.55))
            fill(g, circle(-6.5, side * 18, 1.4), rgb(0.85, 1, 1))
            // cannons
            fill(g, rect(5, side * 18 - 0.8, 6, 1.6, 0.6), gunmetal)
        }
        // tail
        shaded(g, poly([(-14, 0), (-20, -7), (-17, -7), (-11, -2)]), shade(c, 0.7))
        shaded(g, poly([(-14, 0), (-20, 7), (-17, 7), (-11, 2)]), shade(c, 0.7))
        let body = CGPath(ellipseIn: CGRect(x: -17, y: -5, width: 35, height: 10), transform: nil)
        shaded(g, body, c)
        stroke(g, body, shade(c, 0.35), 1)
        let cockpit = CGPath(ellipseIn: CGRect(x: 7, y: -3, width: 9, height: 6), transform: nil)
        shaded(g, cockpit, rgb(0.15, 0.4, 0.7), light: 2)
        fill(g, circle(12.5, -1.2, 1), rgb(1, 1, 1, 0.8))
    }

    // MARK: buildings

    static func buildingSize(_ t: EntityType) -> CGFloat { CGFloat(t.stats.footprint) * CGFloat(Defs.tile) + 10 }

    static func building(_ t: EntityType, _ team: TeamColor) -> SKTexture {
        texture("b\(t.rawValue)-\(team.rawValue)") { buildingImage(t, team) }
    }

    static func buildingImage(_ t: EntityType, _ team: TeamColor, iconScale: CGFloat? = nil) -> UIImage {
        let s = buildingSize(t)
        let c = color(team)
        return image(s, s, scale: iconScale ?? scale) { g in
            g.translateBy(x: s / 2, y: s / 2)
            let h = CGFloat(t.stats.footprint) * CGFloat(Defs.tile) / 2
            // drop shadow and foundation
            fill(g, rect(-h + 3, -h + 4, 2 * h, 2 * h, 6), rgb(0, 0, 0, 0.28))
            switch t {
            case .hq: drawHQ(g, c, h)
            case .depot: drawDepot(g, c, h)
            case .barracks: drawBarracks(g, c, h)
            case .factory: drawFactory(g, c, h)
            case .lab: drawLab(g, c, h)
            case .turret: drawTurretBase(g, c, h)
            default: break
            }
        }
    }

    private static func plate(_ g: CGContext, _ h: CGFloat, _ c: UIColor) {
        let base = rect(-h + 1, -h + 1, 2 * h - 2, 2 * h - 2, 5)
        shaded(g, base, concrete, light: 1.2, dark: 0.75)
        stroke(g, base, rgb(0.25, 0.25, 0.25, 0.8), 1.2)
        // team trim
        stroke(g, rect(-h + 3.5, -h + 3.5, 2 * h - 7, 2 * h - 7, 3), shade(c, 0.9), 1.6)
    }

    private static func drawHQ(_ g: CGContext, _ c: UIColor, _ h: CGFloat) {
        plate(g, h, c)
        let oct = octagon(0, 0, h - 7)
        shaded(g, oct, steel, light: 1.25)
        stroke(g, oct, darkSteel, 1.2)
        // landing pad stripes
        g.setStrokeColor(hazard.withAlphaComponent(0.9).cgColor)
        g.setLineWidth(2)
        for k: CGFloat in [-1, 1] {
            g.move(to: CGPoint(x: -h + 12, y: k * (h - 13)))
            g.addLine(to: CGPoint(x: -h + 22, y: k * (h - 13)))
            g.move(to: CGPoint(x: h - 22, y: k * (h - 13)))
            g.addLine(to: CGPoint(x: h - 12, y: k * (h - 13)))
        }
        g.strokePath()
        // corner pylons
        for (x, y) in [(-1, -1), (1, -1), (1, 1), (-1, 1)] as [(CGFloat, CGFloat)] {
            let p = circle(x * (h - 11), y * (h - 11), 5)
            shaded(g, p, shade(c, 0.8))
            fill(g, circle(x * (h - 11), y * (h - 11), 1.8), rgb(0.6, 1, 1))
        }
        // central dome
        fill(g, circle(1.5, 2.5, 22), rgb(0, 0, 0, 0.25))
        let dome = circle(0, 0, 21)
        shaded(g, dome, c, light: 1.6, dark: 0.5)
        stroke(g, dome, shade(c, 0.35), 1.4)
        stroke(g, circle(0, 0, 14), shade(c, 1.3).withAlphaComponent(0.6), 1)
        fill(g, circle(-6, -6, 4), rgb(1, 1, 1, 0.35))
        // antenna
        fill(g, rect(14, -24, 3, 12, 1), darkSteel)
        fill(g, circle(15.5, -25, 2.2), rgb(1, 0.3, 0.25))
    }

    private static func drawDepot(_ g: CGContext, _ c: UIColor, _ h: CGFloat) {
        plate(g, h, c)
        // energy cells
        for (x, y) in [(-10, -10), (10, -10), (-10, 10), (10, 10)] as [(CGFloat, CGFloat)] {
            let cell = circle(x, y, 9)
            shaded(g, cell, steel, light: 1.4)
            stroke(g, cell, darkSteel, 1)
            fill(g, circle(x, y, 5.5), shade(c, 0.95))
            fill(g, circle(x - 1.5, y - 1.5, 2), rgb(1, 1, 1, 0.45))
        }
        // glowing bus bars
        g.setStrokeColor(rgb(1, 0.85, 0.3, 0.95).cgColor)
        g.setLineWidth(2)
        g.move(to: CGPoint(x: -10, y: 0)); g.addLine(to: CGPoint(x: 10, y: 0))
        g.move(to: CGPoint(x: 0, y: -10)); g.addLine(to: CGPoint(x: 0, y: 10))
        g.strokePath()
        fill(g, circle(0, 0, 3.5), rgb(1, 0.95, 0.6))
    }

    private static func drawBarracks(_ g: CGContext, _ c: UIColor, _ h: CGFloat) {
        plate(g, h, c)
        let roof = rect(-h + 8, -h + 10, 2 * h - 16, 2 * h - 24, 4)
        shaded(g, roof, rgb(0.33, 0.37, 0.36), light: 1.3)
        stroke(g, roof, gunmetal, 1.2)
        // roof ridges
        g.setStrokeColor(rgb(0, 0, 0, 0.3).cgColor)
        g.setLineWidth(1)
        var y = -h + 16
        while y < h - 18 {
            g.move(to: CGPoint(x: -h + 12, y: y))
            g.addLine(to: CGPoint(x: h - 12, y: y))
            y += 6
        }
        g.strokePath()
        // team band and chevrons
        fill(g, rect(-h + 8, -4, 2 * h - 16, 8), shade(c, 0.9))
        for i in 0..<3 {
            let x = CGFloat(-12 + i * 10)
            fill(g, poly([(x, -3), (x + 6, 0), (x, 3), (x + 2, 0)]), rgb(1, 1, 1, 0.85))
        }
        // door
        shaded(g, rect(-12, h - 16, 24, 9, 2), darkSteel)
        fill(g, rect(-10, h - 14, 20, 2, 1), hazard)
        // vents
        for x: CGFloat in [-h + 14, h - 22] {
            shaded(g, rect(x, -h + 13, 8, 8, 2), steel)
        }
    }

    private static func drawFactory(_ g: CGContext, _ c: UIColor, _ h: CGFloat) {
        plate(g, h, c)
        let hall = rect(-h + 7, -h + 7, 2 * h - 14, 2 * h - 14, 5)
        shaded(g, hall, rgb(0.46, 0.47, 0.50), light: 1.25)
        stroke(g, hall, gunmetal, 1.2)
        // diagonal skylights
        g.saveGState()
        g.addPath(rect(-h + 10, -h + 10, h - 6, 2 * h - 20, 3))
        g.clip()
        g.setStrokeColor(rgb(0.55, 0.85, 1, 0.55).cgColor)
        g.setLineWidth(3)
        var x = -h - 20
        while x < h {
            g.move(to: CGPoint(x: x, y: -h))
            g.addLine(to: CGPoint(x: x + 30, y: h))
            x += 9
        }
        g.strokePath()
        g.restoreGState()
        // gear emblem
        let gx = h * 0.42, gy: CGFloat = 0
        let gear = CGMutablePath()
        for i in 0..<8 {
            let a = CGFloat(i) * .pi / 4
            gear.addRect(CGRect(x: -2.5, y: -13, width: 5, height: 6), transform: CGAffineTransform(translationX: gx, y: gy).rotated(by: a))
        }
        fill(g, gear, shade(c, 0.9))
        let disc = circle(gx, gy, 9.5)
        shaded(g, disc, c)
        fill(g, circle(gx, gy, 3.5), rgb(0.3, 0.3, 0.33))
        // smokestacks
        for (sx, sy) in [(-h + 18, h - 18), (-h + 30, h - 18)] as [(CGFloat, CGFloat)] {
            fill(g, circle(sx + 1.5, sy + 2, 6), rgb(0, 0, 0, 0.3))
            shaded(g, circle(sx, sy, 5.5), darkSteel, light: 1.8)
            fill(g, circle(sx, sy, 3), rgb(0.08, 0.08, 0.08))
        }
        // loading door
        fill(g, rect(h - 10, -14, 4, 28, 1), hazard)
    }

    private static func drawLab(_ g: CGContext, _ c: UIColor, _ h: CGFloat) {
        plate(g, h, c)
        let ring = circle(0, 0, h - 6)
        shaded(g, ring, steel, light: 1.3)
        stroke(g, ring, shade(c, 0.95), 2.4)
        let dome = circle(0, 0, h - 12)
        shaded(g, dome, rgb(0.35, 0.75, 0.95), light: 1.8, dark: 0.45)
        stroke(g, dome, rgb(0.2, 0.4, 0.55), 1)
        // dome segments
        g.setStrokeColor(rgb(1, 1, 1, 0.35).cgColor)
        g.setLineWidth(0.8)
        g.move(to: CGPoint(x: -(h - 12), y: 0)); g.addLine(to: CGPoint(x: h - 12, y: 0))
        g.move(to: CGPoint(x: 0, y: -(h - 12))); g.addLine(to: CGPoint(x: 0, y: h - 12))
        g.strokePath()
        fill(g, circle(-5, -6, 4), rgb(1, 1, 1, 0.5))
        // dish
        fill(g, circle(h - 8, -(h - 8), 6.5), rgb(0, 0, 0, 0.25))
        shaded(g, circle(h - 9, -(h - 9), 6), rgb(0.85, 0.87, 0.9), light: 1.2)
        fill(g, circle(h - 9, -(h - 9), 1.5), c)
    }

    private static func drawTurretBase(_ g: CGContext, _ c: UIColor, _ h: CGFloat) {
        let base = octagon(0, 0, h - 2)
        shaded(g, base, concrete, light: 1.2, dark: 0.7)
        stroke(g, base, gunmetal, 1.2)
        stroke(g, octagon(0, 0, h - 6), shade(c, 0.9), 2)
        for (x, y) in [(-1, -1), (1, -1), (1, 1), (-1, 1)] as [(CGFloat, CGFloat)] {
            fill(g, circle(x * (h - 10), y * (h - 10), 2.2), darkSteel)
        }
    }

    static func turretGun(_ team: TeamColor) -> SKTexture {
        texture("tg-\(team.rawValue)") {
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

    /// Scaffolding drawn over a building while it is being built.
    static func scaffold(_ size: Int) -> SKTexture {
        texture("sc\(size)") {
            let h = CGFloat(size) * CGFloat(Defs.tile) / 2
            let s = 2 * h + 10
            return image(s, s) { g in
                g.translateBy(x: s / 2, y: s / 2)
                g.setStrokeColor(rgb(0.85, 0.7, 0.3, 0.9).cgColor)
                g.setLineWidth(1.2)
                var x = -h + 4
                while x <= h - 4 {
                    g.move(to: CGPoint(x: x, y: -h + 4)); g.addLine(to: CGPoint(x: x, y: h - 4))
                    g.move(to: CGPoint(x: -h + 4, y: x)); g.addLine(to: CGPoint(x: h - 4, y: x))
                    x += 10
                }
                g.strokePath()
                // hazard border
                g.saveGState()
                let outer = CGMutablePath()
                outer.addRect(CGRect(x: -h, y: -h, width: 2 * h, height: 2 * h))
                outer.addRect(CGRect(x: -h + 4, y: -h + 4, width: 2 * h - 8, height: 2 * h - 8))
                g.addPath(outer)
                g.clip(using: .evenOdd)
                fill(g, rect(-h, -h, 2 * h, 2 * h), hazard)
                g.setStrokeColor(rgb(0.1, 0.1, 0.1).cgColor)
                g.setLineWidth(3)
                var d = -4 * h
                while d < 4 * h {
                    g.move(to: CGPoint(x: d, y: -h)); g.addLine(to: CGPoint(x: d + 2 * h, y: h))
                    d += 8
                }
                g.strokePath()
                g.restoreGState()
            }
        }
    }

    // MARK: neutral objects

    static func crystal(_ variant: Int) -> SKTexture {
        texture("cr\(variant % 4)") { crystalImage(variant, scale: scale) }
    }

    static func crystalImage(_ variant: Int, scale sc: CGFloat) -> UIImage {
        do {
            let s: CGFloat = 40
            return image(s, s, scale: sc) { g in
                g.translateBy(x: s / 2, y: s / 2)
                var r = Rng(seed: UInt64(variant % 4) * 977 + 5)
                fill(g, CGPath(ellipseIn: CGRect(x: -14, y: -7, width: 30, height: 18), transform: nil), rgb(0, 0, 0, 0.25))
                fill(g, circle(0, 2, 13), rgb(0.3, 0.9, 1, 0.12))
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
                    shaded(g, p, rgb(0.25, 0.85, 0.95), light: 1.9, dark: 0.45)
                    stroke(g, p, rgb(0.75, 1, 1, 0.9), 0.7)
                    g.setStrokeColor(rgb(1, 1, 1, 0.7).cgColor)
                    g.setLineWidth(0.8)
                    g.move(to: CGPoint(x: x + lean * 0.5, y: y - len))
                    g.addLine(to: CGPoint(x: x - w * 0.3, y: y + 2))
                    g.strokePath()
                }
            }
        }
    }

    static func beaconPad() -> SKTexture {
        texture("beaconpad") {
            let s: CGFloat = 76
            return image(s, s) { g in
                g.translateBy(x: s / 2, y: s / 2)
                fill(g, circle(2, 3, 32), rgb(0, 0, 0, 0.25))
                let pad = circle(0, 0, 31)
                shaded(g, pad, rgb(0.55, 0.55, 0.58), light: 1.2, dark: 0.7)
                stroke(g, pad, gunmetal, 1.5)
                for i in 0..<8 {
                    let a = CGFloat(i) * .pi / 4
                    let p = CGMutablePath()
                    p.addArc(center: .zero, radius: 25, startAngle: a + 0.12, endAngle: a + .pi / 4 - 0.12, clockwise: false)
                    stroke(g, p, rgb(0.25, 0.25, 0.28), 4)
                }
                shaded(g, octagon(0, 0, 11), darkSteel, light: 1.6)
            }
        }
    }

    /// White core, tinted with the owner's color by the renderer.
    static func beaconCore() -> SKTexture {
        texture("beaconcore") {
            let s: CGFloat = 40
            return image(s, s) { g in
                g.translateBy(x: s / 2, y: s / 2)
                fill(g, circle(0, 0, 14), rgb(1, 1, 1, 0.18))
                fill(g, circle(0, 0, 9), rgb(1, 1, 1, 0.35))
                shaded(g, poly([(0, -8), (6, 0), (0, 8), (-6, 0)]), .white, light: 1, dark: 0.7)
            }
        }
    }

    static func beaconRing() -> SKTexture {
        texture("beaconring") {
            let s = CGFloat(Defs.beaconRadius) * 2 + 8
            return image(s, s, scale: 1.5) { g in
                g.translateBy(x: s / 2, y: s / 2)
                let r = CGFloat(Defs.beaconRadius)
                g.setLineDash(phase: 0, lengths: [10, 8])
                stroke(g, circle(0, 0, r), rgb(1, 1, 1, 0.55), 2)
            }
        }
    }

    // MARK: effects and UI sprites

    static func glow() -> SKTexture {
        texture("glow") {
            image(32, 32, scale: 2) { g in
                let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                      colors: [rgb(1, 1, 1, 1).cgColor, rgb(1, 1, 1, 0.35).cgColor, rgb(1, 1, 1, 0).cgColor] as CFArray,
                                      locations: [0, 0.35, 1])!
                g.drawRadialGradient(grad, startCenter: CGPoint(x: 16, y: 16), startRadius: 0,
                                     endCenter: CGPoint(x: 16, y: 16), endRadius: 16, options: [])
            }
        }
    }

    static func smoke() -> SKTexture {
        texture("smoke") {
            image(32, 32, scale: 2) { g in
                var r = Rng(seed: 99)
                for _ in 0..<7 {
                    let x = CGFloat(r.range(10, 22)), y = CGFloat(r.range(10, 22)), rad = CGFloat(r.range(5, 9))
                    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                          colors: [rgb(1, 1, 1, 0.5).cgColor, rgb(1, 1, 1, 0).cgColor] as CFArray, locations: [0, 1])!
                    g.drawRadialGradient(grad, startCenter: CGPoint(x: x, y: y), startRadius: 0,
                                         endCenter: CGPoint(x: x, y: y), endRadius: rad, options: [])
                }
            }
        }
    }

    static func scorch() -> SKTexture {
        texture("scorch") {
            image(48, 48, scale: 1.5) { g in
                var r = Rng(seed: 7)
                for _ in 0..<9 {
                    let x = CGFloat(r.range(14, 34)), y = CGFloat(r.range(14, 34)), rad = CGFloat(r.range(6, 14))
                    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                          colors: [rgb(0.08, 0.06, 0.04, 0.45).cgColor, rgb(0.08, 0.06, 0.04, 0).cgColor] as CFArray, locations: [0, 1])!
                    g.drawRadialGradient(grad, startCenter: CGPoint(x: x, y: y), startRadius: 0,
                                         endCenter: CGPoint(x: x, y: y), endRadius: rad, options: [])
                }
            }
        }
    }

    static func shadow() -> SKTexture {
        texture("shadow") {
            image(32, 32, scale: 2) { g in
                let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                      colors: [rgb(0, 0, 0, 0.45).cgColor, rgb(0, 0, 0, 0).cgColor] as CFArray, locations: [0.4, 1])!
                g.drawRadialGradient(grad, startCenter: CGPoint(x: 16, y: 16), startRadius: 0,
                                     endCenter: CGPoint(x: 16, y: 16), endRadius: 16, options: [])
            }
        }
    }

    static func ring() -> SKTexture {
        texture("ring") {
            image(64, 64, scale: 2) { g in
                stroke(g, circle(32, 32, 28), .white, 3.5)
            }
        }
    }

    static func bar() -> SKTexture {
        texture("bar") { image(4, 4, scale: 2) { g in fill(g, rect(0, 0, 4, 4), .white) } }
    }

    static func tracer() -> SKTexture {
        texture("tracer") {
            image(32, 4, scale: 2) { g in
                let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                      colors: [rgb(1, 1, 1, 0).cgColor, rgb(1, 1, 1, 1).cgColor] as CFArray, locations: [0, 1])!
                g.saveGState()
                g.addPath(rect(0, 0.8, 32, 2.4, 1.2))
                g.clip()
                g.drawLinearGradient(grad, start: CGPoint(x: 0, y: 2), end: CGPoint(x: 32, y: 2), options: [])
                g.restoreGState()
            }
        }
    }

    static func rocket() -> SKTexture {
        texture("rocket") {
            image(16, 8, scale: 3) { g in
                fill(g, rect(2, 2.5, 10, 3, 1.5), rgb(0.85, 0.85, 0.8))
                fill(g, poly([(12, 2.5), (15, 4), (12, 5.5)]), rgb(0.9, 0.25, 0.15))
                fill(g, circle(2, 4, 2), rgb(1, 0.7, 0.2))
            }
        }
    }

    static func moveMarker() -> SKTexture {
        texture("marker") {
            image(40, 40, scale: 2) { g in
                stroke(g, circle(20, 20, 14), .white, 2.5)
                g.setStrokeColor(UIColor.white.cgColor)
                g.setLineWidth(2.5)
                for (x, y) in [(20, 2), (20, 38), (2, 20), (38, 20)] as [(CGFloat, CGFloat)] {
                    g.move(to: CGPoint(x: x, y: y))
                    g.addLine(to: CGPoint(x: 20 + (x - 20) * 0.55, y: 20 + (y - 20) * 0.55))
                }
                g.strokePath()
            }
        }
    }

    // MARK: HUD icons

    static func icon(_ t: EntityType, _ team: TeamColor) -> UIImage {
        let key = "i\(t.rawValue)-\(team.rawValue)"
        if let i = imageCache[key] { return i }
        let img: UIImage
        if t.isBuilding {
            let b = buildingImage(t, team, iconScale: 1)
            if t == .turret {
                img = composite(b, turretGunImage(team), size: buildingSize(t))
            } else {
                img = b
            }
        } else if t == .tank {
            img = composite(unitImage(t, team, iconScale: 2), tankTurretImage(team), size: unitSize(t))
        } else if t == .crystal {
            img = crystalImage(0, scale: 2)
        } else {
            img = unitImage(t, team, iconScale: 2)
        }
        // icons face up-right for a bit of life
        let rotated = rotatedIcon(img, t.isUnit ? -.pi / 4 : 0)
        imageCache[key] = rotated
        return rotated
    }

    private static func tankTurretImage(_ team: TeamColor) -> UIImage {
        let s: CGFloat = 56
        let c = color(team)
        return image(s, s, scale: 2) { g in
            g.translateBy(x: s / 2, y: s / 2)
            shaded(g, rect(4, -2.2, 22, 4.4, 1.5), darkSteel, light: 1.7)
            let tur = octagon(0, 0, 8)
            shaded(g, tur, c)
            stroke(g, tur, shade(c, 0.35), 1)
        }
    }

    private static func turretGunImage(_ team: TeamColor) -> UIImage {
        let s: CGFloat = 64
        let c = color(team)
        return image(s, s, scale: 1) { g in
            g.translateBy(x: s / 2, y: s / 2)
            for y: CGFloat in [-4.5, 2] { shaded(g, rect(6, y, 22, 2.8, 1), darkSteel, light: 1.7) }
            let head = rect(-11, -11, 22, 22, 6)
            shaded(g, head, c)
        }
    }

    private static func composite(_ a: UIImage, _ b: UIImage, size: CGFloat) -> UIImage {
        image(size, size, scale: 2) { _ in
            a.draw(in: CGRect(x: 0, y: 0, width: size, height: size))
            let bs = b.size
            b.draw(in: CGRect(x: (size - bs.width) / 2, y: (size - bs.height) / 2, width: bs.width, height: bs.height))
        }
    }

    private static func rotatedIcon(_ img: UIImage, _ angle: CGFloat) -> UIImage {
        guard angle != 0 else { return img }
        let s = max(img.size.width, img.size.height)
        return image(s, s, scale: 2) { g in
            g.translateBy(x: s / 2, y: s / 2)
            g.rotate(by: angle)
            img.draw(in: CGRect(x: -img.size.width / 2, y: -img.size.height / 2, width: img.size.width, height: img.size.height))
        }
    }

    static func upgradeIcon(_ u: Upgrade) -> UIImage {
        let key = "up\(u.rawValue)"
        if let i = imageCache[key] { return i }
        let img = image(40, 40, scale: 2) { g in
            let bg = rect(2, 2, 36, 36, 8)
            shaded(g, bg, rgb(0.2, 0.25, 0.35), light: 1.5)
            stroke(g, bg, rgb(0.5, 0.8, 1, 0.8), 1.5)
            let level = (u == .weapons2 || u == .plating2) ? 2 : 1
            switch u {
            case .weapons1, .weapons2:
                g.translateBy(x: 20, y: 20)
                g.rotate(by: -.pi / 4)
                fill(g, rect(-12, -2, 20, 4, 1), rgb(0.85, 0.85, 0.9))
                fill(g, poly([(8, -4), (14, 0), (8, 4)]), rgb(1, 0.4, 0.3))
                fill(g, rect(-14, -4, 4, 8, 1), rgb(0.5, 0.5, 0.55))
                g.rotate(by: .pi / 4)
                g.translateBy(x: -20, y: -20)
            case .plating1, .plating2:
                let shield = poly([(20, 7), (31, 11), (29, 24), (20, 33), (11, 24), (9, 11)])
                shaded(g, shield, rgb(0.6, 0.7, 0.85), light: 1.6)
                stroke(g, shield, .white, 1.2)
            case .siegeMode:
                fill(g, rect(9, 22, 22, 9, 3), rgb(0.5, 0.55, 0.45))
                fill(g, rect(18, 10, 4, 14, 1), rgb(0.3, 0.3, 0.32))
                fill(g, rect(6, 30, 6, 4, 1), hazard)
                fill(g, rect(28, 30, 6, 4, 1), hazard)
            case .sprint:
                for k in 0..<3 {
                    let x = CGFloat(8 + k * 8)
                    fill(g, poly([(x, 10), (x + 9, 20), (x, 30), (x + 4, 20)]), k == 2 ? hazard : rgb(1, 1, 1, 0.5 + 0.2 * CGFloat(k)))
                }
            }
            if level == 2 || u == .weapons1 || u == .plating1 {
                for i in 0..<level { fill(g, circle(CGFloat(30 - i * 6), 32, 2.2), hazard) }
            }
        }
        imageCache[key] = img
        return img
    }

    // MARK: terrain

    private static func hash(_ x: Int, _ y: Int, _ s: UInt64) -> Double {
        var h = UInt64(bitPattern: Int64(x)) &* 0x9E37_79B1_85EB_CA87 ^ UInt64(bitPattern: Int64(y)) &* 0xC2B2_AE3D_27D4_EB4F ^ s
        h ^= h >> 29
        h = h &* 0xBF58_476D_1CE4_E5B9
        h ^= h >> 32
        return Double(h & 0xFFFFFF) / Double(0xFFFFFF)
    }

    private static func noise(_ x: Double, _ y: Double, _ s: UInt64) -> Double {
        let x0 = Int(floor(x)), y0 = Int(floor(y))
        let fx = x - Double(x0), fy = y - Double(y0)
        let sx = fx * fx * (3 - 2 * fx), sy = fy * fy * (3 - 2 * fy)
        let a = hash(x0, y0, s), b = hash(x0 + 1, y0, s), c = hash(x0, y0 + 1, s), d = hash(x0 + 1, y0 + 1, s)
        return (a + (b - a) * sx) + ((c + (d - c) * sx) - (a + (b - a) * sx)) * sy
    }

    static let chunkTiles = 16

    /// One chunk of ground art (chunkTiles × chunkTiles tiles), drawn with SpriteKit's y-up convention flipped in.
    static func terrainChunk(_ map: GameMap, cx: Int, cy: Int) -> SKTexture {
        let T = CGFloat(Defs.tile)
        let n = chunkTiles
        let size = CGFloat(n) * T
        let seed = map.decoSeed
        let img = image(size, size, scale: 1.25) { g in
            // flip so y goes up like the world
            g.translateBy(x: 0, y: size)
            g.scaleBy(x: 1, y: -1)
            let ox = cx * n, oy = cy * n
            // grass, with large soft color variation
            for ty in -1...n {
                for tx in -1...n {
                    let wx = ox + tx, wy = oy + ty
                    let v = noise(Double(wx) / 6, Double(wy) / 6, seed) * 0.6 + noise(Double(wx) / 2.3, Double(wy) / 2.3, seed + 1) * 0.4
                    let col = rgb(0.24 + 0.08 * v, 0.42 + 0.12 * v, 0.18 + 0.05 * v)
                    g.setFillColor(col.cgColor)
                    g.fill(CGRect(x: CGFloat(tx) * T - 0.5, y: CGFloat(ty) * T - 0.5, width: T + 1, height: T + 1))
                }
            }
            // soften the tile grid with blotches
            for ty in -1...n {
                for tx in -1...n {
                    let wx = ox + tx, wy = oy + ty
                    for k in 0..<3 {
                        let h = hash(wx * 3 + k, wy, seed + 7)
                        let px = (CGFloat(tx) + CGFloat(hash(wx, wy * 5 + k, seed + 3))) * T
                        let py = (CGFloat(ty) + CGFloat(hash(wx * 7 + k, wy, seed + 4))) * T
                        let r = 6 + CGFloat(h) * 12
                        let light = hash(wx, wy + k * 11, seed + 9) > 0.5
                        fill(g, circle(px, py, r), light ? rgb(0.45, 0.62, 0.28, 0.12) : rgb(0.12, 0.25, 0.10, 0.12))
                    }
                }
            }
            func each(_ t: Terrain, _ body: (CGFloat, CGFloat, Int, Int) -> Void) {
                for ty in -2...(n + 1) {
                    for tx in -2...(n + 1) {
                        let wx = ox + tx, wy = oy + ty
                        if map.inBounds(wx, wy) ? map.terrainAt(wx, wy) == t : t == .rock {
                            body((CGFloat(tx) + 0.5) * T, (CGFloat(ty) + 0.5) * T, wx, wy)
                        }
                    }
                }
            }
            // dirt
            each(.dirt) { x, y, wx, wy in
                fill(g, circle(x, y, T * 0.85), rgb(0.47, 0.38, 0.25, 0.55))
                fill(g, circle(x + CGFloat(hash(wx, wy, seed) - 0.5) * 10, y, T * 0.6), rgb(0.53, 0.43, 0.29, 0.9))
            }
            each(.dirt) { x, y, wx, wy in
                for k in 0..<3 {
                    let px = x + CGFloat(hash(wx + k, wy, seed + 21) - 0.5) * T
                    let py = y + CGFloat(hash(wx, wy + k, seed + 22) - 0.5) * T
                    fill(g, circle(px, py, 1.4 + CGFloat(hash(wx, wy, seed + UInt64(k))) * 1.4), rgb(0.38, 0.31, 0.22, 0.8))
                }
            }
            // water: sand shore, deep water, shallows, glints
            each(.water) { x, y, _, _ in fill(g, circle(x, y, T * 0.98), rgb(0.80, 0.74, 0.52)) }
            each(.water) { x, y, _, _ in fill(g, circle(x, y, T * 0.82), rgb(0.30, 0.62, 0.70)) }
            each(.water) { x, y, wx, wy in
                let deep = (0..<4).allSatisfy { k in
                    let (dx, dy) = [(1, 0), (-1, 0), (0, 1), (0, -1)][k]
                    return map.terrainAt(wx + dx, wy + dy) == .water
                }
                fill(g, circle(x, y, T * (deep ? 0.78 : 0.6)), deep ? rgb(0.13, 0.36, 0.55) : rgb(0.2, 0.5, 0.64))
            }
            each(.water) { x, y, wx, wy in
                if hash(wx, wy, seed + 31) > 0.55 {
                    let px = x + CGFloat(hash(wx, wy, seed + 32) - 0.5) * T * 0.7
                    let py = y + CGFloat(hash(wx, wy, seed + 33) - 0.5) * T * 0.7
                    g.setStrokeColor(rgb(0.85, 0.95, 1, 0.45).cgColor)
                    g.setLineWidth(1.2)
                    g.move(to: CGPoint(x: px - 4, y: py))
                    g.addQuadCurve(to: CGPoint(x: px + 4, y: py), control: CGPoint(x: px, y: py + 2))
                    g.strokePath()
                }
            }
            // rocks: shadow, boulders, highlights
            each(.rock) { x, y, _, _ in fill(g, circle(x + 5, y - 6, T * 0.82), rgb(0, 0, 0, 0.28)) }
            each(.rock) { x, y, wx, wy in
                let r = T * (0.68 + CGFloat(hash(wx, wy, seed + 41)) * 0.18)
                let ox2 = CGFloat(hash(wx, wy, seed + 42) - 0.5) * 6
                let p = CGMutablePath()
                let sides = 7
                for k in 0..<sides {
                    let a = CGFloat(k) / CGFloat(sides) * 2 * .pi
                    let rr = r * (0.82 + CGFloat(hash(wx * 13 + k, wy, seed + 43)) * 0.3)
                    let pt = CGPoint(x: x + ox2 + cos(a) * rr, y: y + sin(a) * rr)
                    if k == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                }
                p.closeSubpath()
                let tint = CGFloat(hash(wx, wy, seed + 44)) * 0.08
                // lit from the top-left (y up here)
                g.saveGState()
                g.addPath(p)
                g.clip()
                let colors = [rgb(0.66 + tint, 0.62 + tint, 0.55).cgColor, rgb(0.45 + tint, 0.42 + tint, 0.37).cgColor,
                              rgb(0.27, 0.25, 0.23).cgColor] as CFArray
                let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.5, 1])!
                g.drawRadialGradient(grad, startCenter: CGPoint(x: x - r * 0.4, y: y + r * 0.45), startRadius: 0,
                                     endCenter: CGPoint(x: x, y: y), endRadius: r * 1.5, options: [.drawsAfterEndLocation])
                g.restoreGState()
                stroke(g, p, rgb(0.18, 0.16, 0.15, 0.6), 1)
                // crack
                g.setStrokeColor(rgb(0.2, 0.18, 0.16, 0.5).cgColor)
                g.setLineWidth(0.9)
                g.move(to: CGPoint(x: x - r * 0.3, y: y + r * 0.2))
                g.addLine(to: CGPoint(x: x + r * 0.1, y: y - r * 0.1))
                g.addLine(to: CGPoint(x: x + r * 0.35, y: y - r * 0.05))
                g.strokePath()
            }
            // grass details: tufts, flowers and pebbles
            each(.grass) { x, y, wx, wy in
                let h = hash(wx, wy, seed + 51)
                if h > 0.72 {
                    let px = x + CGFloat(hash(wx, wy, seed + 52) - 0.5) * T * 0.8
                    let py = y + CGFloat(hash(wx, wy, seed + 53) - 0.5) * T * 0.8
                    g.setStrokeColor(rgb(0.16, 0.32, 0.12, 0.8).cgColor)
                    g.setLineWidth(1)
                    for k in -1...1 {
                        g.move(to: CGPoint(x: px + CGFloat(k) * 1.5, y: py))
                        g.addLine(to: CGPoint(x: px + CGFloat(k) * 3, y: py + 4.5))
                    }
                    g.strokePath()
                } else if h < 0.05 {
                    let px = x + CGFloat(hash(wx, wy, seed + 54) - 0.5) * T * 0.8
                    let py = y + CGFloat(hash(wx, wy, seed + 55) - 0.5) * T * 0.8
                    let flower = hash(wx, wy, seed + 56) > 0.5 ? rgb(1, 0.92, 0.4) : rgb(0.95, 0.6, 0.85)
                    for k in 0..<3 { fill(g, circle(px + CGFloat(k) * 2.5 - 2.5, py + CGFloat(k % 2) * 2, 1.2), flower) }
                } else if h < 0.09 {
                    let px = x + CGFloat(hash(wx, wy, seed + 57) - 0.5) * T * 0.8
                    let py = y + CGFloat(hash(wx, wy, seed + 58) - 0.5) * T * 0.8
                    fill(g, circle(px + 0.8, py - 0.8, 2.2), rgb(0, 0, 0, 0.2))
                    fill(g, circle(px, py, 2), rgb(0.62, 0.6, 0.56))
                }
            }
        }
        let t = SKTexture(image: img)
        t.filteringMode = .linear
        return t
    }

    /// One pixel per tile, for the minimap.
    static func minimap(_ map: GameMap) -> UIImage {
        let w = CGFloat(map.width), h = CGFloat(map.height)
        return image(w, h, scale: 2) { g in
            for y in 0..<map.height {
                for x in 0..<map.width {
                    let c: UIColor
                    switch map.terrainAt(x, y) {
                    case .grass: c = rgb(0.25, 0.42, 0.2)
                    case .dirt: c = rgb(0.45, 0.37, 0.25)
                    case .rock: c = rgb(0.38, 0.36, 0.33)
                    case .water: c = rgb(0.15, 0.38, 0.55)
                    }
                    g.setFillColor(c.cgColor)
                    g.fill(CGRect(x: CGFloat(x), y: h - 1 - CGFloat(y), width: 1, height: 1))
                }
            }
        }
    }
}
