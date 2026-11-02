import Foundation
import UIKit

struct AppError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// The on-device speech models Shuō downloads.
enum SpeechModel: String, CaseIterable, Identifiable, Codable {
    /// SenseVoice-Small: understands spoken Mandarin (much better with learners than the iPhone's recognizer).
    case recognition
    /// Kokoro v1.1-zh: a natural Mandarin voice for the replies.
    case voice

    var id: String { rawValue }
    var title: String { self == .recognition ? "Mandarin recognition" : "Mandarin voice" }
    var modelName: String { self == .recognition ? "SenseVoice" : "Kokoro" }
    var detail: String {
        self == .recognition
            ? "SenseVoice: hears learners' Mandarin accurately, on the phone. Until it is downloaded, the iPhone's recognizer is used."
            : "Kokoro: a natural Mandarin voice (100 voices). Until it is downloaded, the iPhone's Chinese voice is used."
    }
    var pack: String { self == .recognition ? "sensevoice" : "kokoro-zh" }
    var approximateBytes: Int64 { self == .recognition ? 240_000_000 : 400_000_000 }
}

/// Downloads the speech models in the background and unpacks them into Documents/Models/<pack>.
@MainActor
final class ModelStore: NSObject, ObservableObject {
    static let shared = ModelStore()
    static let sessionIdentifier = "com.cadewardc.shuo.models"
    nonisolated static let releaseURL = "https://github.com/CadeWardC/Edge/releases/download/models-shuo-v1"

    enum State: Equatable {
        case missing
        case downloading(Double)
        case installing
        case ready
        case failed(String)
    }

    @Published private(set) var states: [SpeechModel: State] = [:]

    /// Handed over by the app delegate when iOS wakes the app for a finished background download.
    var backgroundCompletionHandler: (() -> Void)?

    private var session: URLSession!

    nonisolated static var modelsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Models", isDirectory: true)
    }

    nonisolated static func directory(_ model: SpeechModel) -> URL {
        modelsDirectory.appendingPathComponent(model.pack, isDirectory: true)
    }

    /// Written last when unpacking, so a half-unpacked model never counts as installed.
    nonisolated private static func marker(_ model: SpeechModel) -> URL {
        directory(model).appendingPathComponent(".installed")
    }

    nonisolated static func isInstalled(_ model: SpeechModel) -> Bool {
        FileManager.default.fileExists(atPath: marker(model).path)
    }

    private override init() {
        super.init()
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.timeoutIntervalForResource = 60 * 60 * 24
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        for m in SpeechModel.allCases {
            states[m] = Self.isInstalled(m) ? .ready : .missing
        }
        // downloads that kept running while the app was closed
        session.getAllTasks { tasks in
            let running = tasks.filter { $0.state == .running }.compactMap(\.taskDescription)
            Task { @MainActor in
                for name in running {
                    if let m = SpeechModel(rawValue: name) { self.states[m] = .downloading(0) }
                }
            }
        }
    }

    func state(_ model: SpeechModel) -> State { states[model] ?? .missing }
    func isReady(_ model: SpeechModel) -> Bool { state(model) == .ready }

    func download(_ model: SpeechModel) {
        switch state(model) {
        case .downloading, .installing, .ready: return
        default: break
        }
        let url = URL(string: "\(Self.releaseURL)/\(model.pack).tar")!
        let task = session.downloadTask(with: url)
        task.taskDescription = model.rawValue
        task.countOfBytesClientExpectsToReceive = model.approximateBytes
        task.resume()
        states[model] = .downloading(0)
    }

    func cancel(_ model: SpeechModel) {
        session.getAllTasks { tasks in
            tasks.filter { $0.taskDescription == model.rawValue }.forEach { $0.cancel() }
        }
        states[model] = Self.isInstalled(model) ? .ready : .missing
    }

    func delete(_ model: SpeechModel) {
        SpeechEngines.shared.unload()
        try? FileManager.default.removeItem(at: Self.directory(model))
        states[model] = .missing
    }

    fileprivate func finished(_ model: SpeechModel, tar: URL?, error: String?) {
        if let error {
            states[model] = .failed(error)
            return
        }
        guard let tar else { return }
        states[model] = .installing
        Task.detached(priority: .userInitiated) {
            let result: String?
            do {
                try? FileManager.default.removeItem(at: Self.directory(model))
                try TarExtractor.extract(tar, to: Self.modelsDirectory)
                try Data().write(to: Self.marker(model))
                var dir = Self.modelsDirectory
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                try? dir.setResourceValues(values)
                result = nil
            } catch {
                try? FileManager.default.removeItem(at: Self.directory(model))
                result = "Unpacking failed: \(error.localizedDescription)"
            }
            try? FileManager.default.removeItem(at: tar)
            await MainActor.run {
                self.states[model] = result.map { .failed($0) } ?? .ready
            }
            if result == nil { SpeechEngines.shared.warmUp() }
        }
    }
}

