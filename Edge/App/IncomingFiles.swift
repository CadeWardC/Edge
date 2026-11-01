import Foundation
import UniformTypeIdentifiers

/// Files shared to Edge from other apps: recordings (Voice Memos, Files) become voices, PDFs become papers.
@MainActor
final class IncomingFiles: ObservableObject {
    static let shared = IncomingFiles()

    enum Tab: Hashable { case papers, speak, voices, settings }

    @Published var tab: Tab = .papers
    /// A shared recording waiting for "Add a voice".
    @Published var voiceRecording: IdentifiedURL?
    @Published var error: String?

    struct IdentifiedURL: Identifiable {
        let url: URL
        var id: URL { url }
    }

    func handle(_ url: URL) {
        let type = UTType(filenameExtension: url.pathExtension.lowercased())
        if type?.conforms(to: .pdf) == true {
            do {
                _ = try PaperLibrary.shared.importPDF(url)
                tab = .papers
            } catch {
                self.error = error.localizedDescription
            }
            Self.removeIfInbox(url)
        } else if type?.conforms(to: .audio) == true || type?.conforms(to: .audiovisualContent) == true {
            tab = .voices
            voiceRecording = IdentifiedURL(url: Self.copyIn(url))
        } else {
            error = "Edge can open PDFs and voice recordings, not \(url.lastPathComponent)."
        }
    }

    /// A private copy of a shared file, made while access to the original is granted.
    static func copyIn(_ url: URL) -> URL {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Picked", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
        var copied = false
        NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: nil) { readable in
            copied = (try? FileManager.default.copyItem(at: readable, to: dest)) != nil
        }
        guard copied else { return url }
        removeIfInbox(url)
        return dest
    }

    /// Files shared with "Copy to Edge" land in Documents/Inbox; they are removed once used.
    nonisolated static func removeIfInbox(_ url: URL) {
        if url.pathComponents.contains("Inbox") {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
