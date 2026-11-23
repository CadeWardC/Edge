import SceneKit
import UIKit

/// A hoop to fly through.
struct Ring {
    let node: SCNNode
    let center: SIMD3<Float>
    /// The way to fly through it.
    let direction: SIMD3<Float>
    static let radius: Float = 30
}

/// Puts the island, sea, sky, airports, trees, clouds and rings into a scene.
enum WorldBuilder {
    static let haze = UIColor(red: 0.80, green: 0.89, blue: 0.96, alpha: 1)
    static let zenith = UIColor(red: 0.20, green: 0.50, blue: 0.86, alpha: 1)

    /// Returns the sea, which follows the camera, and the rings.
    static func build(_ scene: SCNScene, terrain: Terrain) -> (sea: SCNNode, rings: [Ring]) {
        scene.background.contents = skyBox()
        scene.fogColor = haze
        scene.fogStartDistance = 5000
        scene.fogEndDistance = 15000
        scene.fogDensityExponent = 1.5

        let root = scene.rootNode
        root.addChildNode(AircraftBuilder.light(.directional, intensity: 950, angles: SIMD3<Float>(-0.95, 0.6, 0)))
        root.addChildNode(AircraftBuilder.light(.ambient, intensity: 520, angles: .zero))
        root.addChildNode(island(terrain))

        let water = SCNPlane(width: 80000, height: 80000)
        water.firstMaterial?.diffuse.contents = UIColor(red: 0.16, green: 0.42, blue: 0.66, alpha: 1)
        water.firstMaterial?.specular.contents = UIColor(white: 0.5, alpha: 1)
        water.firstMaterial?.lightingModel = .blinn
        let sea = SCNNode(geometry: water)
        sea.simdEulerAngles = SIMD3<Float>(-.pi / 2, 0, 0)
        root.addChildNode(sea)

        terrain.airports.forEach { root.addChildNode(airport($0)) }
        root.addChildNode(trees(terrain))
        root.addChildNode(clouds())
        let rings = makeRings(terrain)
        rings.forEach { root.addChildNode($0.node) }
        return (sea, rings)
    }

    // MARK: Land

