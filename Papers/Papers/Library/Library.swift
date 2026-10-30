import Foundation

/// All imported papers, newest first, each saved in Documents/Papers/<id>/.
@MainActor
final class Library: ObservableObject {
    static let shared = Library()

    @Published private(set) var papers: [Paper] = []

    nonisolated static var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Papers", isDirectory: true)
    }

    nonisolated static func folder(_ id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    nonisolated static func pdfURL(_ id: UUID) -> URL { folder(id).appendingPathComponent("paper.pdf") }
    nonisolated static func textURL(_ id: UUID) -> URL { folder(id).appendingPathComponent("text.txt") }
    nonisolated static func audioURL(_ id: UUID) -> URL { folder(id).appendingPathComponent("summary.m4a") }
    nonisolated static func stateURL(_ id: UUID) -> URL { folder(id).appendingPathComponent("state.json") }

    private init() {
        load()
    }

    private func load() {
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let folders = (try? FileManager.default.contentsOfDirectory(at: Self.directory, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        papers = folders.compactMap { folder in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("state.json")) else { return nil }
            return try? decoder.decode(Paper.self, from: data)
        }
        .sorted { $0.added > $1.added }
    }

    func paper(_ id: UUID) -> Paper? {
        papers.first { $0.id == id }
    }

    /// Saves `paper` and publishes the change.
    func update(_ paper: Paper) {
        if let i = papers.firstIndex(where: { $0.id == paper.id }) {
            guard papers[i] != paper else { return }
            papers[i] = paper
        } else {
            papers.insert(paper, at: 0)
        }
        save(paper)
    }

    func update(_ id: UUID, _ change: (inout Paper) -> Void) {
        guard var paper = paper(id) else { return }
        change(&paper)
        update(paper)
    }

    private func save(_ paper: Paper) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(paper) else { return }
        try? FileManager.default.createDirectory(at: Self.folder(paper.id), withIntermediateDirectories: true)
        try? data.write(to: Self.stateURL(paper.id), options: .atomic)
    }

    /// Copies a PDF into the library and queues it. Returns nil when the file could not be read.
    @discardableResult
    func importPDF(from url: URL) -> Paper? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        var paper = Paper(fileName: url.lastPathComponent)
        let dest = Self.pdfURL(paper.id)
        do {
            try FileManager.default.createDirectory(at: Self.folder(paper.id), withIntermediateDirectories: true)
            // a coordinated read also works for files in iCloud Drive that are not downloaded yet
            var coordError: NSError?
            var copyError: Error?
            NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: &coordError) { readURL in
                do { try FileManager.default.copyItem(at: readURL, to: dest) } catch { copyError = error }
            }
            if let e = coordError ?? copyError { throw e }
        } catch {
            try? FileManager.default.removeItem(at: Self.folder(paper.id))
            return nil
        }
        paper.stage = .queued
        update(paper)
        // files handed over with "Open in" land in Documents/Inbox; the library has its own copy now
        if url.path.contains("/Documents/Inbox/") { try? FileManager.default.removeItem(at: url) }
        return paper
    }

    func delete(_ id: UUID) {
        papers.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: Self.folder(id))
    }

    /// Starts over from the PDF (keeps the extracted text).
    func resetSummary(_ id: UUID) {
        update(id) { p in
            p.stage = .queued
            p.stageProgress = 0
            p.error = nil
            p.notes = []
            p.chunkCount = 0
            p.sections = []
            p.duration = nil
            p.chapterStarts = []
            p.playbackPosition = 0
        }
        try? FileManager.default.removeItem(at: Self.audioURL(id))
    }

    /// Records the audio again (for example with another voice), keeping the script.
    func resetAudio(_ id: UUID) {
        update(id) { p in
            p.stage = p.sections.count == SectionKind.allCases.count ? .recording : .queued
            p.stageProgress = 0
            p.error = nil
            p.duration = nil
            p.chapterStarts = []
            p.playbackPosition = 0
        }
        try? FileManager.default.removeItem(at: Self.audioURL(id))
    }

    /// Picks a failed summary up where it stopped.
    func retry(_ id: UUID) {
        update(id) { p in
            if p.sections.count == SectionKind.allCases.count {
                p.stage = .recording
            } else if p.chunkCount > 0 && p.notes.count >= p.chunkCount {
                p.stage = .writing
            } else if p.chunkCount > 0 && FileManager.default.fileExists(atPath: Self.textURL(id).path) {
                p.stage = .notes
            } else {
                p.stage = .queued
            }
            p.stageProgress = 0
            p.error = nil
        }
    }

    /// Papers still to be summarized, oldest first.
    var pending: [Paper] {
        papers.filter(\.isWorking).sorted { $0.added < $1.added }
    }
}