extension ModelStore: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                                totalBytesExpectedToWrite: Int64) {
        guard let name = downloadTask.taskDescription, let model = SpeechModel(rawValue: name) else { return }
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : model.approximateBytes
        let fraction = min(1, Double(totalBytesWritten) / Double(total))
        Task { @MainActor in
            if case .downloading = self.state(model) { self.states[model] = .downloading(fraction) }
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) {
        // the temporary file is deleted when this returns, so move it first
        guard let name = downloadTask.taskDescription, let model = SpeechModel(rawValue: name) else { return }
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 200
        guard status == 200 else {
            Task { @MainActor in self.finished(model, tar: nil, error: "Download failed (HTTP \(status)).") }
            return
        }
        let dest = ModelStore.modelsDirectory.appendingPathComponent("\(model.pack).tar")
        do {
            try FileManager.default.createDirectory(at: ModelStore.modelsDirectory, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: location, to: dest)
            Task { @MainActor in self.finished(model, tar: dest, error: nil) }
        } catch {
            let message = "Could not save the download: \(error.localizedDescription)"
            Task { @MainActor in self.finished(model, tar: nil, error: message) }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let name = task.taskDescription, let model = SpeechModel(rawValue: name) else { return }
        if (error as? URLError)?.code == .cancelled { return }
        let message = error.localizedDescription
        Task { @MainActor in self.finished(model, tar: nil, error: message) }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            self.backgroundCompletionHandler?()
            self.backgroundCompletionHandler = nil
        }
    }
}

/// Unpacks a plain (ustar) tar file, streaming each entry to disk.
enum TarExtractor {
    static func extract(_ tar: URL, to destination: URL) throws {
        let handle = try FileHandle(forReadingFrom: tar)
        defer { try? handle.close() }
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)

        while true {
            guard let raw = try handle.read(upToCount: 512), raw.count == 512 else { break }
            let header = [UInt8](raw)
            if header.allSatisfy({ $0 == 0 }) { break }   // end of archive

            let name = field(header, 0, 100)
            let prefix = field(header, 345, 155)
            let path = prefix.isEmpty ? name : "\(prefix)/\(name)"
            let size = Int(field(header, 124, 12).trimmingCharacters(in: .whitespaces), radix: 8) ?? 0
            let type = header[156]
            let padding = (512 - size % 512) % 512

            let parts = path.split(separator: "/").map(String.init)
            guard !path.hasPrefix("/"), !parts.contains("..") else {
                throw AppError("The model archive has an unsafe path: \(path)")
            }
            let target = destination.appendingPathComponent(path)

            switch type {
            case UInt8(ascii: "5"):
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
                try skip(handle, padding)
            case 0, UInt8(ascii: "0"):
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                fm.createFile(atPath: target.path, contents: nil)
                let out = try FileHandle(forWritingTo: target)
                var remaining = size
                while remaining > 0 {
                    let n = min(remaining, 1 << 20)
                    guard let chunk = try handle.read(upToCount: n), !chunk.isEmpty else {
                        try? out.close()
                        throw AppError("The model archive is cut short.")
                    }
                    try out.write(contentsOf: chunk)
                    remaining -= chunk.count
                }
                try out.close()
                try skip(handle, padding)
            default:
                // links, extended headers: not used by the model archives
                try skip(handle, size + padding)
            }
        }
    }

    private static func field(_ header: [UInt8], _ offset: Int, _ length: Int) -> String {
        let bytes = header[offset..<(offset + length)].prefix { $0 != 0 }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func skip(_ handle: FileHandle, _ count: Int) throws {
        guard count > 0 else { return }
        let offset = try handle.offset()
        try handle.seek(toOffset: offset + UInt64(count))
    }
}
