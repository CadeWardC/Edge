import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var queue: SummaryQueue
    @EnvironmentObject private var player: SummaryPlayer
    @State private var importing = false
    @State private var showSettings = false
    @State private var importFailed = false
    @State private var path: [UUID] = []

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if library.papers.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .navigationTitle("Papers")
            .navigationDestination(for: UUID.self) { id in
                PaperView(id: id)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { importing = true } label: { Image(systemName: "plus") }
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf], allowsMultipleSelection: true) { result in
                guard case .success(let urls) = result else { return }
                var added = 0
                for url in urls where library.importPDF(from: url) != nil { added += 1 }
                if added < urls.count { importFailed = true }
                if added > 0 { queue.start() }
            }
            .alert("Some files could not be added", isPresented: $importFailed) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Make sure they are PDFs you can open in the Files app.")
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .safeAreaInset(edge: .bottom) {
                if let id = player.paperID, let paper = library.paper(id), path.last != id {
                    MiniPlayer(paper: paper) { path.append(id) }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.richtext")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("Add a research paper")
                .font(.title2.bold())
            Text("Pick a PDF, or share one to Papers from Safari, Mail or Files. Papers reads it on your iPhone and makes a five to six minute audio overview: the question, why it matters, what they did and what they found.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button {
                importing = true
            } label: {
                Label("Choose a PDF", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(32)
    }

    private var list: some View {
        List {
            if queue.pausedInBackground {
                Label("iOS paused the summary in the background. It carries on now that Papers is open.",
                      systemImage: "pause.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(library.papers) { paper in
                NavigationLink(value: paper.id) {
                    PaperRow(paper: paper, isCurrent: queue.currentID == paper.id)
                }
            }
            .onDelete { offsets in
                for i in offsets {
                    let id = library.papers[i].id
                    player.unload(id)
                    queue.delete(id)
                }
            }
        }
    }
}

struct PaperRow: View {
    let paper: Paper
    let isCurrent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(paper.displayTitle)
                .font(.headline)
                .lineLimit(3)
            HStack(spacing: 6) {
                switch paper.stage {
                case .ready:
                    Image(systemName: "waveform").foregroundStyle(.tint)
                case .failed:
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                default:
                    if isCurrent { ProgressView().controlSize(.mini) } else { Image(systemName: "clock") }
                }
                Text(paper.stage == .queued && !isCurrent ? "Waiting" : paper.statusText)
                    .lineLimit(2)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if paper.isWorking {
                ProgressView(value: paper.overallProgress)
            } else if paper.stage == .ready, let duration = paper.duration, paper.playbackPosition > 1 {
                ProgressView(value: min(paper.playbackPosition / max(duration, 1), 1))
                    .tint(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

/// A small bar above the bottom edge for the summary that is playing.
struct MiniPlayer: View {
    @EnvironmentObject private var player: SummaryPlayer
    let paper: Paper
    let open: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: open) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(paper.displayTitle).font(.subheadline.bold()).lineLimit(1)
                    Text("\(Paper.format(player.position)) / \(Paper.format(player.duration))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
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
