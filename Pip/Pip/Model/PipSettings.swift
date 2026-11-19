import CoreGraphics
import Foundation

/// How the photos are laid out in the floating window.
struct PipSettings: Codable, Equatable {
    enum Arrangement: String, Codable, CaseIterable, Identifiable {
        case grid, inset
        var id: String { rawValue }
        var title: String { self == .grid ? "Grid" : "One large, others inset" }
    }

    enum Shape: String, Codable, CaseIterable, Identifiable {
        case wide, classic, square, tall, phone, photo
        var id: String { rawValue }
        var title: String {
            switch self {
            case .wide: return "Wide (16:9)"
            case .classic: return "Classic (4:3)"
            case .square: return "Square"
            case .tall: return "Tall (3:4)"
            case .phone: return "Phone (9:16)"
            case .photo: return "Same as first photo"
            }
        }
    }

    static let perPageChoices = [1, 2, 3, 4, 6, 9]

    /// Photos shown at the same time.
    var perPage = 1
    var arrangement: Arrangement = .grid
    var shape: Shape = .classic
    /// Crop each photo to fill its frame, rather than showing all of it with bars.
    var fill = true
    /// Move to the next photos by itself.
    var autoAdvance = true
    var seconds = 5
    /// Open the floating window when the app is left.
    var startOnLeave = true

    private static let key = "settings"

    static func load() -> PipSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let saved = try? JSONDecoder().decode(PipSettings.self, from: data) else { return PipSettings() }
        return saved
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    /// Width divided by height of the window.
    func aspect(firstPhoto: CGFloat?) -> CGFloat {
        switch shape {
        case .wide: return 16.0 / 9.0
        case .classic: return 4.0 / 3.0
        case .square: return 1
        case .tall: return 3.0 / 4.0
        case .phone: return 9.0 / 16.0
        case .photo: return min(max(firstPhoto ?? 4.0 / 3.0, 9.0 / 16.0), 16.0 / 9.0)
        }
    }

    /// Pixel size of the frames drawn for the window (even numbers, longest edge 1280).
    func canvas(firstPhoto: CGFloat?) -> (width: Int, height: Int) {
        let ratio = aspect(firstPhoto: firstPhoto)
        let long: CGFloat = 1280
        let width = ratio >= 1 ? long : long * ratio
        let height = ratio >= 1 ? long / ratio : long
        return (Int(width / 2) * 2, Int(height / 2) * 2)
    }
}
