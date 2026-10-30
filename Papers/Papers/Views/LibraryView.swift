import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var queue: WorkQueue
    @EnvironmentObject private var player: SummaryPlayer
    @State private var importing = false
    @State private var showSettings = false
    @State private var importFailed = false
    @State private var pendingFailure = false   // shown once the picker has gone
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
            .sheet(isPresented: $importing, onDismiss: { if pendingFailure { pendingFailure = false; importFailed = true } }) {
                DocumentPicker(types: [.pdf]) { urls in
                    var added = 0
                    for url in urls {
                        if library.importPDF(from: url) != nil { added += 1 }
                        DocumentPicker.discardCopy(url)
                    }
                    pendingFailure = added < urls.count
                    if added > 0 { queue.start() }
                }
                .ignoresSafeArea()
            }
            .alert("Some files could not be added", isPresented: $importFailed) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Make sure they are PDFs you can open in the Files app.")
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .safeAreaInset(edge: .bottom) {
                if player.item != nil, !isShowingPlayingPaper {
                    MiniPlayer()
                        .onTapGesture { if case .paper(let id, _) = player.item { path.append(id) } }
                }
            }
        }
    }

    private var isShowingPlayingPaper: Bool {
        if case .paper(let id, _) = player.item { return path.last == id }
        return false
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.richtext")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("Add a research paper")
                .font(.title2.bold())
            Text("Pick a PDF, or share one to Papers from Safari, Mail or Files. Papers reads it on your iPhone and makes three things to listen to: a five to six minute overview, a ten to fifteen minute in-depth look at the findings, experiments, figures and limits, and study questions with answers.")
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
                Label("iOS paused the work in the background. It carries on now that Papers is open.",
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
                    queue.deletePaper(id)
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
                if paper.tracks[.overview] != nil {
                    Label("Overview ready to play", systemImage: "play.circle")
                        .font(.caption)
                        .foregroundStyle(.tint)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
