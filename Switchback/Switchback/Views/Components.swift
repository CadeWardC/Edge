import Charts
import SwiftUI

struct DifficultyBadge: View {
    let difficulty: Difficulty

    var body: some View {
        Text(difficulty.title)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .foregroundStyle(difficulty.color)
            .background(difficulty.color.opacity(0.14), in: Capsule())
    }
}

/// The trail's shape, drawn small.
struct TrailThumbnail: View {
    let trail: Trail
    var size: CGFloat = 64
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            } else {
                drawing
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .task(id: trail.id) {
            let px = CGSize(width: size * 2, height: size * 2)
            if let cached = Snapshots.shared.cached(for: trail, size: px) {
                image = cached
                return
            }
            if let img = await Snapshots.shared.image(for: trail, size: px), !Task.isCancelled {
                withAnimation(.easeIn(duration: 0.2)) { image = img }
            }
        }
    }

    /// The trail's shape, drawn while the satellite picture loads (or without signal).
    private var drawing: some View {
        Canvas { ctx, canvas in
            let b = trail.bbox
            let k = cos(b.center.lat * .pi / 180)
            let w = max(b.lonSpan * k, 1e-9), h = max(b.latSpan, 1e-9)
            let cw = Double(canvas.width), ch = Double(canvas.height)
            let inset = 8.0
            let scale: Double = min((cw - 2 * inset) / w, (ch - 2 * inset) / h)
            let ox: Double = (cw - w * scale) / 2
            let oy: Double = (ch - h * scale) / 2
            var path = Path()
            for seg in trail.segments {
                for (i, c) in seg.enumerated() {
                    let pt = CGPoint(x: ox + (c.lon - b.west) * k * scale, y: oy + (b.north - c.lat) * scale)
                    if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
                }
            }
            ctx.stroke(path, with: .color(.trailGreen), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
            let s = trail.start
            let sp = CGPoint(x: ox + (s.lon - b.west) * k * scale, y: oy + (b.north - s.lat) * scale)
            ctx.fill(Path(ellipseIn: CGRect(x: sp.x - 3.5, y: sp.y - 3.5, width: 7, height: 7)), with: .color(.orange))
        }
        .background(Color.trailGreen.opacity(0.10))
    }
}

struct TrailRow: View {
    let trail: Trail
    var distanceAway: Double? = nil

    var body: some View {
        HStack(spacing: 12) {
            TrailThumbnail(trail: trail)
            VStack(alignment: .leading, spacing: 4) {
                Text(trail.name)
                    .font(.headline)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    DifficultyBadge(difficulty: trail.difficulty)
                    Text(trail.routeTypeTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(stats)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                if let d = distanceAway {
                    Text("\(Fmt.distance(d)) away" + (trail.area.map { " · \($0)" } ?? ""))
                        .lineLimit(1)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    private var stats: String {
        var parts = [Fmt.distance(trail.length)]
        if let g = trail.profile?.gain { parts.append("↑ " + Fmt.elevation(g)) }
        parts.append("~" + Fmt.duration(trail.estimatedDuration))
        return parts.joined(separator: " · ")
    }
}

struct StatTile: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline.monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ElevationChart: View {
    let profile: ElevationProfile
    /// Where you are along the trail (metres), drawn as a dot.
    var marker: Double? = nil
    var height: CGFloat = 190
    @State private var selectedX: Double?

    /// The height of the profile at a distance along it.
    static func elevation(at d: Double, in p: ElevationProfile) -> Double? {
        guard let i = p.distances.firstIndex(where: { $0 >= d }) else { return p.elevations.last }
        guard i > 0 else { return p.elevations.first }
        let d0 = p.distances[i - 1], d1 = p.distances[i]
        let t = d1 > d0 ? (d - d0) / (d1 - d0) : 0
        return p.elevations[i - 1] + (p.elevations[i] - p.elevations[i - 1]) * t
    }

    private struct Point: Identifiable {
        let id: Int
        let x: Double
        let y: Double
    }

    private var points: [Point] {
        zip(profile.distances, profile.elevations).enumerated().map { i, p in
            Point(id: i, x: Fmt.displayDistance(p.0), y: Fmt.displayElevation(p.1))
        }
    }

    var body: some View {
        let pts = points
        let lo = Fmt.displayElevation(profile.minElevation)
        let hi = Fmt.displayElevation(profile.maxElevation)
        let pad = max(10, (hi - lo) * 0.15)
        let yMin = max(-500, (lo - pad).rounded(.down))
        let yMax = (hi + pad).rounded(.up)
        let selected = selectedX.flatMap { x in pts.min(by: { abs($0.x - x) < abs($1.x - x) }) }

        Chart {
            ForEach(pts) { p in
                AreaMark(x: .value("Distance", p.x), yStart: .value("Base", yMin), yEnd: .value("Elevation", p.y))
                    .foregroundStyle(LinearGradient(colors: [Color.trailGreen.opacity(0.45), Color.trailGreen.opacity(0.05)],
                                                    startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Distance", p.x), y: .value("Elevation", p.y))
                    .foregroundStyle(Color.trailGreen)
                    .lineStyle(StrokeStyle(lineWidth: 2))
            }
            if let m = marker, let e = ElevationChart.elevation(at: m, in: profile) {
                PointMark(x: .value("You", Fmt.displayDistance(m)), y: .value("Elevation", Fmt.displayElevation(e)))
                    .foregroundStyle(Color.blue)
                    .symbolSize(140)
            }
            if let s = selected {
                RuleMark(x: .value("Selected", s.x))
                    .foregroundStyle(.secondary)
                    .annotation(position: .top) {
                        Text(String(format: "%.1f %@ · %d %@", s.x, Fmt.distanceUnit, Int(s.y), Fmt.elevationUnit))
                            .font(.caption2.monospacedDigit())
                            .padding(4)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 4))
                    }
            }
        }
        .chartYScale(domain: yMin...max(yMax, yMin + 20))
        .chartXAxisLabel(Fmt.distanceUnit)
        .chartYAxisLabel(Fmt.elevationUnit)
        .chartXSelection(value: $selectedX)
        .frame(height: height)
    }
}
