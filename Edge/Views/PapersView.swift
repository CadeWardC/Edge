import SwiftUI
import UniformTypeIdentifiers

struct PapersView: View {
    @EnvironmentObject private var library: PaperLibrary
    @EnvironmentObject private var worker: PaperWorker
    @EnvironmentObject private var voices: VoiceLibrary
    @EnvironmentObject private var models: ModelStore
    @State private var importing = false
    @State private var error: String?
    @State private var path: [UUID] = []
    @State private var hasKey = Keychain.deepSeekKey != nil

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if !hasKey || !VoiceModel.allCases.contains(where: models.isReady) {
                    Section {
                        SetupRow(done: hasKey, title: "Add your DeepSeek API key", detail: "Settings › DeepSeek")
                        SetupRow(done: models.isReady(.kokoro) || VoiceModel.cloning.contains(where: models.isReady),
                                 title: "Download the voices", detail: "Settings › Voice models (Kokoro has 27 built-in voices)")
                    } header: {
                        Text("Get started")
                    } footer: {
                        Text("To hear papers in your own voice, or anyone's, add a recording in the Voices tab and download a cloning model.")
                    }
                }
                if library.papers.isEmpty {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("No papers yet").font(.headline)
                            Text("Import a PDF. DeepSeek writes a script in as many parts as you like, and a natural voice, built in or cloned from a recording, reads it so you can listen.")
                                .font(.subheadline).foregroundStyle(.secondary)
                            Button("Import a PDF") { importing = true }
                                .buttonStyle(.borderedProminent)
                                .padding(.top, 4)
                        }
                        .padding(.vertical, 6)
                    }
                } else {
                    Section {
                        ForEach(library.papers) { paper in
                            NavigationLink(value: paper.id) { PaperRow(paper: paper) }
                        }
                        .onDelete { offsets in
                            for i in offsets {
                                let id = library.papers[i].id
                                worker.cancel(id)
                                library.delete(id)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Papers")
            .toolbar {
                Button { importing = true } label: { Image(systemName: "plus") }
            }
            .navigationDestination(for: UUID.self) { id in PaperDetailView(id: id) }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf], allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls):
                    var last: Paper?
                    for url in urls {
                        do { last = try library.importPDF(url) } catch { self.error = error.localizedDescription }
                    }
                    if urls.count == 1, let last { path = [last.id] }
                case .failure(let e):
                    error = e.localizedDescription
                }
            }
            .alert("Couldn't import", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK") { error = nil }
            } message: { Text(error ?? "") }
            .onAppear { hasKey = Keychain.deepSeekKey != nil }
        }
    }
}

private struct SetupRow: View {
    let done: Bool
    let title: String
    let detail: String

    var body: some View {
        HStack {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? .green : .secondary)
            VStack(alignment: .leading) {
                Text(title).strikethrough(done)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct PaperRow: View {
    @EnvironmentObject private var worker: PaperWorker
    let paper: Paper

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(paper.title).font(.headline).lineLimit(2)
            HStack(spacing: 6) {
                if worker.current == paper.id {
                    ProgressView().controlSize(.mini)
                    Text(worker.status)
                } else if worker.queued.contains(paper.id) {
                    Text("Waiting…")
                } else {
                    switch paper.stage {
                    case .done:
                        Image(systemName: "headphones")
                        Text("\(paper.parts.count) part\(paper.parts.count == 1 ? "" : "s") · \(formatDuration(paper.totalDuration))")
                    case .failed:
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                        Text(paper.message ?? "Didn't finish")
                    default:
                        Text(paper.added.formatted(date: .abbreviated, time: .omitted))
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .padding(.vertical, 2)
    }
}
