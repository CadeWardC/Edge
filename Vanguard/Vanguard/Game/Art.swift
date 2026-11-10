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

    static func texture(_ key: String, _ make: () -> UIImage) -> SKTexture {
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

    static func fill(_ g: CGContext, _ p: CGPath, _ c: UIColor) {
        g.addPath(p)
        g.setFillColor(c.cgColor)
        g.fillPath()
    }

    static func stroke(_ g: CGContext, _ p: CGPath, _ c: UIColor, _ w: CGFloat) {
        g.addPath(p)
        g.setStrokeColor(c.cgColor)
        g.setLineWidth(w)
        g.setLineJoin(.round)
        g.setLineCap(.round)
        g.strokePath()
    }

    /// Fills a shape with a radial gradient lit from the top-left.
    static func shaded(_ g: CGContext, _ p: CGPath, _ c: UIColor, light: CGFloat = 1.45, dark: CGFloat = 0.62) {
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

    static func circle(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) -> CGPath {
        CGPath(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r), transform: nil)
    }

    static func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat = 0) -> CGPath {
        CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerWidth: min(r, w / 2), cornerHeight: min(r, h / 2), transform: nil)
    }

    static func poly(_ pts: [(CGFloat, CGFloat)]) -> CGPath {
        let p = CGMutablePath()
        guard let f = pts.first else { return p }
        p.move(to: CGPoint(x: f.0, y: f.1))
        for q in pts.dropFirst() { p.addLine(to: CGPoint(x: q.0, y: q.1)) }
        p.closeSubpath()
        return p
    }

    static func octagon(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) -> CGPath {
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

    // MARK: units are drawn in ArtUnits.swift

    // MARK: buildings (drawing in ArtWorld.swift)

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

    /// Thin ring under selected units.
    static func selectRing() -> SKTexture {
        texture("selring") {
            image(64, 64, scale: 2) { g in
                fill(g, circle(32, 32, 29), rgb(1, 1, 1, 0.10))
                stroke(g, circle(32, 32, 29), .white, 2)
            }
        }
    }

    /// Soft dark corners over the whole view.
    static func vignette() -> SKTexture {
        texture("vignette") {
            image(128, 128, scale: 1) { g in
                let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                      colors: [rgb(0, 0, 0, 0).cgColor, rgb(0, 0, 0, 0).cgColor, rgb(0, 0, 0.03, 0.55).cgColor] as CFArray,
                                      locations: [0, 0.62, 1])!
                g.drawRadialGradient(grad, startCenter: CGPoint(x: 64, y: 64), startRadius: 0, endCenter: CGPoint(x: 64, y: 64), endRadius: 92,
                                     options: [.drawsAfterEndLocation])
            }
        }
    }

    /// Target marker for an incoming Orbital Strike.
    static func reticle() -> SKTexture {
        texture("reticle") {
            image(96, 96, scale: 2) { g in
                g.setLineDash(phase: 0, lengths: [14, 8])
                stroke(g, circle(48, 48, 44), .white, 3)
                g.setLineDash(phase: 0, lengths: [])
                stroke(g, circle(48, 48, 26), .white, 1.5)
                g.setStrokeColor(UIColor.white.cgColor)
                g.setLineWidth(2)
                for (x, y) in [(48, 4), (48, 92), (4, 48), (92, 48)] as [(CGFloat, CGFloat)] {
                    g.move(to: CGPoint(x: x, y: y))
                    g.addLine(to: CGPoint(x: 48 + (x - 48) * 0.6, y: 48 + (y - 48) * 0.6))
                }
                g.strokePath()
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

    static func turretGunImage(_ team: TeamColor) -> UIImage {
        let s: CGFloat = 64
        let c = color(team)
        return image(s, s, scale: 1) { g in
            g.translateBy(x: s / 2, y: s / 2)
            for y: CGFloat in [-4.5, 2] { shaded(g, rect(6, y, 22, 2.8, 1), darkSteel, light: 1.7) }
            let head = rect(-11, -11, 22, 22, 6)
            shaded(g, head, c)
        }
    }

    static func composite(_ a: UIImage, _ b: UIImage, size: CGFloat) -> UIImage {
        image(size, size, scale: 2) { _ in
            a.draw(in: CGRect(x: 0, y: 0, width: size, height: size))
            let bs = b.size
            b.draw(in: CGRect(x: (size - bs.width) / 2, y: (size - bs.height) / 2, width: bs.width, height: bs.height))
        }
    }

    static func rotatedIcon(_ img: UIImage, _ angle: CGFloat) -> UIImage {
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

}