    private static func island(_ terrain: Terrain) -> SCNNode {
        let side = Terrain.cells + 1
        var vertices: [SCNVector3] = [], normals: [SCNVector3] = []
        var colors: [Float] = []
        vertices.reserveCapacity(side * side)
        normals.reserveCapacity(side * side)
        colors.reserveCapacity(side * side * 4)
        func at(_ row: Int, _ column: Int) -> Float {
            terrain.heights[min(max(row, 0), side - 1) * side + min(max(column, 0), side - 1)]
        }
        for row in 0..<side {
            for column in 0..<side {
                let x = Float(column) * Terrain.spacing - Terrain.half, z = Float(row) * Terrain.spacing - Terrain.half
                let height = at(row, column)
                let normal = simd_normalize(SIMD3<Float>(at(row, column - 1) - at(row, column + 1), 2 * Terrain.spacing, at(row - 1, column) - at(row + 1, column)))
                vertices.append(SCNVector3(x, height, z))
                normals.append(SCNVector3(normal))
                let shade = 0.85 + 0.3 * Terrain.layered(x * 7 + 300, z * 7 - 900)
                var color: SIMD3<Float>
                if height < 4 {
                    color = SIMD3<Float>(0.86, 0.80, 0.58)                      // beach
                } else if normal.y < 0.86 || height > 300 {
                    color = SIMD3<Float>(0.49, 0.46, 0.42)                      // rock
                    if height > 470 { color = SIMD3<Float>(0.95, 0.96, 0.98) }  // snow
                } else {
                    let high = Terrain.smooth(40, 280, height)
                    color = SIMD3<Float>(0.36, 0.60, 0.27) * (1 - high) + SIMD3<Float>(0.24, 0.43, 0.22) * high
                }
                color *= shade
                colors += [color.x, color.y, color.z, 1]
            }
        }
        var indices: [UInt32] = []
        indices.reserveCapacity(Terrain.cells * Terrain.cells * 6)
        for row in 0..<Terrain.cells {
            for column in 0..<Terrain.cells {
                let a = UInt32(row * side + column), b = a + 1, c = a + UInt32(side), d = c + 1
                indices += [a, c, b, b, c, d]
            }
        }
        let colorData = colors.withUnsafeBufferPointer { Data(buffer: $0) }
        let colorSource = SCNGeometrySource(
            data: colorData, semantic: .color, vectorCount: side * side, usesFloatComponents: true, componentsPerVector: 4,
            bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0, dataStride: 4 * MemoryLayout<Float>.size)
        let geometry = SCNGeometry(
            sources: [SCNGeometrySource(vertices: vertices), SCNGeometrySource(normals: normals), colorSource],
            elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
        let material = SCNMaterial()
        material.diffuse.contents = UIColor.white
        material.lightingModel = .lambert
        material.isDoubleSided = true
        geometry.materials = [material]
        return SCNNode(geometry: geometry)
    }

    private static func airport(_ airport: Airport) -> SCNNode {
        let group = SCNNode()
        let thickness = CGFloat(Terrain.runwayThickness)
        let slab = SCNBox(width: CGFloat(airport.length), height: thickness, length: CGFloat(airport.width), chamferRadius: 0)
        let asphalt = flat(UIColor(white: 0.2, alpha: 1))
        let top = SCNMaterial()
        top.diffuse.contents = runwayImage()
        top.diffuse.mipFilter = .linear
        top.lightingModel = .lambert
        slab.materials = [asphalt, asphalt, asphalt, asphalt, top, asphalt]   // front, right, back, left, top, bottom
        let runway = SCNNode(geometry: slab)
        runway.simdPosition = airport.point(along: 0, across: 0, height: Float(thickness) / 2)
        runway.simdOrientation = simd_quatf(angle: airport.heading, axis: SIMD3<Float>(0, 1, 0))
        group.addChildNode(runway)

        func building(_ size: SIMD3<Float>, along: Float, across: Float, color: UIColor) {
            let box = SCNBox(width: CGFloat(size.x), height: CGFloat(size.y), length: CGFloat(size.z), chamferRadius: 0.4)
            box.materials = [flat(color)]
            let node = SCNNode(geometry: box)
            node.simdPosition = airport.point(along: along, across: across, height: size.y / 2)
            node.simdOrientation = simd_quatf(angle: airport.heading, axis: SIMD3<Float>(0, 1, 0))
            group.addChildNode(node)
        }
        building(SIMD3<Float>(42, 13, 30), along: -120, across: 130, color: UIColor(red: 0.78, green: 0.80, blue: 0.83, alpha: 1))
        building(SIMD3<Float>(42, 13, 30), along: -60, across: 130, color: UIColor(red: 0.70, green: 0.36, blue: 0.30, alpha: 1))
        building(SIMD3<Float>(9, 28, 9), along: 40, across: 125, color: UIColor(white: 0.9, alpha: 1))
        building(SIMD3<Float>(14, 5, 14), along: 40, across: 125, color: UIColor(red: 0.2, green: 0.3, blue: 0.4, alpha: 1))
        group.childNodes.last?.simdPosition.y += 27
        return group
    }

    /// Asphalt with edge lines, a dashed centre line and bars at each end, seen from above.
    private static func runwayImage() -> UIImage {
        let size = CGSize(width: 2048, height: 128)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            let context = renderer.cgContext
            context.setFillColor(UIColor(white: 0.23, alpha: 1).cgColor)
            context.fill(CGRect(origin: .zero, size: size))
            context.setFillColor(UIColor(white: 0.93, alpha: 1).cgColor)
            context.fill(CGRect(x: 0, y: 5, width: size.width, height: 4))
            context.fill(CGRect(x: 0, y: size.height - 9, width: size.width, height: 4))
            for x in stride(from: CGFloat(190), to: size.width - 220, by: 96) {
                context.fill(CGRect(x: x, y: size.height / 2 - 3, width: 52, height: 6))
            }
            for end in [CGFloat(30), size.width - 110] {
                for bar in 0..<8 {
                    context.fill(CGRect(x: end, y: 18 + CGFloat(bar) * 12.4, width: 80, height: 6))
                }
            }
        }
    }

    private static func flat(_ color: UIColor) -> SCNMaterial {
        let material = SCNMaterial()
        material.diffuse.contents = color
        material.lightingModel = .lambert
        return material
    }

    private static func trees(_ terrain: Terrain) -> SCNNode {
        var scatter = Scatter(seed: 7)
        let cone = SCNCone(topRadius: 0, bottomRadius: 5, height: 18)
        cone.radialSegmentCount = 6
        cone.materials = [flat(UIColor(red: 0.16, green: 0.36, blue: 0.19, alpha: 1))]
        let forest = SCNNode()
        var planted = 0, tries = 0
        while planted < 1600, tries < 20000 {
            tries += 1
            let x = scatter.next(-Terrain.half...Terrain.half), z = scatter.next(-Terrain.half...Terrain.half)
            let height = terrain.height(x, z)
            guard height > 6, height < 290, terrain.normal(x, z).y > 0.9 else { continue }
            // keep the airports and their approaches clear
            let clear = terrain.airports.allSatisfy { airport in
                let place = airport.local(x, z)
                return abs(place.along) > airport.length / 2 + 500 || abs(place.across) > 190
            }
            guard clear else { continue }
            let tree = SCNNode(geometry: cone)
            let scale = scatter.next(0.7...1.4)
            tree.simdScale = SIMD3<Float>(scale, scale, scale)
            tree.simdPosition = SIMD3<Float>(x, height + 9 * scale - 0.5, z)
            forest.addChildNode(tree)
            planted += 1
        }
        return forest.flattenedClone()
    }

