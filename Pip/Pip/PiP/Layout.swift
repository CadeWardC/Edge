import CoreGraphics
import Foundation

/// Where each photo goes on the canvas. Rectangles have their origin at the top left.
enum Layout {
    static func rects(count: Int, size: CGSize, arrangement: PipSettings.Arrangement) -> [CGRect] {
        guard count > 0 else { return [] }
        if count == 1 { return [CGRect(origin: .zero, size: size)] }
        return arrangement == .grid ? grid(count: count, size: size) : inset(count: count, size: size)
    }

    /// Rows of equal height. The column count is the one whose cells come out closest to square; a short last row is
    /// stretched to the full width.
    private static func grid(count: Int, size: CGSize) -> [CGRect] {
        let gap: CGFloat = 6
        var columns = 1
        var best = Double.infinity
        for candidate in 1...count {
            let rows = Int(ceil(Double(count) / Double(candidate)))
            let cell = (size.width / CGFloat(candidate)) / (size.height / CGFloat(rows))
            let score = abs(log(Double(cell))) + 0.35 * Double(candidate * rows - count)
            if score < best - 1e-9 {
                best = score
                columns = candidate
            }
        }
        let rows = Int(ceil(Double(count) / Double(columns)))
        let rowHeight = (size.height - gap * CGFloat(rows - 1)) / CGFloat(rows)
        var rects: [CGRect] = []
        for row in 0..<rows {
            let items = row == rows - 1 ? count - columns * (rows - 1) : columns
            let width = (size.width - gap * CGFloat(items - 1)) / CGFloat(items)
            for column in 0..<items {
                rects.append(CGRect(x: CGFloat(column) * (width + gap), y: CGFloat(row) * (rowHeight + gap), width: width, height: rowHeight))
            }
        }
        return rects
    }

    /// The first photo covers the canvas; the others are small squares along the bottom, from the right.
    private static func inset(count: Int, size: CGSize) -> [CGRect] {
        let small = count - 1
        let margin = min(size.width, size.height) * 0.035
        let side = min(min(size.width, size.height) * 0.3, (size.width - margin * CGFloat(small + 1)) / CGFloat(small))
        var rects = [CGRect(origin: .zero, size: size)]
        for index in 0..<small {
            let fromRight = CGFloat(small - index)
            rects.append(CGRect(x: size.width - fromRight * (side + margin), y: size.height - margin - side, width: side, height: side))
        }
        return rects
    }
}
