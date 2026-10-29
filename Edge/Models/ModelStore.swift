import Foundation
import UIKit
import UserNotifications

/// Finds, downloads and imports the models: SenseVoice (hearing), Qwen3.5 (writing) and Kokoro (speaking),
/// and the two GGUF files LFM3-Audio needs when it is chosen for any of those:
/// the backbone ("LFM3-Audio-2B-Q8_0.gguf") and the mmproj (audio encoder, depthformer, codec).
@MainActor
final class ModelStore: NSObject, ObservableObject {
    static let defaultRepo = "LiquidAI/LFM3-Audio-2B-GGUF"
    /// Backbone quantizations in order of preference. Q8_0 first: speech is generated from the backbone's
    /// hidden states, and the 4-bit backbones are far off the reference (Q4_K_M logits ~0.4 rel vs 0.009
    /// for Q8_0 in audio.cpp's validation), which shows up as babbled speech.
    nonisolated static let preferredQuants = ["Q8_0", "F16", "BF16", "Q6_K", "Q5_K_M", "Q4_K_M", "Q4_K_S", "Q4_0"]
    nonisolated static let preferredMMProjQuants = ["Q8_0", "F16", "BF16", "F32"]

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
    static let sessionIdentifier = "com.cadewardc.edge.models"

    @Published private(set) var modelURL: URL?
    @Published private(set) var mmprojURL: URL?
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

    var repo: String {
        let r = UserDefaults.standard.string(forKey: "hfRepo")?.trimmingCharacters(in: .whitespaces) ?? ""
        return r.isEmpty ? Self.defaultRepo : r
    }

    /// Documents is exposed in the Files app, so GGUFs can also be dropped in by hand.
    nonisolated static var modelsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// LFM3-Audio's two files are in place.
    var lfmReady: Bool { modelURL != nil && mmprojURL != nil }
    /// SenseVoice, Qwen3.5 and Kokoro are all in place, so the tutor can work without LFM3-Audio.
    var lightReady: Bool { senseVoiceReady && chatModelURL != nil && kokoroReady }
    /// The tutor can start: with the light models, or with LFM3-Audio doing whatever they can't.
    var isReady: Bool { lfmReady || lightReady }

    /// LFM3-Audio is picked in Settings for hearing, writing or speaking.
    nonisolated static var lfmChosen: Bool {
        let d = UserDefaults.standard
        return d.string(forKey: "asrEngine") == "lfm" || d.string(forKey: "replyEngine") == "lfm"
            || d.string(forKey: "ttsEngine") == "lfm"
    }

    /// A 4-bit (or smaller) backbone: text works, speech comes out as babble.
    var backboneIsLowPrecision: Bool {
        guard let name = modelURL?.lastPathComponent.uppercased() else { return false }
        return ["Q4_", "Q3_", "Q2_", "IQ"].contains { name.contains($0) }
    }

