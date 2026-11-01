import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The system file picker, copying the chosen files into the app first. Copies work for every location
/// (iCloud Drive files that aren't downloaded yet, other apps' folders) without security-scoped access.
struct DocumentPicker: UIViewControllerRepresentable {
    let types: [UTType]
    var allowsMultiple = false
    let onPick: ([URL]) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.allowsMultipleSelection = allowsMultiple
        picker.shouldShowFileExtensions = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: ([URL]) -> Void
        init(onPick: @escaping ([URL]) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            // the copies live in a temporary inbox that iOS may clear; move them somewhere stable first
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Picked", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let kept = urls.map { url -> URL in
                let dest = dir.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
                do {
                    try FileManager.default.moveItem(at: url, to: dest)
                    return dest
                } catch {
                    return url
                }
            }
            onPick(kept)
        }
    }
}

extension UTType {
    /// Voice Memos (.m4a), other recordings, and videos with sound.
    static let voiceRecordings: [UTType] = [
        UTType("com.apple.m4a-audio"), .mpeg4Audio, .audio, .wav, .mp3, .aiff,
        UTType("com.apple.coreaudio-format"), .movie, .mpeg4Movie, .quickTimeMovie, .audiovisualContent,
    ].compactMap { $0 }
}

extension URL {
    /// The file's name without extension and without the "<UUID>-" prefix the picker's copies get.
    var pickedFileName: String {
        let base = deletingPathExtension().lastPathComponent
        if base.count > 37, UUID(uuidString: String(base.prefix(36))) != nil,
           base[base.index(base.startIndex, offsetBy: 36)] == "-" {
            return String(base.dropFirst(37))
        }
        return base
    }
}
