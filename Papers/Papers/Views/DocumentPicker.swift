import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The system file picker, handing back copies of the chosen files.
///
/// Used instead of SwiftUI's `.fileImporter`: with one importer in each tab (PDFs in Papers, recordings in Audio),
/// SwiftUI's importers interfere and a picked file can simply be dropped. Copies (`asCopy`) also avoid
/// security-scoped access and files in iCloud Drive that are not downloaded yet.
struct DocumentPicker: UIViewControllerRepresentable {
    let types: [UTType]
    let onPick: ([URL]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.allowsMultipleSelection = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: ([URL]) -> Void

        init(onPick: @escaping ([URL]) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onPick(urls)
        }
    }

    /// Removes the picker's copy once the library has its own.
    static func discardCopy(_ url: URL) {
        let tmp = FileManager.default.temporaryDirectory.standardizedFileURL.path
        if url.standardizedFileURL.path.hasPrefix(tmp) { try? FileManager.default.removeItem(at: url) }
    }
}
