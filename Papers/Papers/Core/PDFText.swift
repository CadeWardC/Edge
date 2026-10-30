import Foundation
import PDFKit
import Vision

/// Pulls the text out of a PDF (PDFKit, or on-device OCR with Vision for scanned pages), cleans it and cuts it
/// into chunks the summary model can read one at a time.
enum PDFText {
    struct Extracted {
        var text: String
        var metadataTitle: String?
    }

    /// The longest paper text that is read; anything beyond (long appendices) is left out.
    static let maxCharacters = 150_000

    static func extract(from url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> Extracted {
        try await Task.detached(priority: .userInitiated) {
            guard let doc = PDFDocument(url: url) else {
                throw EngineError.inference("This PDF could not be opened.")
            }
            if doc.isLocked && !doc.unlock(withPassword: "") {
                throw EngineError.inference("This PDF is password protected.")
            }
            var pages: [String] = []
            for i in 0..<doc.pageCount {
                try Task.checkCancellation()
                guard let page = doc.page(at: i) else { continue }
                var text = page.string ?? ""
                if text.filter({ !$0.isWhitespace }).count < 80 {
                    // a scanned page: read it with OCR
                    text = ocr(page) ?? text
                }
                pages.append(text)
                progress(Double(i + 1) / Double(max(doc.pageCount, 1)))
            }
            let cleaned = clean(pages: pages)
            guard cleaned.count > 400 else {
                throw EngineError.inference("No readable text was found in this PDF.")
            }
            let title = (doc.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String).flatMap(plausibleTitle)
            return Extracted(text: cleaned, metadataTitle: title)
        }.value
    }

    /// Recognizes the text of a page image on device.
    private static func ocr(_ page: PDFPage) -> String? {
        let bounds = page.bounds(for: .mediaBox)
        let scale = 2000 / max(bounds.width, bounds.height, 1)
        let image = page.thumbnail(of: CGSize(width: bounds.width * scale, height: bounds.height * scale), for: .mediaBox)
        #if canImport(UIKit)
        guard let cg = image.cgImage else { return nil }
        #else
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        #endif
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["en-US"]
        do {
            try VNImageRequestHandler(cgImage: cg).perform([request])
        } catch {
            return nil
        }
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: "\n")
    }

    // MARK: Cleaning

