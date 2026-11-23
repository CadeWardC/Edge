import Foundation
import simd

/// A runway and the flat ground made for it.
struct Airport {
    let name: String
    let center: SIMD2<Float>      // x, z
    /// The way the runway points, as a heading (see `Attitude`): 0 is east, a quarter turn is north.
    let heading: Float
    let elevation: Float
    let length: Float = 1200
    let width: Float = 45

    var axis: SIMD3<Float> { SIMD3<Float>(cos(heading), 0, -sin(heading)) }
    var across: SIMD3<Float> { SIMD3<Float>(sin(heading), 0, cos(heading)) }

    /// A point given as metres along and across the runway from its middle.
    func point(along: Float, across side: Float, height: Float = 0) -> SIMD3<Float> {
        SIMD3<Float>(center.x, elevation + height, center.y) + axis * along + across * side
    }

    /// Metres along and across the runway of a point in the world.
    func local(_ x: Float, _ z: Float) -> (along: Float, across: Float) {
        let d = SIMD3<Float>(x - center.x, 0, z - center.y)
        return (simd_dot(d, axis), simd_dot(d, across))
    }
}

/// What is under a point.
struct Ground {
    var height: Float
    var normal: SIMD3<Float>
    var isWater: Bool
}

/// The island: a grid of heights made from layered noise, sinking into the sea at the edges, with flat ground at the
/// airports. Always the same island. `scripts/terrain.py` draws a map of it.
final class Terrain {
    static let cells = 220
    static let spacing: Float = 60
    static let half = Float(cells) * spacing / 2
    /// The runway is a slab this far above the grass.
    static let runwayThickness: Float = 0.5

    let airports = [
        Airport(name: "North Field", center: SIMD2<Float>(-1740, -2400), heading: 0, elevation: 20),
        Airport(name: "South Strip", center: SIMD2<Float>(-240, 3300), heading: .pi / 2, elevation: 21),
    ]
    private(set) var heights: [Float] = []

    init() {
        let side = Self.cells + 1
        heights = [Float](repeating: 0, count: side * side)
        for row in 0..<side {
            for column in 0..<side {
                let x = Float(column) * Self.spacing - Self.half, z = Float(row) * Self.spacing - Self.half
                heights[row * side + column] = shaped(x, z)
            }
        }
    }

    // MARK: Asking about the ground

    /// Height of the land (below 0 is sea bed), between grid points.
    func height(_ x: Float, _ z: Float) -> Float {
        let gx = (x + Self.half) / Self.spacing, gz = (z + Self.half) / Self.spacing
        guard gx >= 0, gz >= 0, gx < Float(Self.cells), gz < Float(Self.cells) else { return -40 }
        let column = Int(gx), row = Int(gz)
        let fx = gx - Float(column), fz = gz - Float(row)
        let side = Self.cells + 1
        let a = heights[row * side + column], b = heights[row * side + column + 1]
        let c = heights[(row + 1) * side + column], d = heights[(row + 1) * side + column + 1]
        let near: Float = a + (b - a) * fx, far: Float = c + (d - c) * fx
        return near + (far - near) * fz
    }

    func normal(_ x: Float, _ z: Float) -> SIMD3<Float> {
        let step: Float = 30
        let slopeX: Float = height(x - step, z) - height(x + step, z)
        let slopeZ: Float = height(x, z - step) - height(x, z + step)
        return simd_normalize(SIMD3<Float>(slopeX, 2 * step, slopeZ))
    }

    func isOnRunway(_ x: Float, _ z: Float) -> Bool {
        airports.contains { airport in
            let place = airport.local(x, z)
            return abs(place.along) <= airport.length / 2 && abs(place.across) <= airport.width / 2
        }
    }

    /// What an aircraft would land on here: land, a runway, or the sea.
    func ground(_ x: Float, _ z: Float) -> Ground {
        let land = height(x, z)
        if land < 0.3 { return Ground(height: 0, normal: SIMD3<Float>(0, 1, 0), isWater: true) }
        if isOnRunway(x, z) { return Ground(height: land + Self.runwayThickness, normal: SIMD3<Float>(0, 1, 0), isWater: false) }
        return Ground(height: land, normal: normal(x, z), isWater: false)
    }

    // MARK: Making the island

    private func shaped(_ x: Float, _ z: Float) -> Float {
        let rough = Self.layered(x, z)
        let edge = Self.smooth(0.5, 0.95, (x * x + z * z).squareRoot() / Self.half)
        let hills: Float = 18 + 2200 * pow(max(rough - 0.3, 0), 1.9)
        var height: Float = (1 - edge) * hills - 40 * edge
        for airport in airports {
            let place = airport.local(x, z)
            let beyondEnd: Float = max(abs(place.along) - (airport.length / 2 + 200), 0)
            let beyondSide: Float = max(abs(place.across) - 150, 0)
            let outside: Float = (beyondEnd * beyondEnd + beyondSide * beyondSide).squareRoot()
            let blend: Float = Self.smooth(0, 450, outside)
            height = airport.elevation + (height - airport.elevation) * blend
        }
        return height
    }

    /// Five layers of noise, each half the size of the last. 0 to 1. Also used to vary the colours.
    static func layered(_ x: Float, _ z: Float) -> Float {
        var total: Float = 0, weight: Float = 1, length: Float = 2800
        for layer in 0..<5 {
            total += noise(x + 1000 * Float(layer), z - 700 * Float(layer), length) * weight
            weight /= 2
            length /= 2
        }
        return total / 1.9375
    }

    private static func noise(_ x: Float, _ z: Float, _ length: Float) -> Float {
        let gx = x / length, gz = z / length
        let i = gx.rounded(.down), j = gz.rounded(.down)
        let fx = gx - i, fz = gz - j
        let ux = fx * fx * (3 - 2 * fx), uz = fz * fz * (3 - 2 * fz)
        let a = value(Int(i), Int(j)), b = value(Int(i) + 1, Int(j)), c = value(Int(i), Int(j) + 1), d = value(Int(i) + 1, Int(j) + 1)
        let near = a + (b - a) * ux, far = c + (d - c) * ux
        return near + (far - near) * uz
    }

    /// A fixed pseudo-random number, 0 to 1, for each grid corner.
    private static func value(_ i: Int, _ j: Int) -> Float {
        var h = UInt32(truncatingIfNeeded: i) &* 374_761_393 &+ UInt32(truncatingIfNeeded: j) &* 668_265_263 &+ 1_013_904_223
        h = (h ^ (h >> 13)) &* 1_274_126_177
        h ^= h >> 16
        return Float(h) / 4_294_967_296
    }

    static func smooth(_ from: Float, _ to: Float, _ value: Float) -> Float {
        let t = min(max((value - from) / (to - from), 0), 1)
        return t * t * (3 - 2 * t)
    }
}

/// Repeatable random numbers, so the trees and clouds are in the same places every time.
struct Scatter {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> Float {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Float(state >> 40) / Float(1 << 24)
    }

    mutating func next(_ range: ClosedRange<Float>) -> Float {
        range.lowerBound + (range.upperBound - range.lowerBound) * next()
    }
}
