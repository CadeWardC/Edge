import SceneKit
import UIKit

/// A part that turns while the engine runs.
struct Spinner {
    let node: SCNNode
    let axis: SIMD3<Float>
    /// Radians a second at full power.
    let rate: Float
}

/// An aircraft ready to put in a scene.
struct BuiltAircraft {
    let node: SCNNode
    let spinners: [Spinner]
    /// From the aircraft's middle down to the bottom of its wheels or skids.
    let gearHeight: Float
    /// Roughly how big it is, for placing cameras.
    let radius: Float
    let length: Float
    let span: Float
    let cockpit: SIMD3<Float>
}

/// Builds the 3D model an aircraft file describes.
enum AircraftBuilder {
    static func build(_ spec: AircraftSpec) -> BuiltAircraft {
        let root = SCNNode()
        var spinners: [Spinner] = []
        var materials: [String: SCNMaterial] = [:]

        for part in spec.parts {
            let material = materials[part.color] ?? makeMaterial(part.color)
            materials[part.color] = material
            let sides: [Float] = part.mirror == true ? [1, -1] : [1]
            for side in sides {
                let holder = SCNNode()
                holder.simdPosition = vector(part.position)
                holder.simdOrientation = rotation(part.rotation)
                let spinNode = SCNNode()
                spinNode.addChildNode(shapeNode(part, material: material))
                holder.addChildNode(spinNode)
                if side > 0 {
                    root.addChildNode(holder)
                } else {
                    // the same part on the other side of the aircraft
                    let mirror = SCNNode()
                    mirror.simdScale = SIMD3<Float>(1, 1, -1)
                    mirror.addChildNode(holder)
                    root.addChildNode(mirror)
                }
                switch part.spin {
                case "propeller": spinners.append(Spinner(node: spinNode, axis: SIMD3<Float>(1, 0, 0), rate: 45))
                case "rotor": spinners.append(Spinner(node: spinNode, axis: SIMD3<Float>(0, 1, 0), rate: 24))
                case "tailrotor": spinners.append(Spinner(node: spinNode, axis: SIMD3<Float>(0, 0, 1), rate: 55))
                default: break
                }
            }
        }

        let box = root.flattenedClone().boundingBox
        let low = SIMD3<Float>(box.min), high = SIMD3<Float>(box.max)
        let size = high - low
        let cockpit = spec.cockpit.map { vector($0) } ?? SIMD3<Float>(0, max(high.y * 0.5, 0.5), 0)
        return BuiltAircraft(
            node: root, spinners: spinners,
            gearHeight: max(-low.y, 0.2),
            radius: max(simd_length(size) / 2, 2),
            length: max(size.x, 1), span: max(size.z, 1),
            cockpit: cockpit)
    }

    /// A small scene that shows the aircraft turning, for the hangar.
    static func previewScene(_ spec: AircraftSpec) -> SCNScene {
        let scene = SCNScene()
        scene.background.contents = UIColor(red: 0.62, green: 0.82, blue: 0.96, alpha: 1)
        let built = build(spec)
        let turntable = SCNNode()
        turntable.addChildNode(built.node)
        turntable.runAction(.repeatForever(.rotateBy(x: 0, y: 2 * .pi, z: 0, duration: 14)))
        scene.rootNode.addChildNode(turntable)

        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera?.fieldOfView = 40
        camera.camera?.zFar = 500
        let r: Float = built.radius
        camera.simdPosition = SIMD3<Float>(r * 1.9, r * 0.8, r * 2.2)
        camera.simdLook(at: SIMD3<Float>(0, 0, 0), up: SIMD3<Float>(0, 1, 0), localFront: SIMD3<Float>(0, 0, -1))
        scene.rootNode.addChildNode(camera)
        scene.rootNode.addChildNode(light(.directional, intensity: 900, angles: SIMD3<Float>(-0.9, 0.6, 0)))
        scene.rootNode.addChildNode(light(.ambient, intensity: 550, angles: .zero))
        return scene
    }

    static func light(_ type: SCNLight.LightType, intensity: CGFloat, angles: SIMD3<Float>) -> SCNNode {
        let node = SCNNode()
        node.light = SCNLight()
        node.light?.type = type
        node.light?.intensity = intensity
        node.simdEulerAngles = angles
        return node
    }

    // MARK: Pieces

    private static func vector(_ values: [Double]?) -> SIMD3<Float> {
        guard let values, values.count == 3 else { return .zero }
        return SIMD3<Float>(Float(values[0]), Float(values[1]), Float(values[2]))
    }

    /// Turns about x, then y, then z, in degrees.
    private static func rotation(_ degrees: [Double]?) -> simd_quatf {
        let r = vector(degrees) * (.pi / 180)
        return simd_quatf(angle: r.z, axis: SIMD3<Float>(0, 0, 1)) * simd_quatf(angle: r.y, axis: SIMD3<Float>(0, 1, 0))
            * simd_quatf(angle: r.x, axis: SIMD3<Float>(1, 0, 0))
    }

