import Foundation
import os
import UIKit
import UserNotifications

/// Downloads the models: Qwen3.5 (reads the paper and writes the summaries), Kokoro (reads them out) and, for the
/// Audio tab, Parakeet with Silero VAD (transcribes recordings).
/// Downloads run in a background URLSession, so they keep going while the app is suspended.
@MainActor
final class ModelStore: NSObject, ObservableObject {
    struct RemoteFile: Decodable {
        let type: String
        let path: String
        let size: Int64?
    }

    enum Phase: Equatable {
        case idle
        case resolving
        case downloading(remaining: Int)
        case failed(String)
    }

    static let shared = ModelStore()
    static let sessionIdentifier = "com.cadewardc.papers.models"

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var progress: Double = 0
    @Published private(set) var downloadSizeBytes: Int64 = 0

    /// Handed over by the app delegate when iOS wakes the app for finished background downloads.
    var backgroundCompletionHandler: (() -> Void)?

    private var session: URLSession!
    /// Bytes written and expected per file name (the task description of each download).
    private var written: [String: Int64] = [:]
    private var expected: [String: Int64] {
        get {
            let stored = UserDefaults.standard.dictionary(forKey: "downloadSizes") ?? [:]
            return stored.compactMapValues { ($0 as? NSNumber)?.int64Value }
        }
        set { UserDefaults.standard.set(newValue.mapValues { NSNumber(value: $0) }, forKey: "downloadSizes") }
    }
    /// Lets "Try again" continue a failed download instead of starting over.
    private var resumeData: [String: Data] = [:]

