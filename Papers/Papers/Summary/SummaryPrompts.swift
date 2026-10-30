import Foundation

/// What the summary model (Qwen3.5-2B, thinking off) is asked. A paper is too long to read in one go, so it reads
/// the paper a part at a time and takes notes, then writes the script one section at a time from those notes.
enum SummaryPrompts {
    /// Words per section: four sections of about 210 words plus the signposts is about 900 words,
    /// which Kokoro reads in five to six minutes.
    static let wordsPerSection = 210

    static func title(firstPage: String) -> [TextRuntime.Message] {
        [
            .init(role: "system", content: "You find the titles of research papers."),
            .init(role: "user", content: """
                Here is the start of a research paper:

                \(firstPage)

                What is the title of this paper? Reply with the title only, on one line, exactly as written.
                """),
        ]
    }

    static func notes(title: String, part: Int, of parts: Int, text: String) -> [TextRuntime.Message] {
        [
            .init(role: "system", content: """
                You are a careful research assistant. You read one part of a scientific paper at a time and take \
                short, factual notes. You only write what the text says.
                """),
            .init(role: "user", content: """
                This is part \(part) of \(parts) of the paper "\(title)".

                <part>
                \(text)
                </part>

                Write notes on this part, at most 120 words, as short plain sentences. Cover only what this part says about:
                - the research question or goal,
                - why it matters (the problem, what was not known),
                - what the researchers did (data, methods, experiments),
                - what they found (results, with the key numbers) and what it means.
                Skip anything this part does not cover. If this part is only references, acknowledgements or \
                tables of numbers with no explanation, write NONE.
                """),
        ]
    }

    static func section(_ kind: SectionKind, title: String, opening: String, notes: [String],
                        previous: [Paper.Section]) -> [TextRuntime.Message] {
        let noteText = notes.enumerated()
            .filter { !isEmptyNote($0.element) }
            .map { "Part \($0.offset + 1): \($0.element)" }
            .joined(separator: "\n\n")
        var user = """
            Paper: \(title)

            The opening of the paper:
            \(opening)

            Notes on the whole paper:
            \(noteText)

            """
        if !previous.isEmpty {
            user += """

                The script so far (do not repeat it):
                \(previous.map(\.text).joined(separator: "\n\n"))

                """
        }
        user += """

            Now write the part of the script about \(focus(kind)). \
            Write about \(wordsPerSection) words as one or two paragraphs of plain spoken English. \
            Do not repeat the title, do not start with "In this paper" or "This study", and do not add a heading.
            """
        return [
            .init(role: "system", content: """
                You write the script of a five minute audio summary of a research paper. The listener is smart but \
                not an expert in this field, and wants a framework for reading the paper. Write for the ear: short \
                sentences, no lists, no headings, no markdown, no citations, no figure or table numbers, no formulas \
                and no URLs. Explain each abbreviation the first time you use it. Only use facts from the notes \
                and the opening of the paper.
                """),
            .init(role: "user", content: user),
        ]
    }

    static func focus(_ kind: SectionKind) -> String {
        switch kind {
        case .question:
            return "what question the researchers are asking: the problem they look at and the specific question or hypothesis they test"
        case .importance:
            return "why this research matters: the background, what was not known or not working before, and who would care about the answer"
        case .methods:
            return "what the researchers did: their approach, the data or participants, and the experiments or analyses, explained simply"
        case .findings:
            return "what they discovered: the main findings with the most important numbers, what the findings mean, and any limits the authors mention"
        }
    }

    static func isEmptyNote(_ note: String) -> Bool {
        let t = note.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty || t.uppercased().hasPrefix("NONE")
    }

    /// Strips what a small model sometimes adds anyway: think blocks, markdown, headings and bullet marks.
    static func cleanScript(_ raw: String) -> String {
        var s = raw
        if let end = s.range(of: "</think>") { s = String(s[end.upperBound...]) }
        s = s.replacingOccurrences(of: "<think>", with: "")
        var lines: [String] = []
        for line in s.components(separatedBy: .newlines) {
            var l = line.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("#") { continue }                                  // headings
            l = SpokenText.replace(l, "^([-*•]|\\d+[.)])\\s+") { _ in "" }   // bullets
            l = l.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
            l = SpokenText.replace(l, "(?<![A-Za-z])\\*|`") { _ in "" }
            l = SpokenText.replace(l, "\\[[0-9,\\s–-]+\\]") { _ in "" }      // citation numbers
            // a heading line like "Why it matters:" on its own
            if l.hasSuffix(":"), l.split(separator: " ").count <= 5 { continue }
            lines.append(l)
        }
        return lines.joined(separator: "\n")
            .replacingOccurrences(of: "\n\n\n", with: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func cleanTitle(_ raw: String) -> String? {
        var t = cleanScript(raw).components(separatedBy: .newlines).first ?? ""
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: " \"'*“”"))
        if t.lowercased().hasPrefix("title:") { t = String(t.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
        return (5...250).contains(t.count) ? t : nil
    }

    static func wordCount(_ s: String) -> Int {
        s.split(whereSeparator: { $0.isWhitespace }).count
    }
}