    /// Removes 4-bit backbones once a better one is in place, to free the space.
    private func removeSupersededBackbones() {
        guard let current = modelURL, !backboneIsLowPrecision else { return }
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.modelsDirectory, includingPropertiesForKeys: nil)) ?? []
        for url in files where url.pathExtension.lowercased() == "gguf" && url != current && !Self.isMMProj(url.lastPathComponent) {
            let name = url.lastPathComponent.uppercased()
            if ["Q4_", "Q3_", "Q2_", "IQ"].contains(where: { name.contains($0) }) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

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

    /// Picks the best local backbone and mmproj from the models directory.
    func refresh() {
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.modelsDirectory, includingPropertiesForKeys: nil)) ?? []
        let ggufs = files.filter { $0.pathExtension.lowercased() == "gguf" }
        let names = ggufs.map(\.lastPathComponent)
        modelURL  = Self.pickBackbone(names).map { Self.modelsDirectory.appendingPathComponent($0) }
        mmprojURL = Self.pickMMProj(names).map { Self.modelsDirectory.appendingPathComponent($0) }
        senseVoiceReady = Self.senseVoiceFiles.allSatisfy {
            FileManager.default.fileExists(atPath: Self.modelsDirectory.appendingPathComponent($0).path)
        }
        let chatDir = Self.modelsDirectory.appendingPathComponent(Self.chatDirectory, isDirectory: true)
        let chatFiles = ((try? FileManager.default.contentsOfDirectory(atPath: chatDir.path)) ?? [])
            .filter { $0.lowercased().hasSuffix(".gguf") }
        chatModelURL = Self.pickChatModel(chatFiles).map { chatDir.appendingPathComponent($0) }
        kokoroReady = Self.kokoroFiles.keys.allSatisfy { FileManager.default.fileExists(atPath: Self.kokoroURL($0).path) }
    }

    // MARK: Chat model (Qwen3.5, the tutor's replies)

    nonisolated static let defaultChatRepo = "unsloth/Qwen3.5-2B-GGUF"
    nonisolated static let chatDirectory = "Chat"
    /// 4-5 bit is plenty for text; only LFM3's voice needed 8-bit.
    nonisolated static let preferredChatQuants = ["Q4_K_M", "UD-Q4_K_XL", "Q5_K_M", "Q4_K_S", "Q6_K", "Q8_0"]

    @Published private(set) var chatModelURL: URL?

    var chatRepo: String {
        let r = UserDefaults.standard.string(forKey: "chatRepo")?.trimmingCharacters(in: .whitespaces) ?? ""
        return r.isEmpty ? Self.defaultChatRepo : r
    }

    nonisolated static func pickChatModel(_ names: [String]) -> String? {
        let candidates = names.filter { $0.lowercased().hasSuffix(".gguf") && !isMMProj($0) }
        for q in preferredChatQuants {
            if let hit = candidates.first(where: { $0.uppercased().contains(q) }) { return hit }
        }
        return candidates.first
    }

    // MARK: SenseVoice (speech recognition)

    /// SenseVoice-Small converted for sherpa-onnx: Mandarin speech recognition, separate from LFM3-Audio.
    nonisolated static let senseVoiceRepo = "csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17"
    nonisolated static let senseVoiceFiles = ["SenseVoice/model.int8.onnx", "SenseVoice/tokens.txt"]
    nonisolated static var senseVoiceModelURL: URL { modelsDirectory.appendingPathComponent(senseVoiceFiles[0]) }
    nonisolated static var senseVoiceTokensURL: URL { modelsDirectory.appendingPathComponent(senseVoiceFiles[1]) }
    /// Approximate sizes, for the progress bar until the server reports the real ones.
    private static let senseVoiceSizes: [String: Int64] = [senseVoiceFiles[0]: 229_000_000, senseVoiceFiles[1]: 316_000]

    @Published private(set) var senseVoiceReady = false

    // MARK: Kokoro (the tutor's voice)

    /// Kokoro-82M v1.1-zh as converted by sherpa-onnx, unpacked into a release of this repo
    /// (.github/workflows/mirror-kokoro.yml) since the original is a single .tar.bz2.
    nonisolated static let kokoroBaseURL = "https://github.com/CadeWardC/Edge/releases/download/models-kokoro-int8-v1_1"
    nonisolated static let kokoroDirectory = "Kokoro"
    /// File name and size (for the progress bar).
    nonisolated static let kokoroFiles: [String: Int64] = [
        "model.int8.onnx": 114_203_914, "voices.bin": 53_790_720, "tokens.txt": 1_111,
        "lexicon-zh.txt": 2_120_131, "lexicon-us-en.txt": 5_956_885, "date-zh.fst": 59_154,
        "number-zh.fst": 64_482, "phone-zh.fst": 88_630, "LICENSE": 11_358,
    ]
    nonisolated static func kokoroURL(_ name: String) -> URL {
        modelsDirectory.appendingPathComponent(kokoroDirectory, isDirectory: true).appendingPathComponent(name)
    }

    @Published private(set) var kokoroReady = false

    nonisolated static func isMMProj(_ name: String) -> Bool {
        name.lowercased().contains("mmproj")
    }

    nonisolated static func pickBackbone(_ names: [String]) -> String? {
        let candidates = names.filter { $0.lowercased().hasSuffix(".gguf") && !isMMProj($0) }
        for q in preferredQuants {
            if let hit = candidates.first(where: { $0.uppercased().contains(q) }) { return hit }
        }
        return candidates.first
    }

    nonisolated static func pickMMProj(_ names: [String]) -> String? {
        let candidates = names.filter { $0.lowercased().hasSuffix(".gguf") && isMMProj($0) }
        for q in preferredMMProjQuants {
            if let hit = candidates.first(where: { $0.uppercased().contains(q) }) { return hit }
        }
        return candidates.first
    }

    // MARK: Download

    func download() async {
        guard phase == .idle || phase.isFailed else { return }
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
            // the LFM3-Audio files: listed from the repo, only when it is chosen in Settings and its files
            // are missing or 4-bit
            var jobs: [(name: String, url: URL)] = []
            var sizes: [String: Int64] = Self.senseVoiceSizes
            for (file, size) in Self.kokoroFiles { sizes["\(Self.kokoroDirectory)/\(file)"] = size }
            if Self.lfmChosen && (!lfmReady || backboneIsLowPrecision) {
                let remote = try await listRemoteFiles(repo: repo)
                let names = remote.map(\.path)
                guard let backbone = Self.pickBackbone(names) else {
                    throw LFMError.load("No model GGUF found in \(repo).")
                }
                guard let mmproj = Self.pickMMProj(names) else {
                    throw LFMError.load("No mmproj GGUF found in \(repo).")
                }
                for (path, size) in remote.map({ ($0.path, $0.size ?? 0) }) { sizes[path] = size }
                jobs += [backbone, mmproj].filter(missing).map { (name: $0, url: resolveURL(repo, $0)) }
            }
            // the chat model, kept in its own folder; a failed lookup does not hold back the rest
            if chatModelURL == nil, let remote = try? await listRemoteFiles(repo: chatRepo),
               let file = Self.pickChatModel(remote.map(\.path)) {
                let name = "\(Self.chatDirectory)/\(file)"
                sizes[name] = remote.first { $0.path == file }?.size ?? 0
                if missing(name) { jobs.append((name: name, url: resolveURL(chatRepo, file))) }
            }
            // the SenseVoice files, kept in their own folder
            jobs += Self.senseVoiceFiles.filter(missing).map {
                (name: $0, url: resolveURL(Self.senseVoiceRepo, String($0.split(separator: "/").last!)))
            }
            // the Kokoro files, from this app's own release
            jobs += Self.kokoroFiles.keys.sorted().filter { !FileManager.default.fileExists(atPath: Self.kokoroURL($0).path) }.map {
                (name: "\(Self.kokoroDirectory)/\($0)", url: URL(string: "\(Self.kokoroBaseURL)/\($0)")!)
            }
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
        if isReady {
            phase = .idle
            expected = [:]
            removeSupersededBackbones()
            Notifier.post(title: "Models downloaded", body: "Your tutor is ready. Tap to start speaking Mandarin.")
        } else if !phase.isFailed {
            phase = .failed("The download did not finish. Tap Try again to continue.")
        }
    }

    private func listRemoteFiles(repo: String) async throws -> [RemoteFile] {
        let url = URL(string: "https://huggingface.co/api/models/\(repo)/tree/main")!
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw LFMError.load("Hugging Face returned \(http.statusCode) for \(repo). Check the repo name in Settings.")
        }
        return try JSONDecoder().decode([RemoteFile].self, from: data).filter { $0.type == "file" }
    }

    // MARK: Import

    /// Copies user-picked GGUFs into the models directory.
    func importFiles(_ urls: [URL]) {
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let dest = Self.modelsDirectory.appendingPathComponent(url.lastPathComponent)
            try? FileManager.default.removeItem(at: dest)
            do {
                try FileManager.default.copyItem(at: url, to: dest)
                Self.excludeFromBackup(dest)
            } catch {
                phase = .failed("Import failed: \(error.localizedDescription)")
            }
        }
        refresh()
    }

    /// Removes only LFM3-Audio's GGUFs, for when the other models do everything.
    func deleteLFM() {
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.modelsDirectory, includingPropertiesForKeys: nil)) ?? []
        for url in files where url.pathExtension.lowercased() == "gguf" {
            try? FileManager.default.removeItem(at: url)
        }
        refresh()
    }

    func deleteModels() {
        for url in [modelURL, mmprojURL].compactMap({ $0 }) {
            try? FileManager.default.removeItem(at: url)
        }
        try? FileManager.default.removeItem(at: Self.senseVoiceModelURL.deletingLastPathComponent())
        try? FileManager.default.removeItem(at: Self.modelsDirectory.appendingPathComponent(Self.chatDirectory))
        try? FileManager.default.removeItem(at: Self.modelsDirectory.appendingPathComponent(Self.kokoroDirectory))
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
            if (self.expected[name] ?? 0) <= 0, totalBytesExpectedToWrite > 0 {
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

/// Local notification for when the model finishes downloading in the background.
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
