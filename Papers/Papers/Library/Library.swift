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
    nonisolated static func audioURL(_ id: UUID, _ track: TrackKind) -> URL { folder(id).appendingPathComponent(track.fileName) }
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

    /// Starts over from the PDF.
    func resetSummary(_ id: UUID) {
        update(id) { p in
            p.stage = .queued
            p.stageProgress = 0
            p.error = nil
            p.notes = []
            p.chunkCount = 0
            p.overview = []
            p.deepPlan = nil
            p.deep = []
            p.questionList = nil
            p.questions = []
            p.tracks = [:]
        }
        for track in TrackKind.allCases { try? FileManager.default.removeItem(at: Self.audioURL(id, track)) }
    }

    /// Records the audio again (for example with other voices), keeping the scripts.
    func resetAudio(_ id: UUID) {
        update(id) { p in
            p.tracks = [:]
            p.error = nil
            p.stageProgress = 0
            p.stage = p.overview.count == PaperPipeline.OverviewPart.allCases.count ? .recordOverview : .queued
        }
        for track in TrackKind.allCases { try? FileManager.default.removeItem(at: Self.audioURL(id, track)) }
    }

    /// Picks a failed summary up where it stopped.
    func retry(_ id: UUID) {
        update(id) { p in
            p.stage = Self.resumeStage(p)
            p.stageProgress = 0
            p.error = nil
        }
    }

    /// The first step that is not done yet.
    nonisolated static func resumeStage(_ p: Paper) -> Paper.Stage {
        let hasText = FileManager.default.fileExists(atPath: textURL(p.id).path)
        if !hasText || p.chunkCount == 0 { return .queued }
        if p.notes.count < p.chunkCount { return .notes }
        if p.overview.count < PaperPipeline.OverviewPart.allCases.count { return .overview }
        if p.tracks[.overview] == nil { return .recordOverview }
        if p.deepPlan == nil || p.deep.count < (p.deepPlan?.count ?? 0) { return .deep }
        if p.questionList == nil || p.questions.count < (p.questionList?.count ?? 0) { return .questions }
        if p.tracks[.deep] == nil { return .recordDeep }
        if p.tracks[.questions] == nil && !p.questions.isEmpty { return .recordQuestions }
        return .ready
    }

    /// Papers still to be summarized, oldest first.
    var pending: [Paper] {
        papers.filter(\.isWorking).sorted { $0.added < $1.added }
    }
}
