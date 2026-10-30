import SwiftUI
import UniformTypeIdentifiers

/// The Audio tab: import a recording (audio or video), get its transcript and a bullet-point summary.
struct RecordingsView: View {
    @EnvironmentObject private var recordings: RecordingLibrary
    @EnvironmentObject private var models: ModelStore
    @EnvironmentObject private var queue: WorkQueue
    @EnvironmentObject private var player: SummaryPlayer
    @State private var importing = false
    @State private var importFailed = false
    @State private var showSettings = false
    @State private var path: [UUID] = []

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if !models.speechReady {
                    speechDownload
                }
                if queue.pausedInBackground {
                    Label("iOS paused the work in the background. It carries on now that Papers is open.",
                          systemImage: "pause.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if recordings.recordings.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Add a recording").font(.headline)
                        Text("A lecture, meeting, interview, voice memo or video. Papers transcribes it on your iPhone with Parakeet, then sums it up in bullet points with the key points and action items. Tap + or share a file to Papers.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                }
                ForEach(recordings.recordings) { r in
                    NavigationLink(value: r.id) {
                        RecordingRow(recording: r, isCurrent: queue.currentID == r.id, speechReady: models.speechReady)
                    }
                }
                .onDelete { offsets in
                    for i in offsets { queue.deleteRecording(recordings.recordings[i].id) }
                }
            }
            .navigationTitle("Audio")
            .navigationDestination(for: UUID.self) { id in RecordingView(id: id) }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { importing = true } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $importing) {
                DocumentPicker(types: [.audio, .movie]) { urls in
                    Task {
                        var added = 0
                        for url in urls {
                            if await recordings.importMedia(from: url) != nil { added += 1 }
                            DocumentPicker.discardCopy(url)
                        }
                        if added < urls.count { importFailed = true }
                        if added > 0 { queue.start() }
                    }
                }
                .ignoresSafeArea()
            }
            .alert("Some files could not be added", isPresented: $importFailed) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Make sure they are audio or video files with sound.")
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .safeAreaInset(edge: .bottom) {
                if player.item != nil, !isShowingPlayingRecording {
                    MiniPlayer()
                        .onTapGesture { if case .recording(let id) = player.item { path.append(id) } }
                }
            }
        }
    }

    private var isShowingPlayingRecording: Bool {
        if case .recording(let id) = player.item { return path.last == id }
        return false
    }

    @ViewBuilder private var speechDownload: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Speech recognition", systemImage: "arrow.down.circle").font(.headline)
            Text("A one-time download of about 670 MB: NVIDIA Parakeet (English and 24 other European languages, with punctuation) and a voice detector.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            switch models.phase {
            case .idle:
                Button("Download") { Task { await models.download(speech: true) } }
                    .buttonStyle(.borderedProminent)
            case .resolving:
                ProgressView()
            case .downloading(let remaining):
                ProgressView(value: models.progress)
                Text(models.downloadingSpeech
                     ? "\(Int(models.progress * 100))% · \(remaining) file\(remaining == 1 ? "" : "s") left. You can leave the app."
                     : "Waiting for the other download to finish.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .failed(let message):
                Text(message).font(.footnote).foregroundStyle(.red)
                Button("Try again") { Task { await models.download(speech: true) } }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.vertical, 6)
    }
}

struct RecordingRow: View {
    let recording: Recording
    let isCurrent: Bool
    let speechReady: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(recording.displayTitle).font(.headline).lineLimit(2)
            HStack(spacing: 6) {
                switch recording.stage {
                case .ready:
                    Image(systemName: "list.bullet.rectangle").foregroundStyle(.tint)
                case .failed:
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                default:
                    if isCurrent { ProgressView().controlSize(.mini) } else { Image(systemName: "clock") }
                }
                Text(statusText).lineLimit(2)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if recording.isWorking {
                ProgressView(value: recording.overallProgress)
            }
        }
        .padding(.vertical, 4)
    }

    private var statusText: String {
        if recording.isWorking && !recording.transcriptionDone && !speechReady { return "Waiting for the speech recognition download" }
        if recording.stage == .queued && !isCurrent { return "Waiting · \(Paper.format(recording.duration))" }
        return recording.statusText
    }
}

struct RecordingView: View {
    let id: UUID
    @EnvironmentObject private var recordings: RecordingLibrary
    @EnvironmentObject private var queue: WorkQueue
    @EnvironmentObject private var player: SummaryPlayer
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false
    @State private var showTranscript = true