    static func clean(pages: [String]) -> String {
        // running headers and footers repeat on many pages
        var lineCounts: [String: Int] = [:]
        let pageLines = pages.map { $0.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) } }
        for lines in pageLines {
            for line in Set(lines) where !line.isEmpty && line.count < 100 {
                lineCounts[line.lowercased(), default: 0] += 1
            }
        }
        let repeatThreshold = max(3, pages.count / 3)

        var lines: [String] = []
        for pageLinesOfPage in pageLines {
            for line in pageLinesOfPage {
                if line.isEmpty { lines.append(""); continue }
                if (lineCounts[line.lowercased()] ?? 0) >= repeatThreshold { continue }
                // page numbers and lone figure ticks
                if line.count <= 4, line.allSatisfy({ $0.isNumber || $0.isPunctuation || $0.isWhitespace }) { continue }
                lines.append(line)
            }
            lines.append("")
        }

        // cut the reference list (the last "References" heading in the second half of the paper)
        let referenceHeadings: Set<String> = ["references", "bibliography", "literature cited", "works cited",
                                              "reference list", "references and notes", "cited literature"]
        if let cut = lines.indices.last(where: { i in
            let l = lines[i].lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " .:0123456789IVX"))
            return referenceHeadings.contains(l)
        }), cut > lines.count * 2 / 5 {
            lines = Array(lines[..<cut])
        }

        // join lines into running text, fixing words split by a hyphen at the end of a line
        var text = ""
        for line in lines {
            if line.isEmpty {
                if !text.hasSuffix("\n\n") { text += "\n\n" }
                continue
            }
            if text.hasSuffix("-"), let first = line.first, first.isLowercase {
                text.removeLast()
                text += line
            } else if text.isEmpty || text.hasSuffix("\n") {
                text += line
            } else {
                text += " " + line
            }
        }
        text = joinLigatures(text)
        text = SpokenText.replace(text, "[ \\t]{2,}") { _ in " " }
        text = SpokenText.replace(text, "\\n{3,}") { _ in "\n\n" }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count > maxCharacters {
            text = String(text.prefix(maxCharacters))
        }
        return text
    }

    /// Some PDFs (PLOS among them) put a space after an "fi", "fl" or "ff" ligature glyph: "scientifi c fi ndings",
    /// "eff ect". That breaks retrieval, grounding and pronunciation, so the halves are joined again.
    static func joinLigatures(_ text: String) -> String {
        // no English word ends in "fi" or "fl" except a few like "hi-fi", which a hyphen protects
        var s = SpokenText.replace(text, "(?<![A-Za-z-])([A-Za-z]*f[il]) ([a-z]+)") { m in m[1] + m[2] }
        // many words end in "ff" ("cutoff value"), so only the continuations of split ligatures are joined
        s = SpokenText.replace(s, "(?<![A-Za-z-])([A-Za-z]*ff) ((?:ect|erent|erenc|er|ort|ici|usi|use|ord|ix)[a-z]*)") { m in
            ["off", "staff", "stuff", "cliff", "tariff", "sheriff", "plaintiff"].contains(m[1].lowercased()) ? m[0] : m[1] + m[2]
        }
        return s
    }

    static func plausibleTitle(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = t.lowercased()
        guard (12...250).contains(t.count), t.contains(" "),
              !lower.hasSuffix(".pdf"), !lower.hasSuffix(".doc"), !lower.hasSuffix(".docx"), !lower.hasSuffix(".tex"),
              !lower.contains("microsoft word"), !lower.hasPrefix("untitled") else { return nil }
        return t
    }

    // MARK: Figures

    struct Figure: Equatable {
        /// "Figure 2" or "Table 1"
        var label: String
        var caption: String
    }

    /// The captions of the paper's figures and tables ("Figure 2. Accuracy of ..."), in order, one per label.
    static func figures(in text: String, limit: Int = 6) -> [Figure] {
        let pattern = "(?:^|\\n|\\. )\\s*((?:Figure|Fig\\.|FIGURE|Table|TABLE)\\s*(\\d{1,2}))\\s*[.:|—–-]\\s*([A-Z(][^\\n]{20,600})"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        var seen = Set<String>()
        var out: [Figure] = []
        for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let kind = ns.substring(with: m.range(at: 1)).lowercased().hasPrefix("t") ? "Table" : "Figure"
            let label = "\(kind) \(ns.substring(with: m.range(at: 2)))"
            guard !seen.contains(label) else { continue }
            var caption = ns.substring(with: m.range(at: 3))
            // keep the caption to its first few sentences
            let sentences = caption.components(separatedBy: ". ")
            if sentences.count > 3 { caption = sentences.prefix(3).joined(separator: ". ") + "." }
            seen.insert(label)
            out.append(Figure(label: label, caption: caption.trimmingCharacters(in: .whitespaces)))
        }
        // figures first (they carry the paper's evidence), then tables, each in order
        let figuresFirst = out.filter { $0.label.hasPrefix("Figure") } + out.filter { $0.label.hasPrefix("Table") }
        return Array(figuresFirst.prefix(limit))
    }

    // MARK: Chunks

    /// Splits the text into at most `maxChunks` pieces of roughly equal size, at paragraph or sentence breaks.
    /// About 9,000 characters (2,300 tokens) each for a typical paper.
    static func chunks(_ text: String, maxChunks: Int = 10) -> [String] {
        let target = max(9_000, Int((Double(text.count) / Double(maxChunks)).rounded(.up)))
        var chunks: [String] = []
        var rest = Substring(text)
        while !rest.isEmpty {
            if rest.count <= Int(Double(target) * 1.3) {
                chunks.append(String(rest))
                break
            }
            let limit = rest.index(rest.startIndex, offsetBy: target)
            let window = rest[rest.index(rest.startIndex, offsetBy: target * 3 / 4)..<limit]
            let breakAt = window.range(of: "\n\n", options: .backwards)?.upperBound
                ?? window.range(of: ". ", options: .backwards)?.upperBound
                ?? limit
            chunks.append(String(rest[..<breakAt]).trimmingCharacters(in: .whitespacesAndNewlines))
            rest = rest[breakAt...]
        }
        return chunks.filter { !$0.isEmpty }
    }
}
