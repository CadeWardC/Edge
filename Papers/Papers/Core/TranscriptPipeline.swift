import Foundation

struct TranscriptSummary: Codable, Equatable {
    var title: String
    var overview: String
    var keyPoints: [String]
    var actionItems: [String]
}

/// Summarizes a transcript into bullet points: long transcripts are read a part at a time into bullet notes,
/// which are then merged into the final summary.
enum TranscriptPipeline {
    /// About 1,800 tokens of transcript per part.
    static let partCharacters = 7_000

    static func text(_ segments: [TranscriptSegment]) -> String {
        segments.map { "[\(timestamp($0.start))] \($0.text)" }.joined(separator: "\n")
    }

    static func parts(_ segments: [TranscriptSegment]) -> [String] {
        var parts: [String] = []
        var current = ""
        for line in text(segments).components(separatedBy: "\n") {
            if current.count + line.count > partCharacters, !current.isEmpty {
                parts.append(current)
                current = ""
            }
            current += (current.isEmpty ? "" : "\n") + line
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }

    static func notes(part: String, index: Int, of count: Int, writer: TextWriter) async throws -> String {
        let reply = try await writer.write([
            .init(role: "system", content: """
                You take precise notes on transcripts. You copy names, numbers, dates and decisions exactly, and \
                never add anything that was not said.
                """),
            .init(role: "user", content: """
                This is part \(index + 1) of \(count) of a transcript (timestamps in brackets).

                <transcript>
                \(part)
                </transcript>

                Write bullet notes on this part: every main point, fact, number, decision and action item (with who \
                and when, if said). When the speaker says "I will", write "the speaker will", not a name. One short \
                line per bullet, each starting with "- ". Write nothing else.
                """),
        ], maxTokens: 600, temperature: 0)
        return PaperPipeline.clean(reply)
    }

    static func summarize(notes: [String], transcript: String, writer: TextWriter) async throws -> TranscriptSummary {
        let material = notes.count == 1 && transcript.count <= partCharacters
            ? "TRANSCRIPT:\n" + transcript
            : "NOTES ON THE TRANSCRIPT, IN ORDER:\n" + notes.joined(separator: "\n")
        let reply = try await writer.write([
            .init(role: "system", content: """
                You summarize transcripts into clear bullet points. You only use what was said, copy names and \
                numbers exactly, and never invent anything.
                """),
            .init(role: "user", content: """
                \(material)

                Write the summary in exactly this format:
                TITLE: a short title, at most 8 words
                OVERVIEW: one or two sentences on what this is about
                KEY POINTS:
                - the most important points, 5 to 12 bullets, most important first, each one specific and self-contained
                ACTION ITEMS:
                - each task, decision or follow-up that was stated, with who and when if said; or "- none"
                Attribute a task to a person only if the transcript names them for it; when the speaker says "I \
                will", write "The speaker will". Do not merge separate items.
                """),
        ], maxTokens: 900, temperature: 0.2)
        return parse(PaperPipeline.clean(reply), source: transcript)
    }

    static func parse(_ text: String, source: String) -> TranscriptSummary {
        var title = "", overview = ""
        var keyPoints: [String] = [], actions: [String] = []
        enum Section { case none, key, actions }
        var section = Section.none
        let said = Set(Grounding.numbers(in: source))
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let upper = line.uppercased()
            if upper.hasPrefix("TITLE:") {
                title = String(line.dropFirst(6)).trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
                section = .none
            } else if upper.hasPrefix("OVERVIEW:") {
                overview = String(line.dropFirst(9)).trimmingCharacters(in: .whitespaces)
                section = .none
            } else if upper.hasPrefix("KEY POINTS") {
                section = .key
            } else if upper.hasPrefix("ACTION ITEMS") {
                section = .actions
            } else if !line.isEmpty {
                let item = SpokenText.replace(line, "^([-*•]|\\d+[.)])\\s*") { _ in "" }
                guard item.count > 2, !PaperPipeline.isNone(item) else { continue }
                // a bullet that cites a number nobody said is dropped
                guard Grounding.numbers(in: item).allSatisfy({ said.contains($0) }) else { continue }
                switch section {
                case .key: keyPoints.append(item)
                case .actions: actions.append(item)
                case .none: if overview.isEmpty { overview = item } else if keyPoints.isEmpty { overview += " " + item }
                }
            }
        }
        return TranscriptSummary(title: title, overview: overview, keyPoints: keyPoints, actionItems: actions)
    }

    static func timestamp(_ seconds: Double) -> String {
        let s = Int(seconds)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}