    private static func makeMaterial(_ hex: String) -> SCNMaterial {
        let c = Hex.components(hex) ?? (red: 1, green: 0, blue: 1, alpha: 1)
        let material = SCNMaterial()
        material.diffuse.contents = UIColor(red: c.red, green: c.green, blue: c.blue, alpha: 1)
        material.specular.contents = UIColor(white: 0.25, alpha: 1)
        material.lightingModel = .blinn
        material.transparency = c.alpha
        material.isDoubleSided = true
        return material
    }

    private static func shapeNode(_ part: AircraftSpec.Part, material: SCNMaterial) -> SCNNode {
        let size = vector(part.size)
        let node = SCNNode()
        switch part.shape {
        case "box":
            let radius = max(0, min(CGFloat(part.radius ?? 0), CGFloat(min(size.x, size.y, size.z)) / 2))
            node.geometry = SCNBox(width: CGFloat(size.x), height: CGFloat(size.y), length: CGFloat(size.z), chamferRadius: radius)
        case "sphere":
            let sphere = SCNSphere(radius: 0.5)
            sphere.segmentCount = 20
            node.geometry = sphere
            node.simdScale = size
        case "cylinder", "cone":
            // SceneKit's cone stands up; lay it along the aircraft with its top to the front
            let taper = CGFloat(min(max(part.taper ?? (part.shape == "cone" ? 0 : 1), 0), 1))
            let cone = SCNCone(topRadius: 0.5 * taper, bottomRadius: 0.5, height: 1)
            cone.radialSegmentCount = 20
            let lying = SCNNode(geometry: cone)
            lying.simdEulerAngles = SIMD3<Float>(0, 0, -.pi / 2)
            lying.geometry?.materials = [material]
            node.simdScale = size
            node.addChildNode(lying)
            return node
        default:
            node.geometry = slab(part, size: size, upright: part.shape == "fin")
        }
        node.geometry?.materials = [material]
        return node
    }

    /// A wing (reaching out along z) or a fin (reaching up along y): a flat slab that can narrow, sweep back and rise
    /// towards its tip.
    private static func slab(_ part: AircraftSpec.Part, size: SIMD3<Float>, upright: Bool) -> SCNGeometry {
        let chord = size.x
        let reach = upright ? size.y : size.z
        let thickness = upright ? size.z : size.y
        let taper = Float(min(max(part.taper ?? 1, 0.02), 3))
        let sweep = Float(part.sweep ?? 0), rise = Float(part.dihedral ?? 0)
        let tipThickness = thickness * max(min(taper, 1), 0.4)

        func corner(_ atTip: Bool, _ front: Float, _ top: Float) -> SIMD3<Float> {
            let tipX: Float = -sweep + front * chord * taper / 2, tipY: Float = rise + top * tipThickness / 2
            let rootX: Float = front * chord / 2, rootY: Float = top * thickness / 2
            let point = atTip ? SIMD3<Float>(tipX, tipY, reach) : SIMD3<Float>(rootX, rootY, 0)
            return upright ? SIMD3<Float>(point.x, point.z, point.y) : point
        }
        let quads: [[SIMD3<Float>]] = [
            [corner(false, 1, 1), corner(false, -1, 1), corner(true, -1, 1), corner(true, 1, 1)],       // top
            [corner(false, 1, -1), corner(true, 1, -1), corner(true, -1, -1), corner(false, -1, -1)],   // bottom
            [corner(false, 1, 1), corner(true, 1, 1), corner(true, 1, -1), corner(false, 1, -1)],       // front edge
            [corner(false, -1, 1), corner(false, -1, -1), corner(true, -1, -1), corner(true, -1, 1)],   // back edge
            [corner(false, 1, 1), corner(false, 1, -1), corner(false, -1, -1), corner(false, -1, 1)],   // root
            [corner(true, 1, 1), corner(true, -1, 1), corner(true, -1, -1), corner(true, 1, -1)],       // tip
        ]
        return Mesh.geometry(quads: quads)
    }
}

/// Flat-sided shapes from corner points.
enum Mesh {
    static func geometry(quads: [[SIMD3<Float>]]) -> SCNGeometry {
        var vertices: [SCNVector3] = [], normals: [SCNVector3] = []
        var indices: [UInt32] = []
        for quad in quads where quad.count == 4 {
            let normal = simd_normalize(simd_cross(quad[1] - quad[0], quad[3] - quad[0]))
            let base = UInt32(vertices.count)
            for point in quad {
                vertices.append(SCNVector3(point))
                normals.append(SCNVector3(normal))
            }
            indices += [base, base + 1, base + 2, base, base + 2, base + 3]
        }
        return SCNGeometry(
            sources: [SCNGeometrySource(vertices: vertices), SCNGeometrySource(normals: normals)],
            elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
    }
}
