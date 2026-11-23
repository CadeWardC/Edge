import CoreGraphics
import Foundation

/// One aircraft, exactly as written in its .json file. See AIRCRAFT.md for what every field means.
struct AircraftSpec: Decodable, Identifiable {
    struct Stats: Decodable {
        /// Forward speed in world units a second (the sky is 400 units tall).
        var speed = 170.0
        /// How fast it gains height. 1 is normal.
        var climb = 1.0
        /// How quickly it answers your finger. 1 is normal.
        var agility = 1.0
        /// Extra distance, in units, from which stars are pulled in.
        var magnet = 0.0

        init() {}

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            speed = try values.decodeIfPresent(Double.self, forKey: .speed) ?? 170
            climb = try values.decodeIfPresent(Double.self, forKey: .climb) ?? 1
            agility = try values.decodeIfPresent(Double.self, forKey: .agility) ?? 1
            magnet = try values.decodeIfPresent(Double.self, forKey: .magnet) ?? 0
        }

        enum CodingKeys: String, CodingKey { case speed, climb, agility, magnet }
    }

    struct Size: Decodable {
        var width: Double
        var height: Double
    }

    /// One coloured shape. Units: x forward (the nose points right), y up, the aircraft about 90 long.
    struct Part: Decodable {
        var shape: String
        var color: String
        var outline: String?
        var x: Double?
        var y: Double?
        var width: Double?
        var height: Double?
        var radius: Double?
        var rotation: Double?
        var points: [[Double]]?
        var smooth: Bool?
        var animation: String?
    }

    var id: String
    var name: String
    /// Which flight model flies it: a key of `FlightModels.all`.
    var type: String
    var description: String?
    /// Stars needed to unlock it. Nothing or 0 means free.
    var price: Int?
    var stats: Stats?
    var hitbox: Size?
    /// Stays level instead of tilting with the climb.
    var level: Bool?
    var trail: String?
    var parts: [Part]

    static let shapes: Set<String> = ["ellipse", "rect", "polygon"]
    static let animations: Set<String> = ["none", "propeller", "rotor", "spin", "blink"]

    var cost: Int { max(price ?? 0, 0) }

    /// Stats kept inside the range the game is playable in.
    var tunedStats: Stats {
        var tuned = stats ?? Stats()
        tuned.speed = min(max(tuned.speed, 80), 320)
        tuned.climb = min(max(tuned.climb, 0.4), 2)
        tuned.agility = min(max(tuned.agility, 0.4), 2.5)
        tuned.magnet = min(max(tuned.magnet, 0), 120)
        return tuned
    }

    /// Says what is wrong with the file in words its author can act on.
    func validate() throws {
        if id.trimmingCharacters(in: .whitespaces).isEmpty { throw SpecError("\"id\" is empty") }
        if name.trimmingCharacters(in: .whitespaces).isEmpty { throw SpecError("\"name\" is empty") }
        if FlightModels.all[type] == nil {
            throw SpecError("\"type\" is \"\(type)\"; it must be one of: \(FlightModels.all.keys.sorted().joined(separator: ", "))")
        }
        if parts.isEmpty { throw SpecError("\"parts\" is empty, so there is nothing to draw") }
        if parts.count > 80 { throw SpecError("more than 80 parts") }
        for (index, part) in parts.enumerated() {
            let place = "part \(index + 1)"
            guard Self.shapes.contains(part.shape) else {
                throw SpecError("\(place): \"shape\" is \"\(part.shape)\"; use ellipse, rect or polygon")
            }
            if Hex.components(part.color) == nil { throw SpecError("\(place): \"color\" should look like #E94F37") }
            if let outline = part.outline, Hex.components(outline) == nil { throw SpecError("\(place): \"outline\" should look like #FFFFFF") }
            if let animation = part.animation, !Self.animations.contains(animation) {
                throw SpecError("\(place): \"animation\" is \"\(animation)\"; use propeller, rotor, spin, blink or none")
            }
            if part.shape == "polygon" {
                guard let points = part.points, points.count >= 3, points.allSatisfy({ $0.count == 2 }) else {
                    throw SpecError("\(place): a polygon needs \"points\" with at least three [x, y] pairs")
                }
            } else {
                guard let width = part.width, let height = part.height, width > 0, height > 0 else {
                    throw SpecError("\(place): needs a \"width\" and \"height\" above 0")
                }
            }
        }
    }
}

struct SpecError: LocalizedError {
    let text: String
    init(_ text: String) { self.text = text }
    var errorDescription: String? { text }
}

/// Reads colours written as #RRGGBB or #RRGGBBAA.
enum Hex {
    static func components(_ text: String) -> (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat)? {
        var digits = text.trimmingCharacters(in: .whitespaces)
        if digits.hasPrefix("#") { digits.removeFirst() }
        guard digits.count == 6 || digits.count == 8, let value = UInt64(digits, radix: 16) else { return nil }
        let rgba = digits.count == 6 ? (value << 8) | 0xFF : value
        return (CGFloat((rgba >> 24) & 0xFF) / 255, CGFloat((rgba >> 16) & 0xFF) / 255, CGFloat((rgba >> 8) & 0xFF) / 255, CGFloat(rgba & 0xFF) / 255)
    }
}
