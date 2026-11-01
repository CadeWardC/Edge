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
            voiceRecording = IdentifiedURL(url: url)
        } else {
            error = "Edge can open PDFs and voice recordings, not \(url.lastPathComponent)."
        }
    }

    /// Files shared with "Copy to Edge" land in Documents/Inbox; they are removed once used.
    nonisolated static func removeIfInbox(_ url: URL) {
        if url.pathComponents.contains("Inbox") {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
