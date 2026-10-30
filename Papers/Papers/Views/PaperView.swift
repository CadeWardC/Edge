import PDFKit
import SwiftUI

struct PaperView: View {
    let id: UUID
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var queue: SummaryQueue
    @EnvironmentObject private var player: SummaryPlayer
    @Environment(\.dismiss) private var dismiss
    @State private var showPDF = false
    @State private var confirmDelete = false

    var body: some View {
        Group {
            if let paper = library.paper(id) {
                content(paper)
            } else {
                ContentUnavailableView("This paper was removed", systemImage: "doc")
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showPDF) {
            NavigationStack {
                PDFKitView(url: Library.pdfURL(id))
                    .ignoresSafeArea(edges: .bottom)
                    .navigationTitle("PDF")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { Button("Done") { showPDF = false } }
            }
        }
        .confirmationDialog("Delete this paper and its summary?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                player.unload(id)
                queue.delete(id)
                dismiss()
            }
        }
    }

    @ViewBuilder private func content(_ paper: Paper) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(paper.displayTitle)
                    .font(.title2.bold())
                    .textSelection(.enabled)

                switch paper.stage {
                case .ready:
                    PlayerCard(paper: paper)
                case .failed:
                    failedCard(paper)
                default:
                    progressCard(paper)
                }

                ForEach(Array(paper.sections.enumerated()), id: \.element.id) { index, section in
                    SectionCard(paper: paper, index: index, section: section)
                }
            }
            .padding()
        }
        .onAppear {
            if paper.stage == .ready { player.load(paper) }
        }
        .onChange(of: paper.stage) { _, stage in
            if stage == .ready, let p = library.paper(id) { player.load(p) }
        }
        .toolbar {
            Menu {
                Button { showPDF = true } label: { Label("View PDF", systemImage: "doc.text") }
                if paper.stage == .ready {
                    ShareLink(item: Library.audioURL(id)) { Label("Share audio", systemImage: "square.and.arrow.up") }
                }
                if !paper.isWorking {
                    if paper.sections.count == SectionKind.allCases.count {
                        Button {
                            player.unload(id)
                            queue.regenerate(id, scriptToo: false)
                        } label: {
                            Label("Record again with \(NarratorVoice.current.label)", systemImage: "waveform")
                        }
                    }
                    Button {
                        player.unload(id)
                        queue.regenerate(id, scriptToo: true)
                    } label: {
                        Label("Make a new summary", systemImage: "arrow.clockwise")
                    }
                }
                Button(role: .destructive) { confirmDelete = true } label: { Label("Delete", systemImage: "trash") }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    private func progressCard(_ paper: Paper) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ProgressView(value: paper.overallProgress)
            Text(queue.currentID == paper.id ? paper.statusText : (queue.isRunning ? "Waiting for the paper before it" : "Waiting"))
                .font(.subheadline)
            Text("This runs entirely on your iPhone and takes several minutes. You can leave the app: it keeps going in the background, and you'll get a notification when the audio is ready.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !queue.isRunning {
                Button("Start") { queue.start() }
                    .buttonStyle(.bordered)
            }
        }
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func failedCard(_ paper: Paper) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("The summary could not be made", systemImage: "exclamationmark.triangle")
                .font(.headline)
            Text(paper.error ?? "Unknown error")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button("Try again") { queue.retry(paper.id) }
                .buttonStyle(.borderedProminent)
        }
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

struct PlayerCard: View {
    let paper: Paper
    @EnvironmentObject private var player: SummaryPlayer
    @State private var scrubbing: Double?

    private var isLoaded: Bool { player.paperID == paper.id }
    private var position: Double { scrubbing ?? (isLoaded ? player.position : paper.playbackPosition) }
    private var duration: Double { max(paper.duration ?? 0, 1) }

    var body: some View {
        VStack(spacing: 14) {
            Slider(value: Binding(get: { position }, set: { scrubbing = $0 }), in: 0...duration, onEditingChanged: { editing in
                if !editing, let s = scrubbing {
                    player.load(paper)
                    player.seek(to: s)
                    scrubbing = nil
                }
            })
            HStack {
                Text(Paper.format(position))
                Spacer()
                Text(currentChapter.map { paper.sections.indices.contains($0) ? paper.sections[$0].kind.heading : "" } ?? "")
                    .foregroundStyle(.secondary)
                Spacer()
                Text("-" + Paper.format(max(duration - position, 0)))
            }
            .font(.caption.monospacedDigit())

            HStack(spacing: 36) {
                Button { player.load(paper); player.skip(-15) } label: {
                    Image(systemName: "gobackward.15").font(.title)
                }
                Button {
                    if isLoaded { player.toggle() } else { player.play(paper) }
                } label: {
                    Image(systemName: isLoaded && player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 64))
                }
                Button { player.load(paper); player.skip(15) } label: {
                    Image(systemName: "goforward.15").font(.title)
                }
            }

            Menu {
                Picker("Speed", selection: $player.speed) {
                    ForEach(SummaryPlayer.speeds, id: \.self) { s in
                        Text(String(format: "%.1f×", s)).tag(s)
                    }
                }
            } label: {
                Label(String(format: "%.1f×", player.speed), systemImage: "speedometer")
                    .font(.subheadline)
            }
        }
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private var currentChapter: Int? {
        paper.chapterStarts.lastIndex { $0 <= position + 0.25 }
    }
}

struct SectionCard: View {
    let paper: Paper
    let index: Int
    let section: Paper.Section
    @EnvironmentObject private var player: SummaryPlayer

    private var isCurrent: Bool {
        guard player.paperID == paper.id, paper.stage == .ready else { return false }
        let starts = paper.chapterStarts
        return starts.lastIndex { $0 <= player.position + 0.25 } == index
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(section.kind.heading, systemImage: section.kind.symbol)
                    .font(.headline)
                    .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                Spacer()
                if paper.stage == .ready, paper.chapterStarts.indices.contains(index) {
                    Button {
                        player.load(paper)
                        player.seek(to: paper.chapterStarts[index])
                        player.play()
                    } label: {
                        Label(Paper.format(paper.chapterStarts[index]), systemImage: "play.fill")
                            .font(.caption.monospacedDigit())
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            Text(section.text)
                .font(.body)
                .foregroundStyle(isCurrent ? .primary : .secondary)
                .textSelection(.enabled)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isCurrent ? AnyShapeStyle(.tint.opacity(0.08)) : AnyShapeStyle(.clear),
                    in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.quaternary))
    }
}

struct PDFKitView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.document = PDFDocument(url: url)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {}
}
