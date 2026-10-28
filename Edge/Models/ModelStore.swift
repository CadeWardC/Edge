import Foundation
import UIKit

/// Finds, downloads and imports the two GGUF files LFM3-Audio needs:
/// the backbone ("LFM3-Audio-2B-Q4_K_M.gguf") and the mmproj (audio encoder, depthformer, codec).
@MainActor
final class ModelStore: NSObject, ObservableObject {
    static let defaultRepo = "LiquidAI/LFM3-Audio-2B-GGUF"
    /// Backbone quantizations in order of preference: small enough for a phone, good enough for Mandarin.
    static let preferredQuants = ["Q4_K_M", "Q4_K_S", "Q5_K_M", "Q4_0", "Q8_0", "F16"]
    static let preferredMMProjQuants = ["Q8_0", "F16", "BF16", "F32"]

    struct RemoteFile: Decodable {
        let type: String
        let path: String
        let size: Int64?
    }

    enum Phase: Equatable {
        case idle
        case resolving
        case downloading(file: String, index: Int, count: Int)
        case failed(String)
    }

    @Published private(set) var modelURL: URL?
    @Published private(set) var mmprojURL: URL?
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var progress: Double = 0
    @Published private(set) var downloadSizeBytes: Int64 = 0

    private var session: URLSession!
    private var continuation: CheckedContinuation<URL, Error>?
    private var currentDestination: URL?
    private var currentTask: URLSessionDownloadTask?
    private var completedBytes: Int64 = 0

    var repo: String {
        let r = UserDefaults.standard.string(forKey: "hfRepo")?.trimmingCharacters(in: .whitespaces) ?? ""
        return r.isEmpty ? Self.defaultRepo : r
    }

    /// Documents is exposed in the Files app, so GGUFs can also be dropped in by hand.
    static var modelsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    var isReady: Bool { modelURL != nil && mmprojURL != nil }

    override init() {
        super.init()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 60 * 60 * 6
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        refresh()
    }

    /// Picks the best local backbone and mmproj from the models directory.
    func refresh() {
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.modelsDirectory, includingPropertiesForKeys: nil)) ?? []
        let ggufs = files.filter { $0.pathExtension.lowercased() == "gguf" }
        let names = ggufs.map(\.lastPathComponent)
        modelURL  = Self.pickBackbone(names).map { Self.modelsDirectory.appendingPathComponent($0) }
        mmprojURL = Self.pickMMProj(names).map { Self.modelsDirectory.appendingPathComponent($0) }
    }

    static func isMMProj(_ name: String) -> Bool {
        name.lowercased().contains("mmproj")
    }

    static func pickBackbone(_ names: [String]) -> String? {
        let candidates = names.filter { $0.lowercased().hasSuffix(".gguf") && !isMMProj($0) }
        for q in preferredQuants {
            if let hit = candidates.first(where: { $0.uppercased().contains(q) }) { return hit }
        }
        return candidates.first
    }

    static func pickMMProj(_ names: [String]) -> String? {
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
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = false }

        do {
            let remote = try await listRemoteFiles()
            let names = remote.map(\.path)
            guard let backbone = Self.pickBackbone(names) else {
                throw LFMError.load("No model GGUF found in \(repo).")
            }
            guard let mmproj = Self.pickMMProj(names) else {
                throw LFMError.load("No mmproj GGUF found in \(repo).")
            }
            let wanted = [backbone, mmproj].filter {
                !FileManager.default.fileExists(atPath: Self.modelsDirectory.appendingPathComponent($0).path)
            }
            let sizes = Dictionary(remote.map { ($0.path, $0.size ?? 0) }, uniquingKeysWith: { a, _ in a })
            downloadSizeBytes = wanted.reduce(0) { $0 + (sizes[$1] ?? 0) }
            completedBytes = 0

            for (i, name) in wanted.enumerated() {
                phase = .downloading(file: name, index: i + 1, count: wanted.count)
                let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
                let url = URL(string: "https://huggingface.co/\(repo)/resolve/main/\(encoded)?download=true")!
                let dest = Self.modelsDirectory.appendingPathComponent(name)
                _ = try await downloadFile(from: url, to: dest)
                completedBytes += sizes[name] ?? 0
            }
            phase = .idle
            refresh()
        } catch {
            if (error as? URLError)?.code == .cancelled {
                phase = .idle
            } else {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func cancelDownload() {
        currentTask?.cancel()
    }

    private func listRemoteFiles() async throws -> [RemoteFile] {
        let url = URL(string: "https://huggingface.co/api/models/\(repo)/tree/main")!
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw LFMError.load("Hugging Face returned \(http.statusCode) for \(repo). Check the repo name in Settings.")
        }
        return try JSONDecoder().decode([RemoteFile].self, from: data).filter { $0.type == "file" }
    }

    private func downloadFile(from url: URL, to dest: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { cont in
            self.continuation = cont
            self.currentDestination = dest
            let task = session.downloadTask(with: url)
            self.currentTask = task
            task.resume()
        }
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

    func deleteModels() {
        for url in [modelURL, mmprojURL].compactMap({ $0 }) {
            try? FileManager.default.removeItem(at: url)
        }
        refresh()
    }

    static func excludeFromBackup(_ url: URL) {
        var u = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? u.setResourceValues(values)
    }

    fileprivate func finish(_ result: Result<URL, Error>) {
        currentTask = nil
        continuation?.resume(with: result)
        continuation = nil
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
        Task { @MainActor in
            let total = self.downloadSizeBytes > 0 ? self.downloadSizeBytes : totalBytesExpectedToWrite
            guard total > 0 else { return }
            self.progress = min(1, Double(self.completedBytes + totalBytesWritten) / Double(total))
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) {
        // the temporary file is deleted when this returns, so move it synchronously
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 200
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let moved = Result<URL, Error>(catching: {
            guard status == 200 else { throw LFMError.load("Download failed with HTTP \(status).") }
            try FileManager.default.moveItem(at: location, to: staging)
            return staging
        })
        Task { @MainActor in
            guard let dest = self.currentDestination else { return }
            self.finish(moved.flatMap { staged in
                Result<URL, Error>(catching: {
                    try? FileManager.default.removeItem(at: dest)
                    try FileManager.default.moveItem(at: staged, to: dest)
                    ModelStore.excludeFromBackup(dest)
                    return dest
                })
            })
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        Task { @MainActor in self.finish(.failure(error)) }
    }
}