    var body: some View {
        Group {
            if let r = recordings.recording(id) {
                content(r)
            } else {
                ContentUnavailableView("This recording was removed", systemImage: "waveform")
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Delete this recording, its transcript and summary?", isPresented: $confirmDelete,
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                queue.deleteRecording(id)
                dismiss()
            }
        }
    }

    private func content(_ r: Recording) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(r.displayTitle).font(.title2.bold()).textSelection(.enabled)

                    PlayerCard(id: .recording(id), duration: r.duration, savedPosition: r.position)

                    if r.stage == .failed {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("This could not be finished", systemImage: "exclamationmark.triangle").font(.headline)
                            Text(r.error ?? "Unknown error").font(.footnote).foregroundStyle(.secondary)
                            Button("Try again") { queue.retryRecording(id) }.buttonStyle(.borderedProminent)
                        }
                        .padding()
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
                    } else if r.isWorking {
                        VStack(alignment: .leading, spacing: 8) {
                            ProgressView(value: r.overallProgress)
                            Text(queue.currentID == id ? r.statusText : "Waiting").font(.subheadline)
                            Text("The transcript appears below as it is written. You can leave the app.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding()
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
                    }

                    if let s = r.summary {
                        SummaryCard(summary: s)
                    }

                    if !r.segments.isEmpty {
                        HStack {
                            Text("Transcript").font(.title3.bold())
                            Spacer()
                            Button(showTranscript ? "Hide" : "Show") { withAnimation { showTranscript.toggle() } }
                                .font(.subheadline)
                        }
                        if showTranscript {
                            LazyVStack(alignment: .leading, spacing: 10) {
                                ForEach(Array(r.segments.enumerated()), id: \.offset) { i, segment in
                                    SegmentRow(segment: segment, isCurrent: isCurrent(segment, in: r)) {
                                        player.load(.recording(id))
                                        player.seek(to: segment.start)
                                        player.play()
                                    }
                                    .id(i)
                                }
                            }
                        }
                    }
                }
                .padding()
            }
            .toolbar {
                Menu {
                    if r.summary != nil {
                        ShareLink(item: r.summaryText) { Label("Share summary", systemImage: "list.bullet") }
                        Button { UIPasteboard.general.string = r.summaryText } label: { Label("Copy summary", systemImage: "doc.on.doc") }
                    }
                    if !r.segments.isEmpty {
                        ShareLink(item: r.transcriptText) { Label("Share transcript", systemImage: "text.alignleft") }
                        Button { UIPasteboard.general.string = r.transcriptText } label: { Label("Copy transcript", systemImage: "doc.on.doc") }
                    }
                    if r.transcriptionDone && !r.isWorking {
                        Button { queue.resummarize(id) } label: { Label("Summarize again", systemImage: "arrow.clockwise") }
                    }
                    Button(role: .destructive) { confirmDelete = true } label: { Label("Delete", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
    }

    private func isCurrent(_ segment: TranscriptSegment, in r: Recording) -> Bool {
        player.item == .recording(r.id) && player.position >= segment.start && player.position < segment.end + 0.5
    }
}

struct SummaryCard: View {
    let summary: TranscriptSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !summary.overview.isEmpty {
                Text(summary.overview).font(.body).textSelection(.enabled)
            }
            if !summary.keyPoints.isEmpty {
                Text("Key points").font(.headline)
                ForEach(Array(summary.keyPoints.enumerated()), id: \.offset) { _, point in
                    BulletText(text: point)
                }
            }
            if !summary.actionItems.isEmpty {
                Text("Action items").font(.headline).padding(.top, 4)
                ForEach(Array(summary.actionItems.enumerated()), id: \.offset) { _, item in
                    BulletText(text: item, symbol: "checkmark.circle")
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

struct BulletText: View {
    let text: String
    var symbol = "circle.fill"

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .font(symbol == "circle.fill" ? .system(size: 6) : .caption)
                .foregroundStyle(.tint)
            Text(text).textSelection(.enabled)
        }
    }
}

struct SegmentRow: View {
    let segment: TranscriptSegment
    let isCurrent: Bool
    let onTap: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button(action: onTap) {
                Text(TranscriptPipeline.timestamp(segment.start))
                    .font(.caption.monospacedDigit())
            }
            .buttonStyle(.borderless)
            Text(segment.text)
                .foregroundStyle(isCurrent ? .primary : .secondary)
                .textSelection(.enabled)
        }
        .padding(6)
        .background(isCurrent ? AnyShapeStyle(.tint.opacity(0.1)) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 8))
    }
}
