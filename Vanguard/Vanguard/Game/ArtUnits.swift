import SpriteKit
import UIKit

/// Units, drawn facing +x, with a dark outline for readability and a few animation frames each:
/// infantry walk, treads roll, engines flicker, rotors spin.
extension Art {
    static func unitSize(_ t: EntityType) -> CGFloat { CGFloat(t.stats.radius) * 2 + 18 }

    /// Frames in a unit's move animation.
    static func unitFrames(_ t: EntityType) -> Int {
        switch t {
        case .trooper, .lancer, .mender: return 4
        case .tank: return 3
        case .worker, .skimmer, .gunship: return 2
        default: return 1
        }
    }

    static func unit(_ t: EntityType, _ team: TeamColor, frame: Int = 0) -> SKTexture {
        cachedTexture("u3-\(t.rawValue)-\(team.rawValue)-\(frame)") { unitImage(t, team, frame: frame) }
    }

    static func unitImage(_ t: EntityType, _ team: TeamColor, frame: Int = 0, iconScale: CGFloat? = nil) -> UIImage {
        let s = unitSize(t)
        let c = color(team)
        return image(s, s, scale: iconScale ?? scale) { g in
            g.translateBy(x: s / 2, y: s / 2)
            switch t {
            case .worker: drawDrone(g, c, frame)
            case .trooper: drawSoldier(g, c, frame, kind: 0)
            case .lancer: drawSoldier(g, c, frame, kind: 1)
            case .mender: drawSoldier(g, c, frame, kind: 2)
            case .skimmer: drawSkimmer2(g, c, frame)
            case .tank: drawTank2(g, c, frame)
            case .gunship: drawGunship2(g, c, frame)
            default: break
            }
        }
    }

    // MARK: helpers

    static let outline = rgb(0.04, 0.05, 0.07, 0.75)

    /// Fill with lit shading, then a dark outline.
    static func part(_ g: CGContext, _ p: CGPath, _ c: UIColor, light: CGFloat = 1.45, dark: CGFloat = 0.6, line: CGFloat = 1) {
        shaded(g, p, c, light: light, dark: dark)
        stroke(g, p, outline, line)
    }

    static func ellipse(_ x: CGFloat, _ y: CGFloat, _ rx: CGFloat, _ ry: CGFloat) -> CGPath {
        CGPath(ellipseIn: CGRect(x: x - rx, y: y - ry, width: rx * 2, height: ry * 2), transform: nil)
    }

    // MARK: drone

    private static func drawDrone(_ g: CGContext, _ c: UIColor, _ f: Int) {
        // hover pods with glowing thrusters
        for side: CGFloat in [-1, 1] {
            let pod = rect(-7, side * 8 - 2.6, 10, 5.2, 2.6)
            part(g, pod, steel, line: 0.8)
            let glowA: CGFloat = f == 0 ? 0.9 : 0.55
            fill(g, circle(-7.5, side * 8, 3), rgb(0.35, 0.9, 1, 0.35 * glowA))
            fill(g, circle(-7.2, side * 8, 1.5), rgb(0.7, 1, 1, glowA))
        }
        // mining arm
        fill(g, rect(4, -1.2, 7, 2.4, 1), darkSteel)
        part(g, poly([(10, -3.4), (13.5, -2.2), (13.5, 2.2), (10, 3.4), (11.2, 0)]), hazard, line: 0.7)
        // body shell
        let body = circle(-0.5, 0, 7.4)
        part(g, body, c, light: 1.6, dark: 0.5, line: 1.1)
        fill(g, circle(-2.2, 0, 4), shade(c, 0.68))
        // panel line and sensor eye
        g.setStrokeColor(rgb(0, 0, 0, 0.3).cgColor)
        g.setLineWidth(0.6)
        g.move(to: CGPoint(x: -6.5, y: 0)); g.addLine(to: CGPoint(x: 1, y: 0))
        g.strokePath()
        fill(g, circle(3.2, 0, 2.3), rgb(0.15, 0.2, 0.25))
        fill(g, circle(3.4, 0, 1.5), glass)
        fill(g, circle(3.9, -0.6, 0.6), .white)
    }

    // MARK: infantry

