import CoreGraphics
import Foundation

/// The ground. Flat where a flight starts, then rolling hills that grow with distance. Different every flight.
struct Terrain {
    static let skyHeight: CGFloat = 400
    /// Aircraft cannot go above this.
    static let ceiling: CGFloat = 388

    private let phases: [CGFloat]

    init() {
        phases = (0..<3).map { _ in CGFloat.random(in: 0..<(2 * .pi)) }
    }

    func height(at x: CGFloat) -> CGFloat {
        let start = min(max((x - 500) / 2500, 0), 1)
        let ramp = start * start * (3 - 2 * start)
        let growth = min(max(x / 30000, 0), 1)
        func wave(_ length: CGFloat, _ phase: CGFloat) -> CGFloat { 0.5 + 0.5 * sin(x / length + phase) }
        return 36 + ramp * ((50 + 50 * growth) * wave(190, phases[0]) + (20 + 30 * growth) * wave(67, phases[1]) + 14 * wave(23, phases[2]))
    }
}
