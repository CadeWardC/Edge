import CoreGraphics
import Foundation

/// One aircraft, exactly as written in its .json file. "How to make aircraft.txt" explains every field.
///
/// Axes, in metres from the middle of the aircraft: x forward (the nose), y up, z out along the right wing.
struct AircraftSpec: Decodable, Identifiable {
    /// How it flies. Everything is optional; each flight model reads what it needs.
    struct Flight: Decodable {
        /// Planes: the speed, in knots, below which the wing stops flying.
        var stallSpeed: Double?
        /// The fastest it flies level, in knots.
        var topSpeed: Double?
        /// Planes: engine thrust as a share of weight. Helicopters: the most the rotor lifts, as a multiple of weight.
        var power: Double?
        /// Planes: degrees a second at full stick.
        var rollRate: Double?
        var pitchRate: Double?
        var yawRate: Double?
        /// Helicopters: how briskly it leans where the stick points. 1 is normal.
        var agility: Double?
    }

    struct Part: Decodable {
        var shape: String
        var color: String
        var size: [Double]
        var position: [Double]?
        var rotation: [Double]?
        var taper: Double?
        var sweep: Double?
        var dihedral: Double?
        var radius: Double?
        var mirror: Bool?
        var spin: String?
    }

    var id: String
    var name: String
    /// Which flight model flies it: a key of `FlightModels.all`.
    var type: String
    var description: String?
    var flight: Flight?
    /// Where the pilot's eyes are, for the cockpit view.
    var cockpit: [Double]?
    var parts: [Part]

    static let shapes: Set<String> = ["box", "sphere", "cylinder", "cone", "wing", "fin"]
    static let spins: Set<String> = ["none", "propeller", "rotor", "tailrotor"]

    /// Says what is wrong with the file in words its author can act on.
    func validate() throws {
        if id.trimmingCharacters(in: .whitespaces).isEmpty { throw SpecError("\"id\" is empty") }
        if name.trimmingCharacters(in: .whitespaces).isEmpty { throw SpecError("\"name\" is empty") }
        if FlightModels.all[type] == nil {
            throw SpecError("\"type\" is \"\(type)\"; it must be one of: \(FlightModels.all.keys.sorted().joined(separator: ", "))")
        }
        if let cockpit, cockpit.count != 3 { throw SpecError("\"cockpit\" needs three numbers: [x, y, z]") }
        if parts.isEmpty { throw SpecError("\"parts\" is empty, so there is nothing to draw") }
        if parts.count > 150 { throw SpecError("more than 150 parts") }
        for (index, part) in parts.enumerated() {
            let place = "part \(index + 1)"
            guard Self.shapes.contains(part.shape) else {
                throw SpecError("\(place): \"shape\" is \"\(part.shape)\"; use box, sphere, cylinder, cone, wing or fin")
            }
            if Hex.components(part.color) == nil { throw SpecError("\(place): \"color\" should look like #E94F37") }
            guard part.size.count == 3, part.size.allSatisfy({ $0 > 0 && $0 < 200 }) else {
                throw SpecError("\(place): \"size\" needs three numbers above 0: [length, height, width]")
            }
            if let position = part.position, position.count != 3 { throw SpecError("\(place): \"position\" needs three numbers: [x, y, z]") }
            if let rotation = part.rotation, rotation.count != 3 { throw SpecError("\(place): \"rotation\" needs three numbers: [x, y, z]") }
            if let spin = part.spin, !Self.spins.contains(spin) {
                throw SpecError("\(place): \"spin\" is \"\(spin)\"; use propeller, rotor, tailrotor or none")
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