    private static func drawSoldier(_ g: CGContext, _ c: UIColor, _ f: Int, kind: Int) {
        let swing: [CGFloat] = [0, 3, 0, -3]
        let k = swing[f % 4]
        let armor = kind == 2 ? rgb(0.93, 0.94, 0.95) : c
        let dark = shade(kind == 2 ? rgb(0.85, 0.86, 0.88) : c, 0.6)
        // boots (seen under the body as the legs swing)
        part(g, ellipse(1 + k, -4.2, 3.4, 2), rgb(0.16, 0.16, 0.18), line: 0.7)
        part(g, ellipse(1 - k, 4.2, 3.4, 2), rgb(0.16, 0.16, 0.18), line: 0.7)
        // backpack
        part(g, rect(-9.5, -5, 6, 10, 2), kind == 2 ? rgb(0.9, 0.92, 0.94) : rgb(0.3, 0.32, 0.28), line: 0.8)
        if kind == 2 {
            fill(g, rect(-8.3, -1, 3.6, 2), rgb(0.2, 0.8, 0.35))
            fill(g, rect(-7.5, -2.2, 2, 4.4), rgb(0.2, 0.8, 0.35))
        } else {
            fill(g, rect(-9, -4, 1.5, 8), shade(c, 0.9))
        }
        // weapon
        switch kind {
        case 0:
            part(g, rect(0, 1.3, 14, 2.6, 0.8), gunmetal, light: 1.8, line: 0.6)
            fill(g, rect(12, 1.7, 3.5, 1.8, 0.5), darkSteel)
            fill(g, rect(5, 3.6, 2, 2.4, 0.5), gunmetal)
        case 1:
            part(g, rect(-11, 2.4, 25, 5.2, 2.2), rgb(0.42, 0.46, 0.32), light: 1.5, line: 0.8)
            fill(g, rect(-11, 3, 3, 4, 1), rgb(0.15, 0.15, 0.15))
            fill(g, rect(11, 2.4, 3, 5.2, 1), rgb(0.95, 0.35, 0.15))
            fill(g, rect(2, 2.4, 2, 5.2), shade(c, 0.9))
        default:
            // med drone orb floating ahead
            fill(g, circle(9, -6.5, 3.8), rgb(0.4, 1, 0.5, 0.3))
            part(g, circle(9, -6.5, 2.2), rgb(0.85, 1, 0.9), light: 1.2, line: 0.6)
            fill(g, rect(1, 1.5, 8, 2.2, 0.7), darkSteel)
        }
        // arms forward (swing a little)
        part(g, rect(0.5, -6.8 + k * 0.3, 6.5, 3, 1.5), dark, line: 0.6)
        part(g, rect(0.5, 3.8 - k * 0.3, 6, 3, 1.5), dark, line: 0.6)
        // shoulders / body armor
        let torso = ellipse(-1, 0, 5.4, 8.2)
        part(g, torso, armor, light: 1.55, dark: 0.55, line: 1.1)
        fill(g, rect(-3.5, -6, 2, 12, 1), shade(armor, 0.75).withAlphaComponent(0.6))
        if kind == 1 { part(g, ellipse(-1, -6.5, 3, 2.4), shade(c, 0.85), line: 0.6) }
        if kind == 2 { fill(g, rect(-2, -7.6, 1.6, 15.2), c) }
        // helmet with visor
        let helmet = circle(0.8, 0, 4.7)
        part(g, helmet, kind == 2 ? rgb(0.97, 0.98, 0.99) : shade(c, 0.66), light: 1.7, dark: 0.55, line: 1)
        fill(g, CGPath(roundedRect: CGRect(x: 2.6, y: -2.6, width: 2.6, height: 5.2), cornerWidth: 1.2, cornerHeight: 1.2, transform: nil),
             kind == 2 ? rgb(0.25, 0.7, 0.4, 0.9) : rgb(0.35, 0.85, 1, 0.9))
        fill(g, circle(-0.6, -1.6, 1.2), rgb(1, 1, 1, 0.35))
    }

    // MARK: skimmer