    private static func clouds() -> SCNNode {
        var scatter = Scatter(seed: 21)
        let puff = SCNSphere(radius: 1)
        puff.segmentCount = 10
        let white = SCNMaterial()
        white.diffuse.contents = UIColor.white
        white.lightingModel = .constant
        puff.materials = [white]
        let sky = SCNNode()
        for _ in 0..<70 {
            let middle = SIMD3<Float>(scatter.next(-9000...9000), scatter.next(650...1400), scatter.next(-9000...9000))
            for _ in 0..<4 {
                let blob = SCNNode(geometry: puff)
                blob.simdPosition = middle + SIMD3<Float>(scatter.next(-160...160), scatter.next(-20...20), scatter.next(-120...120))
                blob.simdScale = SIMD3<Float>(scatter.next(110...200), scatter.next(35...60), scatter.next(90...160))
                sky.addChildNode(blob)
            }
        }
        return sky.flattenedClone()
    }

    // MARK: Rings

    /// A circuit of hoops from North Field: out along the runway, round over the north coast and back to land.
    private static func makeRings(_ terrain: Terrain) -> [Ring] {
        let home = terrain.airports[0]
        let route: [(along: Float, across: Float, height: Float)] = [
            (1500, 0, 130), (2600, -500, 220), (3000, -1500, 260), (2300, -2500, 260), (800, -2800, 240),
            (-800, -2600, 220), (-2200, -1900, 190), (-2700, -800, 150), (-1900, 0, 100),
        ]
        let centers: [SIMD3<Float>] = route.map { stop in
            var point = home.point(along: stop.along, across: stop.across, height: stop.height)
            point.y = max(point.y, terrain.height(point.x, point.z) + 100)
            return point
        }
        return centers.enumerated().map { index, center in
            let before = index > 0 ? centers[index - 1] : home.point(along: 0, across: 0, height: 60)
            let after = index + 1 < centers.count ? centers[index + 1] : home.point(along: -600, across: 0, height: 0)
            var direction = after - before
            direction.y = 0
            direction = simd_normalize(direction)
            let hoop = SCNTorus(ringRadius: CGFloat(Ring.radius), pipeRadius: 1.8)
            hoop.ringSegmentCount = 36
            let material = SCNMaterial()
            material.lightingModel = .constant
            hoop.materials = [material]
            let node = SCNNode(geometry: hoop)
            node.simdPosition = center
            node.simdOrientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: direction)
            return Ring(node: node, center: center, direction: direction)
        }
    }

    // MARK: Sky

    /// Six pictures that wrap the world: pale at the horizon, deep blue overhead.
    private static func skyBox() -> [UIImage] {
        let size = 48
        var low: (CGFloat, CGFloat, CGFloat) = (0, 0, 0), top: (CGFloat, CGFloat, CGFloat) = (0, 0, 0)
        haze.getRed(&low.0, green: &low.1, blue: &low.2, alpha: nil)
        zenith.getRed(&top.0, green: &top.1, blue: &top.2, alpha: nil)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        // 0 to 3 are the sides, 4 is overhead, 5 is underfoot (SceneKit's order: +x, -x, +y, -y, +z, -z)
        func face(_ kind: Int) -> UIImage {
            UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: format).image { renderer in
                for row in 0..<size {
                    for column in 0..<size {
                        let u = (CGFloat(column) + 0.5) / CGFloat(size) * 2 - 1
                        let v = 1 - (CGFloat(row) + 0.5) / CGFloat(size) * 2
                        let length = (1 + u * u + v * v).squareRoot()
                        let up = kind == 4 ? 1 / length : (kind == 5 ? -1 / length : v / length)
                        let t = pow(max(up, 0), 0.55)
                        UIColor(red: low.0 + (top.0 - low.0) * t, green: low.1 + (top.1 - low.1) * t, blue: low.2 + (top.2 - low.2) * t, alpha: 1).setFill()
                        renderer.fill(CGRect(x: column, y: row, width: 1, height: 1))
                    }
                }
            }
        }
        let side = face(0)
        return [side, side, face(4), face(5), side, side]
    }
}
