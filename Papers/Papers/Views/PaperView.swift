import PDFKit
import SwiftUI

struct PaperView: View {
    let id: UUID
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var queue: WorkQueue
    @EnvironmentObject private var player: SummaryPlayer
    @Environment(\.dismiss) private var dismiss
    @State private var track = TrackKind.overview
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
        .confirmationDialog("Delete this paper and its audio?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                queue.deletePaper(id)
                dismiss()
            }
        }
        .onAppear {
            // continue with the track that was playing
            if case .paper(let pid, let kind) = player.item, pid == id { track = kind }
        }
    }

    @ViewBuilder private func content(_ paper: Paper) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(paper.displayTitle)
                    .font(.title2.bold())
                    .textSelection(.enabled)

                if paper.stage == .failed {
                    failedCard(paper)
                } else if paper.isWorking {
                    progressCard(paper)
                }

                Picker("Track", selection: $track) {
                    ForEach(TrackKind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .pickerStyle(.segmented)

                Text(track.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let t = paper.tracks[track] {
                    PlayerCard(id: .paper(id, track), duration: t.duration, savedPosition: t.position)
                } else if paper.isWorking {
                    Label(track == .overview ? "Being written now." : "Comes after the overview.", systemImage: "hourglass")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                switch track {
                case .overview:
                    ForEach(paper.overview) { part in
                        PartCard(heading: part.heading, text: part.text, playable: .paper(id, .overview),
                                 chapter: paper.tracks[.overview]?.chapters.first { $0.title == part.heading })
                    }
                case .deep:
                    ForEach(paper.deep) { part in
                        PartCard(heading: part.heading, text: part.text, playable: .paper(id, .deep),
                                 chapter: paper.tracks[.deep]?.chapters.first { $0.title == part.heading })
                    }
                case .questions:
                    ForEach(Array(paper.questions.enumerated()), id: \.element.id) { i, qa in
                        QuestionCard(number: i + 1, qa: qa, playable: .paper(id, .questions),
                                     chapter: paper.tracks[.questions]?.chapters.first { $0.title == "Question \(i + 1)" })
                    }
                }
            }
            .padding()
        }
        .toolbar {
            Menu {
                Button { showPDF = true } label: { Label("View PDF", systemImage: "doc.text") }
                if let t = paper.tracks[track] {
                    ShareLink(item: Library.audioURL(id, track)) {
                        Label("Share \(track.title.lowercased()) audio (\(Paper.format(t.duration)))", systemImage: "square.and.arrow.up")
                    }
                }
                if !paper.isWorking {
                    if paper.overview.count == PaperPipeline.OverviewPart.allCases.count {
                        Button { queue.regenerate(id, scriptToo: false) } label: {
                            Label("Record again with the current voices", systemImage: "waveform")
                        }
                    }
                    Button { queue.regenerate(id, scriptToo: true) } label: {
                        Label("Make everything again", systemImage: "arrow.clockwise")
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
            Text(queue.currentID == paper.id ? paper.statusText : (queue.isRunning ? "Waiting for the item before it" : "Waiting"))
                .font(.subheadline)
            Text("This runs entirely on your iPhone and takes a while. The overview is ready first. You can leave the app: the work continues in the background, and you'll get a notification.")
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
            Label("This could not be finished", systemImage: "exclamationmark.triangle")
                .font(.headline)
            Text(paper.error ?? "Unknown error")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button("Try again") { queue.retryPaper(paper.id) }
                .buttonStyle(.borderedProminent)
        }
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

/// A written part of a script, highlighted while it plays; its play button jumps to it.
struct PartCard: View {
    let heading: String
    let text: String
    let playable: PlayableID
    let chapter: Chapter?
    @EnvironmentObject private var player: SummaryPlayer

    private var isCurrent: Bool {
        guard player.item == playable, let chapter, let i = player.currentChapterIndex else { return false }
        return player.chapters[i] == chapter
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(heading)
                    .font(.headline)
                    .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                Spacer()
                if let chapter {
                    Button {
                        player.load(playable)
                        player.seek(to: chapter.start)
                        player.play()
                    } label: {
                        Label(Paper.format(chapter.start), systemImage: "play.fill").font(.caption.monospacedDigit())
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            Text(text)
                .font(.body)
                .foregroundStyle(isCurrent ? .primary : .secondary)
                .textSelection(.enabled)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isCurrent ? AnyShapeStyle(.tint.opacity(0.08)) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.quaternary))
    }
}

/// A study question; tap to show the answer (try answering it first).
struct QuestionCard: View {
    let number: Int
    let qa: QuestionAnswer
    let playable: PlayableID
    let chapter: Chapter?
    @EnvironmentObject private var player: SummaryPlayer
    @State private var revealed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Text("\(number)").font(.headline.monospacedDigit()).foregroundStyle(.tint)
                Text(qa.question).font(.headline)
                Spacer()
                if let chapter {
                    Button {
                        player.load(playable)
                        player.seek(to: chapter.start)
                        player.play()
                    } label: { Image(systemName: "play.fill").font(.caption) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            if revealed {
                Text(qa.answer)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } else {
                Button("Show answer") { withAnimation { revealed = true } }
                    .font(.subheadline)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
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