    private static func drawSkimmer2(_ g: CGContext, _ c: UIColor, _ f: Int) {
        // engine flames
        let flame: CGFloat = f == 0 ? 7 : 4.5
        for side: CGFloat in [-1, 1] {
            fill(g, poly([(-11, side * 4.5 - 2.2), (-11 - flame, side * 4.5), (-11, side * 4.5 + 2.2)]), rgb(1, 0.55, 0.15, 0.85))
            fill(g, poly([(-11, side * 4.5 - 1.2), (-11 - flame * 0.55, side * 4.5), (-11, side * 4.5 + 1.2)]), rgb(1, 0.95, 0.6))
        }
        // side fins
        part(g, poly([(-6, -6), (3, -12.5), (6.5, -11.5), (0, -4.5)]), darkSteel, light: 1.7, line: 0.8)
        part(g, poly([(-6, 6), (3, 12.5), (6.5, 11.5), (0, 4.5)]), darkSteel, light: 1.7, line: 0.8)
        // engines
        part(g, rect(-12, -7, 9, 5, 2.4), steel, line: 0.8)
        part(g, rect(-12, 2, 9, 5, 2.4), steel, line: 0.8)
        // hull
        let body = poly([(17, 0), (5, -6.5), (-9, -6.2), (-6, 0), (-9, 6.2), (5, 6.5)])
        part(g, body, c, light: 1.7, dark: 0.5, line: 1.1)
        fill(g, poly([(15, 0), (5, -2.4), (-5, -1.6), (-5, 1.6), (5, 2.4)]), shade(c, 1.35))
        // rider
        part(g, circle(-1.5, 0, 3.4), shade(c, 0.6), light: 1.8, line: 0.8)
        fill(g, rect(0.2, -1.8, 1.8, 3.6, 0.8), rgb(0.35, 0.85, 1, 0.9))
        // windscreen
        part(g, ellipse(5, 0, 3.2, 2.6), rgb(0.2, 0.45, 0.75), light: 2, line: 0.6)
        fill(g, circle(14, 0, 1.1), rgb(1, 0.3, 0.2))
    }

    // MARK: tank

    private static func drawTank2(_ g: CGContext, _ c: UIColor, _ f: Int) {
        // tracks with rolling treads
        for side: CGFloat in [-1, 1] {
            let y = side > 0 ? 8.5 : -15
            let track = rect(-17, y, 34, 6.5, 2.8)
            part(g, track, rgb(0.13, 0.13, 0.15), light: 1.7, line: 1)
            g.saveGState()
            g.addPath(track)
            g.clip()
            g.setStrokeColor(rgb(0.36, 0.36, 0.38, 0.9).cgColor)
            g.setLineWidth(1.1)
            var x: CGFloat = -18 + CGFloat(f)
            while x < 18 {
                g.move(to: CGPoint(x: x, y: y)); g.addLine(to: CGPoint(x: x, y: y + 6.5))
                x += 3
            }
            g.strokePath()
            g.restoreGState()
        }
        // hull with sloped front armor
        let hull = poly([(15, -8), (17, -5), (17, 5), (15, 8), (-15, 9), (-16, 6), (-16, -6), (-15, -9)])
        part(g, hull, shade(c, 0.85), light: 1.4, dark: 0.55, line: 1.2)
        fill(g, poly([(11, -7.5), (16, -4.5), (16, 4.5), (11, 7.5)]), shade(c, 1.25))
        // armor skirts lines and team stripe
        fill(g, rect(-15, -2.2, 6, 4.4, 1), shade(c, 0.55))
        fill(g, rect(-6, -9, 3, 18), shade(c, 1.15).withAlphaComponent(0.45))
        // engine deck grille and exhaust
        g.setStrokeColor(rgb(0, 0, 0, 0.4).cgColor)
        g.setLineWidth(0.8)
        for i in 0..<4 {
            let yy = CGFloat(-5.5 + Double(i) * 3.6)
            g.move(to: CGPoint(x: -14, y: yy)); g.addLine(to: CGPoint(x: -10, y: yy))
        }
        g.strokePath()
        fill(g, circle(-16.5, -6, 1.4), rgb(0.1, 0.1, 0.1))
        // tow hooks and lights
        fill(g, circle(16.2, -6, 1), rgb(1, 0.95, 0.7))
        fill(g, circle(16.2, 6, 1), rgb(1, 0.95, 0.7))
    }

    static func tankTurret(_ team: TeamColor) -> SKTexture {
        cachedTexture("tt3-\(team.rawValue)") { tankTurretImage(team) }
    }