    /// Documents/Models, visible in the Files app.
    nonisolated static var modelsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Models", isDirectory: true)
    }

    var isReady: Bool { chatModelURL != nil && kokoroReady }

    private override init() {
        super.init()
        // a background session keeps downloading while the app is suspended, and relaunches it when done
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.timeoutIntervalForResource = 60 * 60 * 24
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        refresh()
        restoreDownloads()
    }

    /// Checks which models are in place.
    func refresh() {
        let chatDir = Self.modelsDirectory.appendingPathComponent(Self.chatDirectory, isDirectory: true)
        let chatFiles = ((try? FileManager.default.contentsOfDirectory(atPath: chatDir.path)) ?? [])
            .filter { $0.lowercased().hasSuffix(".gguf") }
        chatModelURL = Self.pickChatModel(chatFiles).map { chatDir.appendingPathComponent($0) }
        kokoroReady = Self.kokoroFiles.keys.allSatisfy { FileManager.default.fileExists(atPath: Self.kokoroURL($0).path) }
        speechReady = Self.speechFiles.keys.allSatisfy {
            FileManager.default.fileExists(atPath: Self.speechDirectoryURL.appendingPathComponent($0).path)
        }
    }

    // MARK: Summary model (Qwen3.5)

    nonisolated static let defaultChatRepo = "unsloth/Qwen3.5-2B-GGUF"
    nonisolated static let largerChatRepo = "unsloth/Qwen3.5-4B-GGUF"
    /// Q4_K_M of Qwen3.5-4B, about 2.7 GB; it needs about 3.4 GB free while running.
    nonisolated static let largerChatBytes: Int64 = 2_740_000_000
    nonisolated static let chatDirectory = "Chat"
    nonisolated static let preferredChatQuants = ["Q4_K_M", "UD-Q4_K_XL", "Q5_K_M", "Q4_K_S", "Q6_K", "Q8_0"]

    @Published private(set) var chatModelURL: URL?

    var chatRepo: String {
        let r = UserDefaults.standard.string(forKey: "chatRepo")?.trimmingCharacters(in: .whitespaces) ?? ""
        return r.isEmpty ? Self.defaultChatRepo : r
    }

    nonisolated static func pickChatModel(_ names: [String]) -> String? {
        let candidates = names.filter { $0.lowercased().hasSuffix(".gguf") && !$0.lowercased().contains("mmproj") }
        for q in preferredChatQuants {
            if let hit = candidates.first(where: { $0.uppercased().contains(q) }) { return hit }
        }
        return candidates.first
    }

    // MARK: Kokoro (the narrator)

    /// Kokoro-82M v1.0 as converted by sherpa-onnx (full precision; int8 is audibly noisy), unpacked into a release
    /// of this repo (.github/workflows/mirror-kokoro-en.yml) since the original is a single .tar.bz2.
    nonisolated static let kokoroBaseURL = "https://github.com/CadeWardC/Edge/releases/download/models-kokoro-v1_0"
    nonisolated static let kokoroDirectory = "Kokoro"
    /// File name and size (from the mirror workflow's listing), for the progress bar.
    nonisolated static let kokoroFiles: [String: Int64] = [
        "model.onnx": 325_560_556, "voices.bin": 28_200_960, "tokens.txt": 687, "lexicon-us-en.txt": 5_956_885,
    ]
    nonisolated static var kokoroDirectoryURL: URL {
        modelsDirectory.appendingPathComponent(kokoroDirectory, isDirectory: true)
    }
    nonisolated static func kokoroURL(_ name: String) -> URL {
        modelsDirectory.appendingPathComponent(kokoroDirectory, isDirectory: true).appendingPathComponent(name)
    }

    @Published private(set) var kokoroReady = false

    // MARK: Speech recognition (Parakeet + Silero VAD), only for the Audio tab

    /// NVIDIA Parakeet TDT 0.6B v3 (int8, sherpa-onnx) and Silero VAD, unpacked into a release of this repo by
    /// .github/workflows/mirror-parakeet.yml.
    nonisolated static let speechBaseURL = "https://github.com/CadeWardC/Edge/releases/download/models-parakeet-v3"
    nonisolated static let speechDirectory = "Parakeet"
    /// Approximate sizes for the progress bar until the server reports the real ones.
    nonisolated static let speechFiles: [String: Int64] = [
        "encoder.int8.onnx": 652_000_000, "decoder.int8.onnx": 12_000_000, "joiner.int8.onnx": 6_400_000,
        "tokens.txt": 94_000, "silero_vad.onnx": 2_300_000,
    ]
    nonisolated static var speechDirectoryURL: URL {
        modelsDirectory.appendingPathComponent(speechDirectory, isDirectory: true)
    }

    @Published private(set) var speechReady = false
    /// Which set the current download is for.
    @Published private(set) var downloadingSpeech = false

    // MARK: Memory

    /// What the app may still allocate before iOS stops it (os_proc_available_memory), in bytes.
    nonisolated static var availableMemory: Int64 {
        Int64(os_proc_available_memory())
    }

    /// Whether a model file of this size can be loaded now with room to spare for its working memory.
    nonisolated static func fits(modelBytes: Int64) -> Bool {
        let available = availableMemory
        // 0 means the call is not supported (simulator); let it try
        return available == 0 || available > modelBytes + 700_000_000
    }

    // MARK: Download

    /// Downloads the summary model and the voice, or (`speech`) the speech recognition files for the Audio tab.
    func download(speech: Bool = false) async {
        guard phase == .idle || phase.isFailed else { return }
        downloadingSpeech = speech
        phase = .resolving
        progress = 0
        Notifier.requestPermission()

        func missing(_ name: String) -> Bool {
            !FileManager.default.fileExists(atPath: Self.modelsDirectory.appendingPathComponent(name).path)
        }
        func resolveURL(_ repo: String, _ file: String) -> URL {
            let encoded = file.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? file
            return URL(string: "https://huggingface.co/\(repo)/resolve/main/\(encoded)?download=true")!
        }

        do {
            var jobs: [(name: String, url: URL)] = []
            var sizes: [String: Int64] = [:]
            for (file, size) in Self.kokoroFiles { sizes["\(Self.kokoroDirectory)/\(file)"] = size }
            for (file, size) in Self.speechFiles { sizes["\(Self.speechDirectory)/\(file)"] = size }
            if speech {
                jobs = Self.speechFiles.keys.sorted().map { "\(Self.speechDirectory)/\($0)" }.filter(missing).map {
                    (name: $0, url: URL(string: "\(Self.speechBaseURL)/\(($0 as NSString).lastPathComponent)")!)
                }
            }
            // the summary model, kept in its own folder; its file name is looked up in the repo
            if !speech && chatModelURL == nil {
                let remote = try await listRemoteFiles(repo: chatRepo)
                guard let file = Self.pickChatModel(remote.map(\.path)) else {
                    throw EngineError.load("No GGUF model found in \(chatRepo).")
                }
                let name = "\(Self.chatDirectory)/\(file)"
                sizes[name] = remote.first { $0.path == file }?.size ?? 0
                if missing(name) { jobs.append((name: name, url: resolveURL(chatRepo, file))) }
            }
            // the Kokoro files, from this repo's release
            if !speech { jobs += Self.kokoroFiles.keys.sorted().filter { !FileManager.default.fileExists(atPath: Self.kokoroURL($0).path) }.map {
                (name: "\(Self.kokoroDirectory)/\($0)", url: URL(string: "\(Self.kokoroBaseURL)/\($0)")!)
            } }
            let wanted = jobs.map(\.name)
            guard !wanted.isEmpty else {
                phase = .idle
                refresh()
                return
            }
            expected = Dictionary(uniqueKeysWithValues: wanted.map { ($0, sizes[$0] ?? 0) })
            written = [:]
            updateProgress()

            for (name, url) in jobs {
                let task: URLSessionDownloadTask
                if let data = resumeData.removeValue(forKey: name) {
                    task = session.downloadTask(withResumeData: data)
                } else {
                    task = session.downloadTask(with: url)
                }
                task.taskDescription = name
                if let size = sizes[name], size > 0 {
                    task.countOfBytesClientExpectsToReceive = size
                }
                task.resume()
            }
            phase = .downloading(remaining: wanted.count)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func cancelDownload() {
        resumeData.removeAll()
        session.getAllTasks { tasks in tasks.forEach { $0.cancel() } }
        phase = .idle
    }

    /// Picks up downloads that kept running while the app was suspended or relaunched.
    private func restoreDownloads() {
        session.getAllTasks { tasks in
            let names = tasks.filter { $0.state == .running || $0.state == .suspended }.compactMap(\.taskDescription)
            Task { @MainActor in
                guard !names.isEmpty else { return }
                self.downloadingSpeech = names.allSatisfy { $0.hasPrefix(Self.speechDirectory + "/") }
                self.phase = .downloading(remaining: names.count)
                self.updateProgress()
            }
        }
    }

    private func updateProgress() {
        let exp = expected
        downloadSizeBytes = exp.values.reduce(0, +)
        guard downloadSizeBytes > 0 else { return }
        let done = exp.keys.reduce(Int64(0)) { $0 + min(written[$1] ?? 0, exp[$1] ?? 0) }
        progress = min(1, Double(done) / Double(downloadSizeBytes))
    }

    /// Called after each download task ends, with the error that ended it (nil on success).
    private func taskEnded(_ name: String?, error: Error?) {
        if let name, let error {
            let urlError = error as? URLError
            if let data = urlError?.downloadTaskResumeData {
                resumeData[name] = data
            }
            if urlError?.code == .cancelled && resumeData[name] == nil {
                return // cancelled by the user
            }
            phase = .failed(error.localizedDescription)
        }
        session.getAllTasks { tasks in
            let remaining = tasks.filter { $0.state == .running || $0.state == .suspended }.count
            Task { @MainActor in self.allTasksSettled(remaining: remaining) }
        }
    }

    private func allTasksSettled(remaining: Int) {
        if remaining > 0 {
            if !phase.isFailed { phase = .downloading(remaining: remaining) }
            return
        }
        refresh()
        if downloadingSpeech ? speechReady : isReady {
            phase = .idle
            expected = [:]
            Notifier.post(title: "Models downloaded", body: downloadingSpeech
                ? "Speech recognition is ready. Add a recording to transcribe it."
                : "Papers is ready. Add a PDF to hear its summary.")
            downloadingSpeech = false
        } else if !phase.isFailed {
            phase = .failed("The download did not finish. Tap Try again to continue.")
        }
    }

    private func listRemoteFiles(repo: String) async throws -> [RemoteFile] {
        let url = URL(string: "https://huggingface.co/api/models/\(repo)/tree/main")!
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw EngineError.load("Hugging Face returned \(http.statusCode) for \(repo). Check your connection and try again.")
        }
        return try JSONDecoder().decode([RemoteFile].self, from: data).filter { $0.type == "file" }
    }

    func deleteSpeechModel() {
        try? FileManager.default.removeItem(at: Self.speechDirectoryURL)
        refresh()
    }

    func deleteModels() {
        try? FileManager.default.removeItem(at: Self.modelsDirectory)
        refresh()
    }

    /// Removes the summary model so the next download fetches the one in `chatRepo`.
    func deleteChatModel() {
        try? FileManager.default.removeItem(at: Self.modelsDirectory.appendingPathComponent(Self.chatDirectory))
        refresh()
    }

    nonisolated static func excludeFromBackup(_ url: URL) {
        var u = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? u.setResourceValues(values)
    }
}

