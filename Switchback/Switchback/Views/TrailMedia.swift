import Photos
import SwiftUI

/// Swipeable photos at the top of a trail page: Commons photos, then a satellite picture of the route.
struct TrailHero: View {
    let trail: Trail
    let photos: [TrailPhoto]
    @State private var satellite: UIImage?
    @State private var page = 0

    var body: some View {
        TabView(selection: $page) {
            ForEach(Array(photos.enumerated()), id: \.element.id) { i, p in
                ZStack(alignment: .bottomLeading) {
                    AsyncImage(url: p.thumb, transaction: Transaction(animation: .easeIn(duration: 0.2))) { phase in
                        switch phase {
                        case .success(let img):
                            img.resizable().scaledToFill()
                        case .failure:
                            Color.secondary.opacity(0.15).overlay(Image(systemName: "photo").foregroundStyle(.secondary))
                        default:
                            Color.secondary.opacity(0.12).overlay(ProgressView())
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    credit(p)
                }
                .tag(i)
            }
            satelliteView.tag(photos.count)
        }
        .tabViewStyle(.page(indexDisplayMode: photos.isEmpty ? .never : .automatic))
        .frame(height: 250)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .task(id: trail.id) {
            satellite = await Snapshots.shared.image(for: trail, size: CGSize(width: 900, height: 560))
        }
    }

    private var satelliteView: some View {
        ZStack(alignment: .bottomLeading) {
            if let satellite {
                Image(uiImage: satellite).resizable().scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            } else {
                Color.secondary.opacity(0.12).overlay(ProgressView())
            }
            Text("Satellite · Apple Maps")
                .font(.caption2)
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.black.opacity(0.45), in: Capsule())
                .padding(8)
        }
    }

    @ViewBuilder
    private func credit(_ p: TrailPhoto) -> some View {
        let text = p.credit.isEmpty ? "Wikimedia Commons" : p.credit
        Group {
            if let url = p.page {
                Link(destination: url) { Label(text, systemImage: "info.circle") }
            } else {
                Text(text)
            }
        }
        .font(.caption2)
        .lineLimit(1)
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.black.opacity(0.45), in: Capsule())
        .padding(8)
        .padding(.bottom, photos.count > 0 ? 18 : 0)
    }
}

/// One line summing up a trail's sights, e.g. "2 viewpoints · waterfall · water at 3.1 mi".
func highlightSummary(_ pois: [TrailPOI]) -> String? {
    var parts: [String] = []
    for kind in [POIKind.peak, .viewpoint, .waterfall, .lake, .cave] {
        let n = pois.filter { $0.kind == kind }.count
        if n == 1 { parts.append(kind.title.lowercased()) }
        if n > 1 { parts.append("\(n) \(kind.title.lowercased())s") }
    }
    if let water = pois.first(where: { $0.kind == .water }) {
        parts.append("water at \(Fmt.distance(water.along))")
    }
    guard !parts.isEmpty else { return nil }
    let s = parts.joined(separator: " · ")
    return s.prefix(1).uppercased() + s.dropFirst()
}

/// The highlights along a trail, in order.
struct HighlightsList: View {
    let pois: [TrailPOI]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(pois) { p in
                HStack(spacing: 12) {
                    Image(systemName: p.kind.symbol)
                        .font(.subheadline)
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(Color(p.kind.mapColor), in: Circle())
                    VStack(alignment: .leading, spacing: 1) {
                        Text(p.displayName).font(.subheadline.weight(.semibold))
                        Text(detail(p)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(p.kind == .parking ? "Trailhead" : Fmt.distance(p.along))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func detail(_ p: TrailPOI) -> String {
        var parts = [p.name == nil ? "" : p.kind.title]
        if let e = p.elevation { parts.append(Fmt.elevation(e)) }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// Your photos from a hike, in a strip; tap one to see it full screen.
struct HikePhotoStrip: View {
    let photos: [HikePhoto]
    let thumbs: [String: UIImage]
    @State private var shown: HikePhoto?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(photos) { p in
                    Button { shown = p } label: {
                        Group {
                            if let img = thumbs[p.id] {
                                Image(uiImage: img).resizable().scaledToFill()
                            } else {
                                Color.secondary.opacity(0.15)
                            }
                        }
                        .frame(width: 96, height: 96)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .fullScreenCover(item: $shown) { p in FullPhoto(photo: p) }
    }
}

private struct FullPhoto: View {
    let photo: HikePhoto
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                ProgressView().tint(.white)
            }
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill").font(.title).foregroundStyle(.white.opacity(0.85))
            }
            .padding()
        }
        .task {
            image = await HikePhotos.image(photo.asset, size: CGSize(width: 2000, height: 2000))
        }
    }
}