    static func tankTurretImage(_ team: TeamColor, scale sc: CGFloat? = nil) -> UIImage {
        let s: CGFloat = 60
        let c = color(team)
        return image(s, s, scale: sc ?? scale) { g in
            g.translateBy(x: s / 2, y: s / 2)
            // barrel with muzzle brake
            part(g, rect(5, -2.1, 22, 4.2, 1.4), darkSteel, light: 1.9, line: 0.9)
            part(g, rect(25, -3.2, 5, 6.4, 1.2), gunmetal, light: 1.6, line: 0.9)
            fill(g, rect(9, -2.1, 2, 4.2), shade(c, 0.9))
            // turret body
            let tur = poly([(9, -6), (10, 0), (9, 6), (-4, 8.5), (-9, 5), (-9, -5), (-4, -8.5)])
            part(g, tur, c, light: 1.65, dark: 0.5, line: 1.1)
            // commander hatch and sight
            part(g, circle(-3, -3, 2.8), shade(c, 0.65), light: 1.8, line: 0.7)
            fill(g, rect(3, 2.2, 3.5, 2.4, 0.8), rgb(0.35, 0.85, 1, 0.9))
            fill(g, rect(-8, -1, 2, 2), rgb(0, 0, 0, 0.4))
        }
    }

    // MARK: gunship

    private static func drawGunship2(_ g: CGContext, _ c: UIColor, _ f: Int) {
        // stub wings with missile pods
        let wing = poly([(5, -4), (8, -4), (3, -15), (-3, -15), (-6, -4)])
        let wing2 = poly([(5, 4), (8, 4), (3, 15), (-3, 15), (-6, 4)])
        part(g, wing, shade(c, 0.75), line: 0.9)
        part(g, wing2, shade(c, 0.75), line: 0.9)
        for side: CGFloat in [-1, 1] {
            part(g, rect(-2, side * 10 - 1.4, 9, 2.8, 1.4), rgb(0.85, 0.85, 0.8), light: 1.3, line: 0.6)
            fill(g, poly([(7, side * 10 - 1.4), (9.5, side * 10), (7, side * 10 + 1.4)]), rgb(0.9, 0.3, 0.2))
        }
        // ducted fans at the wing tips, blades spinning
        for side: CGFloat in [-1, 1] {
            let cy = side * 17
            part(g, circle(-1, cy, 6.5), steel, light: 1.4, line: 1)
            fill(g, circle(-1, cy, 5), rgb(0.08, 0.09, 0.1, 0.9))
            g.saveGState()
            g.translateBy(x: -1, y: cy)
            g.rotate(by: CGFloat(f) * .pi / 4)
            g.setStrokeColor(rgb(0.8, 0.85, 0.9, 0.8).cgColor)
            g.setLineWidth(1.4)
            for b in 0..<3 {
                let a = CGFloat(b) * 2 * .pi / 3
                g.move(to: .zero); g.addLine(to: CGPoint(x: cos(a) * 4.6, y: sin(a) * 4.6))
            }
            g.strokePath()
            g.restoreGState()
            fill(g, circle(-1, cy, 1.4), shade(c, 0.9))
        }
        // tail boom and fins
        part(g, rect(-21, -1.6, 10, 3.2, 1.4), shade(c, 0.7), line: 0.8)
        part(g, poly([(-19, 0), (-24, -7), (-21, -7), (-16, -1)]), shade(c, 0.6), line: 0.8)
        part(g, poly([(-19, 0), (-24, 7), (-21, 7), (-16, 1)]), shade(c, 0.6), line: 0.8)
        // fuselage
        let body = poly([(18, 0), (14, -4.5), (2, -6), (-12, -4.5), (-14, 0), (-12, 4.5), (2, 6), (14, 4.5)])
        part(g, body, c, light: 1.65, dark: 0.5, line: 1.2)
        fill(g, rect(-8, -1, 16, 2), shade(c, 1.3).withAlphaComponent(0.6))
        // nose cannon and canopy
        fill(g, rect(16, -0.8, 6, 1.6, 0.6), gunmetal)
        part(g, ellipse(9, 0, 4.5, 3), rgb(0.15, 0.4, 0.7), light: 2.1, line: 0.7)
        fill(g, circle(10.5, -1, 1), rgb(1, 1, 1, 0.8))
        // engine glow
        let glowA: CGFloat = f == 0 ? 0.9 : 0.6
        fill(g, circle(-13, -3, 1.6), rgb(0.5, 0.95, 1, glowA))
        fill(g, circle(-13, 3, 1.6), rgb(0.5, 0.95, 1, glowA))
    }
}