extension ModelStore.Phase {
    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}

extension ModelStore: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                                totalBytesExpectedToWrite: Int64) {
        guard let name = downloadTask.taskDescription else { return }
        Task { @MainActor in
            self.written[name] = totalBytesWritten
            if totalBytesExpectedToWrite > 0, self.expected[name] != totalBytesExpectedToWrite {
                self.expected[name] = totalBytesExpectedToWrite
            }
            self.updateProgress()
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) {
        // the temporary file is deleted when this returns, so move it into place synchronously
        guard let name = downloadTask.taskDescription else { return }
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 200
        let dest = Self.modelsDirectory.appendingPathComponent(name)
        var failure: String?
        if status == 200 {
            do {
                try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: location, to: dest)
                Self.excludeFromBackup(dest)
            } catch {
                failure = "Could not save \(name): \(error.localizedDescription)"
            }
        } else {
            failure = "Downloading \(name) failed with HTTP \(status)."
        }
        if let failure {
            Task { @MainActor in self.phase = .failed(failure) }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let name = task.taskDescription
        Task { @MainActor in self.taskEnded(name, error: error) }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            self.backgroundCompletionHandler?()
            self.backgroundCompletionHandler = nil
        }
    }
}

/// Local notifications for finished downloads and summaries.
enum Notifier {
    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    @MainActor static func post(title: String, body: String) {
        guard UIApplication.shared.applicationState != .active else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
