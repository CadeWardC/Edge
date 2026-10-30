import Foundation

/// An imported audio or video file, its transcript and its bullet-point summary, saved in
/// Documents/Recordings/<id>/ (the media file as it was imported, and state.json).
struct Recording: Codable, Identifiable, Equatable {
    enum Stage: String, Codable {
        case queued, transcribing, summarizing, ready, failed
    }

    var id = UUID()
    var fileName: String
    var mediaName: String
    var added = Date()
    var duration: Double = 0
    var stage: Stage = .queued
    var stageProgress: Double = 0
    var error: String?
    var segments: [TranscriptSegment] = []
    /// The audio up to here has been transcribed (so a stopped transcription carries on).
    var transcribedUntil: Double = 0
    var transcriptionDone = false
    var notes: [String] = []
    var summary: TranscriptSummary?
    var position: Double = 0

    init(fileName: String, mediaName: String) {
        self.fileName = fileName
        self.mediaName = mediaName
    }

    var displayTitle: String {
        if let t = summary?.title, !t.isEmpty { return t }
        return (fileName as NSString).deletingPathExtension
    }

    var isWorking: Bool { ![.ready, .failed].contains(stage) }

    var overallProgress: Double {
        switch stage {
        case .queued, .failed: return 0
        case .transcribing: return 0.75 * stageProgress
        case .summarizing: return 0.75 + 0.25 * stageProgress
        case .ready: return 1
        }
    }

    var statusText: String {
        switch stage {
        case .queued: return "Waiting"
        case .transcribing: return "Transcribing, \(Int(stageProgress * 100))%"
        case .summarizing: return "Summarizing"
        case .ready: return duration > 0 ? "\(Paper.format(duration)) · \(summary?.keyPoints.count ?? 0) key points" : "Ready"
        case .failed: return error ?? "Failed"
        }
    }

    /// The transcript as plain text, with timestamps.
    var transcriptText: String { TranscriptPipeline.text(segments) }

    /// The summary as plain text, for copying and sharing.
    var summaryText: String {
        guard let s = summary else { return "" }
        var out = "\(displayTitle)\n\n\(s.overview)\n\nKey points\n" + s.keyPoints.map { "• \($0)" }.joined(separator: "\n")
        if !s.actionItems.isEmpty {
            out += "\n\nAction items\n" + s.actionItems.map { "• \($0)" }.joined(separator: "\n")
        }
        return out
    }
}

/// All imported recordings, newest first.
@MainActor
final class RecordingLibrary: ObservableObject {
    static let shared = RecordingLibrary()

    /// Audio and video types the Audio tab accepts.
    static let mediaExtensions: Set<String> = ["m4a", "mp3", "wav", "aiff", "aif", "aac", "caf", "flac", "mp4", "mov", "m4v", "3gp", "amr", "opus", "ogg"]

    @Published private(set) var recordings: [Recording] = []

    nonisolated static var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Recordings", isDirectory: true)
    }

    nonisolated static func folder(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString, isDirectory: true) }
    nonisolated static func mediaURL(_ r: Recording) -> URL { folder(r.id).appendingPathComponent(r.mediaName) }

    private init() {
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let folders = (try? FileManager.default.contentsOfDirectory(at: Self.directory, includingPropertiesForKeys: nil)) ?? []
        recordings = folders.compactMap { folder in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("state.json")) else { return nil }
            return try? JSONDecoder().decode(Recording.self, from: data)
        }
        .sorted { $0.added > $1.added }
    }

    func recording(_ id: UUID) -> Recording? { recordings.first { $0.id == id } }

    func update(_ recording: Recording) {
        if let i = recordings.firstIndex(where: { $0.id == recording.id }) {
            guard recordings[i] != recording else { return }
            recordings[i] = recording
        } else {
            recordings.insert(recording, at: 0)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(recording) else { return }
        try? FileManager.default.createDirectory(at: Self.folder(recording.id), withIntermediateDirectories: true)
        try? data.write(to: Self.folder(recording.id).appendingPathComponent("state.json"), options: .atomic)
    }

    func update(_ id: UUID, _ change: (inout Recording) -> Void) {
        guard var r = recording(id) else { return }
        change(&r)
        update(r)
    }

    /// Copies an audio or video file into the library and queues it.
    @discardableResult
    func importMedia(from url: URL) async -> Recording? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let ext = url.pathExtension.isEmpty ? "m4a" : url.pathExtension.lowercased()
        var recording = Recording(fileName: url.lastPathComponent, mediaName: "audio.\(ext)")
        let dest = Self.mediaURL(recording)
        do {
            try FileManager.default.createDirectory(at: Self.folder(recording.id), withIntermediateDirectories: true)
            var coordError: NSError?
            var copyError: Error?
            NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: &coordError) { readURL in
                do { try FileManager.default.copyItem(at: readURL, to: dest) } catch { copyError = error }
            }
            if let e = coordError ?? copyError { throw e }
        } catch {
            try? FileManager.default.removeItem(at: Self.folder(recording.id))
            return nil
        }
        recording.duration = await Transcriber.duration(of: dest)
        guard recording.duration > 0 else {
            try? FileManager.default.removeItem(at: Self.folder(recording.id))
            return nil
        }
        update(recording)
        if url.path.contains("/Documents/Inbox/") { try? FileManager.default.removeItem(at: url) }
        return recording
    }

    func delete(_ id: UUID) {
        recordings.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: Self.folder(id))
    }

    func retry(_ id: UUID) {
        update(id) { r in
            r.stage = r.transcriptionDone ? .summarizing : .transcribing
            r.error = nil
            r.stageProgress = 0
        }
    }

    /// Makes the summary again from the transcript.
    func resummarize(_ id: UUID) {
        update(id) { r in
            r.notes = []
            r.summary = nil
            r.stage = .summarizing
            r.error = nil
        }
    }

    var pending: [Recording] {
        recordings.filter(\.isWorking).sorted { $0.added < $1.added }
    }
}
