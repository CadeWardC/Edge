import Foundation

/// Finds the passages of a document that best match a query (BM25), so each writing step sees the paper's or the
/// transcript's own words and not only the notes about them. Grounding the model in the source is what keeps a
/// small model from filling gaps with invented detail.
struct PassageIndex {
    let passages: [String]
    private let termFreqs: [[String: Int]]
    private let docFreq: [String: Int]
    private let lengths: [Int]
    private let averageLength: Double

    /// Splits `text` into passages of about `size` characters at sentence ends.
    init(text: String, size: Int = 900) {
        var passages: [String] = []
        var current = ""
        for sentence in Self.sentences(text) {
            if current.count + sentence.count > size, !current.isEmpty {
                passages.append(current)
                current = ""
            }
            current += (current.isEmpty ? "" : " ") + sentence
        }
        if !current.isEmpty { passages.append(current) }
        self.passages = passages
        termFreqs = passages.map { passage in
            Self.terms(passage).reduce(into: [:]) { $0[$1, default: 0] += 1 }
        }
        var df: [String: Int] = [:]
        for tf in termFreqs { for term in tf.keys { df[term, default: 0] += 1 } }
        docFreq = df
        lengths = termFreqs.map { $0.values.reduce(0, +) }
        averageLength = Double(max(lengths.reduce(0, +), 1)) / Double(max(passages.count, 1))
    }

    /// The best passages for `query`, in document order, together at most `budget` characters.
    /// Passages that contain one of `boost` (for example "Figure 2") come first.
    func excerpts(for query: String, budget: Int = 3200, boost: [String] = []) -> String {
        let queryTerms = Set(Self.terms(query))
        let n = Double(passages.count)
        var scored: [(index: Int, score: Double)] = []
        for (i, tf) in termFreqs.enumerated() {
            var score = 0.0
            for term in queryTerms {
                guard let f = tf[term] else { continue }
                let df = Double(docFreq[term] ?? 0)
                let idf = log(1 + (n - df + 0.5) / (df + 0.5))
                let freq = Double(f)
                score += idf * freq * 2.2 / (freq + 1.2 * (0.25 + 0.75 * Double(lengths[i]) / averageLength))
            }
            if boost.contains(where: { Self.containsLabel(passages[i], $0) }) {
                score += 100
            }
            if score > 0 { scored.append((i, score)) }
        }
        var chosen: [Int] = []
        var used = 0
        for candidate in scored.sorted(by: { $0.score > $1.score }) {
            let length = passages[candidate.index].count
            if used + length > budget { continue }
            chosen.append(candidate.index)
            used += length
        }
        return chosen.sorted().map { "[…] " + passages[$0] }.joined(separator: "\n\n")
    }

    /// "Figure 2" but not "Figure 21".
    private static func containsLabel(_ passage: String, _ label: String) -> Bool {
        var search = passage.startIndex..<passage.endIndex
        while let r = passage.range(of: label, options: [.caseInsensitive], range: search) {
            if r.upperBound == passage.endIndex || !passage[r.upperBound].isNumber { return true }
            search = r.upperBound..<passage.endIndex
        }
        return false
    }

    private static let stopWords: Set<String> = [
        "the", "a", "an", "and", "or", "of", "to", "in", "on", "for", "with", "by", "is", "are", "was", "were", "be",
        "been", "this", "that", "these", "those", "it", "its", "as", "at", "from", "we", "our", "their", "they", "which",
        "what", "how", "why", "did", "does", "do", "can", "not", "but", "than", "into", "also", "has", "have", "had",
        "about", "between", "each", "paper", "study", "authors", "researchers", "there", "such", "more", "most",
    ]

    static func terms(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count > 1 && !stopWords.contains($0) }
            .map(stem)
    }

    /// A light stemmer, enough to match "experiments" with "experiment".
    private static func stem(_ w: String) -> String {
        for suffix in ["ing", "ies", "es", "ed", "s"] where w.count > suffix.count + 3 && w.hasSuffix(suffix) {
            return String(w.dropLast(suffix.count))
        }
        return w
    }

    static func sentences(_ text: String) -> [String] {
        var out: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: [.bySentences, .localized]) { sub, _, _, _ in
            if let s = sub?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty { out.append(s) }
        }
        return out
    }
}

/// Removes sentences that state a number the source never mentions: the commonest way a small model invents
/// results. Only multi-digit numbers, decimals and percentages are checked ("1" or "two" are too common to judge).
enum Grounding {
    static func removeUnsupportedNumbers(_ text: String, source: String) -> String {
        let sourceNumbers = Set(numbers(in: source))
        let paragraphs = text.components(separatedBy: "\n")
        return paragraphs.map { paragraph -> String in
            PassageIndex.sentences(paragraph)
                .filter { sentence in numbers(in: sentence).allSatisfy { sourceNumbers.contains($0) } }
                .joined(separator: " ")
        }
        .filter { !$0.isEmpty }
        .joined(separator: "\n\n")
    }

    /// Numbers worth checking, normalized ("1,200" -> "1200", "0.50" -> "0.5").
    static func numbers(in text: String) -> [String] {
        let pattern = "(?<![A-Za-z0-9.])(\\d{1,3}(?:,\\d{3})+|\\d+\\.\\d+|\\d{2,})(?![A-Za-z0-9])"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            var n = ns.substring(with: m.range(at: 1)).replacingOccurrences(of: ",", with: "")
            if n.contains(".") {
                while n.hasSuffix("0") { n.removeLast() }
                if n.hasSuffix(".") { n.removeLast() }
            }
            // years and small counts are rarely invented results; keep the check on real measurements
            if let v = Double(n), v < 10, !n.contains(".") { return nil }
            return n
        }
    }
}
