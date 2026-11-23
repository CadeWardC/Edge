import SpriteKit
import UIKit

/// Turns an aircraft's parts into pictures: moving nodes for the game and a still image for the hangar.
enum AircraftArt {
    static let outlineWidth: CGFloat = 1.5

    static func color(_ hex: String?) -> UIColor {
        guard let hex, let c = Hex.components(hex) else { return .clear }
        return UIColor(red: c.red, green: c.green, blue: c.blue, alpha: c.alpha)
    }

    /// The point a part turns and animates around: its centre.
    static func pivot(_ part: AircraftSpec.Part) -> CGPoint {
        if part.shape == "polygon", let points = part.points, !points.isEmpty {
            let xs = points.map { $0[0] }, ys = points.map { $0[1] }
            return CGPoint(x: (xs.min()! + xs.max()!) / 2, y: (ys.min()! + ys.max()!) / 2)
        }
        return CGPoint(x: part.x ?? 0, y: part.y ?? 0)
    }

    /// The part's outline around its pivot, y up.
    static func path(_ part: AircraftSpec.Part) -> CGPath {
        let path = CGMutablePath()
        let center = pivot(part)
        switch part.shape {
        case "polygon":
            let points = (part.points ?? []).map { CGPoint(x: $0[0] - center.x, y: $0[1] - center.y) }
            guard points.count >= 3 else { break }
            if part.smooth == true {
                // a closed curve that touches the middle of every side
                func middle(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
                let count = points.count
                path.move(to: middle(points[0], points[1]))
                for index in 0..<count {
                    let corner = points[(index + 1) % count]
                    path.addQuadCurve(to: middle(corner, points[(index + 2) % count]), control: corner)
                }
            } else {
                path.addLines(between: points)
            }
            path.closeSubpath()
        case "rect":
            let width = CGFloat(part.width ?? 1), height = CGFloat(part.height ?? 1)
            let radius = max(0, min(CGFloat(part.radius ?? 0), width / 2, height / 2))
            path.addRoundedRect(in: CGRect(x: -width / 2, y: -height / 2, width: width, height: height), cornerWidth: radius, cornerHeight: radius)
        default:
            let width = CGFloat(part.width ?? 1), height = CGFloat(part.height ?? 1)
            path.addEllipse(in: CGRect(x: -width / 2, y: -height / 2, width: width, height: height))
        }
        let degrees = part.rotation ?? 0
        guard degrees != 0 else { return path }
        var turn = CGAffineTransform(rotationAngle: CGFloat(degrees) * .pi / 180)
        return path.copy(using: &turn) ?? path
    }

    /// The box around the whole drawing, in aircraft units.
    static func bounds(_ spec: AircraftSpec) -> CGRect {
        var box = CGRect.null
        for part in spec.parts {
            let center = pivot(part)
            box = box.union(path(part).boundingBoxOfPath.offsetBy(dx: center.x, dy: center.y))
        }
        return box.isNull ? CGRect(x: -40, y: -15, width: 80, height: 30) : box
    }

    /// What the aircraft can bump into: its "hitbox", or most of its drawing.
    static func hitbox(_ spec: AircraftSpec) -> CGSize {
        if let box = spec.hitbox, box.width > 0, box.height > 0 {
            return CGSize(width: min(max(box.width, 10), 160), height: min(max(box.height, 8), 100))
        }
        let box = bounds(spec)
        return CGSize(width: min(max(box.width * 0.7, 10), 160), height: min(max(box.height * 0.5, 8), 100))
    }

    static func node(for spec: AircraftSpec) -> SKNode {
        let aircraft = SKNode()
        for (index, part) in spec.parts.enumerated() {
            let shape = SKShapeNode(path: path(part))
            shape.position = pivot(part)
            shape.fillColor = color(part.color)
            shape.strokeColor = color(part.outline)
            shape.lineWidth = part.outline == nil ? 0 : outlineWidth
            shape.zPosition = CGFloat(index) * 0.01
            if let action = animation(part.animation) { shape.run(.repeatForever(action)) }
            aircraft.addChild(shape)
        }
        return aircraft
    }

    private static func animation(_ name: String?) -> SKAction? {
        switch name {
        case "propeller": return .sequence([.scaleY(to: 0.2, duration: 0.05), .scaleY(to: 1, duration: 0.05)])
        case "rotor": return .sequence([.scaleX(to: 0.25, duration: 0.06), .scaleX(to: 1, duration: 0.06)])
        case "spin": return .rotate(byAngle: -2 * .pi, duration: 0.7)
        case "blink": return .sequence([.fadeAlpha(to: 0.35, duration: 0.3), .fadeAlpha(to: 1, duration: 0.3)])
        default: return nil
        }
    }

    static func image(for spec: AircraftSpec, size: CGSize) -> UIImage {
        let box = bounds(spec)
        let scale = min(size.width / max(box.width, 1), size.height / max(box.height, 1)) * 0.92
        return UIGraphicsImageRenderer(size: size).image { renderer in
            let context = renderer.cgContext
            context.translateBy(x: size.width / 2, y: size.height / 2)
            context.scaleBy(x: scale, y: -scale)
            context.translateBy(x: -box.midX, y: -box.midY)
            for part in spec.parts {
                let center = pivot(part)
                context.saveGState()
                context.translateBy(x: center.x, y: center.y)
                context.addPath(path(part))
                context.setFillColor(color(part.color).cgColor)
                context.fillPath()
                if part.outline != nil {
                    context.addPath(path(part))
                    context.setStrokeColor(color(part.outline).cgColor)
                    context.setLineWidth(outlineWidth)
                    context.strokePath()
                }
                context.restoreGState()
            }
        }
    }
}
