import Foundation

// The simulation only uses +, -, *, / and squareRoot() on Doubles: those are exactly rounded (IEEE 754) on every
// device, so the same commands give the same game everywhere (needed for lockstep multiplayer). No sin/cos/atan2/pow
// in Sim/; the renderer may use them freely.

struct Vec2: Equatable, Hashable, Codable {
    var x: Double
    var y: Double

    static let zero = Vec2(x: 0, y: 0)

    static func + (a: Vec2, b: Vec2) -> Vec2 { Vec2(x: a.x + b.x, y: a.y + b.y) }
    static func - (a: Vec2, b: Vec2) -> Vec2 { Vec2(x: a.x - b.x, y: a.y - b.y) }
    static func * (a: Vec2, s: Double) -> Vec2 { Vec2(x: a.x * s, y: a.y * s) }
    static func / (a: Vec2, s: Double) -> Vec2 { Vec2(x: a.x / s, y: a.y / s) }
    static func += (a: inout Vec2, b: Vec2) { a = a + b }
    static func -= (a: inout Vec2, b: Vec2) { a = a - b }

    var lengthSq: Double { x * x + y * y }
    var length: Double { lengthSq.squareRoot() }
    func normalized() -> Vec2 {
        let l = length
        return l > 1e-9 ? self / l : .zero
    }
    func dist(_ o: Vec2) -> Double { (self - o).length }
    func distSq(_ o: Vec2) -> Double { (self - o).lengthSq }
    func dot(_ o: Vec2) -> Double { x * o.x + y * o.y }
    /// Rotated 90° counter-clockwise.
    var perp: Vec2 { Vec2(x: -y, y: x) }
    func clampedLength(_ maxLen: Double) -> Vec2 {
        let l = length
        return l > maxLen && l > 0 ? self * (maxLen / l) : self
    }
}

extension Vec2 {
    init(_ x: Double, _ y: Double) { self.init(x: x, y: y) }
}

/// SplitMix64: small, fast, and identical on every platform.
struct Rng: Codable {
    var state: UInt64

    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// 0 ..< 1
    mutating func unit() -> Double { Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0) }
    /// 0 ..< n
    mutating func int(_ n: Int) -> Int { n <= 1 ? 0 : Int(next() % UInt64(n)) }
    mutating func range(_ lo: Double, _ hi: Double) -> Double { lo + (hi - lo) * unit() }
    mutating func chance(_ p: Double) -> Bool { unit() < p }
}

/// FNV-1a, used for the per-tick state checksum that multiplayer peers compare.
struct Hasher64 {
    private(set) var value: UInt64 = 0xCBF2_9CE4_8422_2325

    mutating func add(_ v: UInt64) {
        var x = v
        for _ in 0..<8 {
            value ^= x & 0xFF
            value = value &* 0x100_0000_01B3
            x >>= 8
        }
    }
    mutating func add(_ v: Int) { add(UInt64(bitPattern: Int64(v))) }
    mutating func add(_ v: Double) { add(v.bitPattern) }
    mutating func add(_ v: Bool) { add(v ? 1 : 0) }
    mutating func add(_ v: Vec2) { add(v.x); add(v.y) }
}
