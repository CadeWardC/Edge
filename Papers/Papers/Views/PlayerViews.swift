import SwiftUI

/// The player for one item: scrubber, chapter name, ±15 s, play/pause, chapter skip and speed.
struct PlayerCard: View {
    let id: PlayableID
    /// The saved length and position, shown before the item is loaded.
    let duration: Double
    let savedPosition: Double
    @EnvironmentObject private var player: SummaryPlayer
    @State private var scrubbing: Double?

    private var isLoaded: Bool { player.item == id }
    private var position: Double { scrubbing ?? (isLoaded ? player.position : savedPosition) }
    private var total: Double { max(isLoaded ? player.duration : duration, 1) }

    var body: some View {
        VStack(spacing: 12) {
            Slider(value: Binding(get: { min(position, total) }, set: { scrubbing = $0 }), in: 0...total,
                   onEditingChanged: { editing in
                if !editing, let s = scrubbing {
                    player.load(id)
                    player.seek(to: s)
                    scrubbing = nil
                }
            })
            HStack {
                Text(Paper.format(position))
                Spacer()
                if isLoaded, let i = player.currentChapterIndex {
                    Text(player.chapters[i].title).lineLimit(1).foregroundStyle(.secondary)
                    Spacer()
                }
                Text("-" + Paper.format(max(total - position, 0)))
            }
            .font(.caption.monospacedDigit())

            HStack(spacing: 28) {
                if isLoaded && !player.chapters.isEmpty {
                    Button { player.previousChapter() } label: { Image(systemName: "backward.end.fill").font(.title3) }
                }
                Button { player.load(id); player.skip(-15) } label: { Image(systemName: "gobackward.15").font(.title) }
                Button {
                    if isLoaded { player.toggle() } else { player.play(id) }
                } label: {
                    Image(systemName: isLoaded && player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 60))
                }
                Button { player.load(id); player.skip(15) } label: { Image(systemName: "goforward.15").font(.title) }
                if isLoaded && !player.chapters.isEmpty {
                    Button { player.nextChapter() } label: { Image(systemName: "forward.end.fill").font(.title3) }
                }
            }

            Menu {
                Picker("Speed", selection: $player.speed) {
                    ForEach(SummaryPlayer.speeds, id: \.self) { s in
                        Text(Self.speedLabel(s)).tag(s)
                    }
                }
            } label: {
                Label(Self.speedLabel(player.speed), systemImage: "speedometer").font(.subheadline)
            }
        }
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    static func speedLabel(_ s: Float) -> String {
        s == s.rounded() ? String(format: "%.0f×", s) : String(format: s * 10 == (s * 10).rounded() ? "%.1f×" : "%.2f×", s)
    }
}

/// A small bar above the tab bar for whatever is playing.
struct MiniPlayer: View {
    @EnvironmentObject private var player: SummaryPlayer

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(player.title).font(.subheadline.bold()).lineLimit(1)
                Text("\(player.subtitle) · \(Paper.format(player.position)) / \(Paper.format(player.duration))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button { player.skip(-15) } label: { Image(systemName: "gobackward.15") }
            Button { player.toggle() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.title2)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
    }
}
