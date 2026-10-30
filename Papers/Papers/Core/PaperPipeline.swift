import Foundation

/// Everything the summary model is asked about a paper, shared by the app and the macOS test harness.
///
/// A paper does not fit a small model's attention in one go, so it is read a part at a time into structured notes
/// (question, motivation, methods, experiments, figures, findings, limitations). Every piece of the script is then
/// written from the notes that matter for it plus passages retrieved from the paper itself, and sentences that
/// cite numbers the paper does not contain are removed.
struct PaperSource {
    let title: String
    let text: String
    let chunks: [String]
    let index: PassageIndex
    let figures: [PDFText.Figure]

    init(title: String, text: String) {
        self.title = title
        self.text = text
        chunks = PDFText.chunks(text)
        index = PassageIndex(text: text)
        figures = PDFText.figures(in: text)
    }

    /// The abstract and the start of the introduction.
    var opening: String { String(text.prefix(1500)) }
}

/// The notes on all parts, merged by heading.
struct PaperNotes {
    enum Field: String, CaseIterable {
        case question = "QUESTION", motivation = "MOTIVATION", methods = "METHODS", experiments = "EXPERIMENTS"
        case figures = "FIGURES", findings = "FINDINGS", limitations = "LIMITATIONS"
        /// Plain facts, when a part could not be noted under the headings.
        case facts = "FACTS"
    }

    private(set) var lines: [Field: [String]] = [:]

    init(_ notes: [String]) {
        for note in notes {
            var field: Field?
            for raw in note.components(separatedBy: .newlines) {
                var line = raw.trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: "**", with: "")
                    .trimmingCharacters(in: CharacterSet(charactersIn: "#").union(.whitespaces))
                // the model often writes the headings as bullets too: "- QUESTION: ..."
                line = SpokenText.replace(line, "^([-*•]|\\d+[.)])\\s*") { _ in "" }
                // a heading is "QUESTION:" or "QUESTION" on its own, not a sentence that starts with the word
                if let f = Field.allCases.first(where: { field in
                    let upper = line.uppercased()
                    guard upper.hasPrefix(field.rawValue) else { return false }
                    let rest = upper.dropFirst(field.rawValue.count).trimmingCharacters(in: .whitespaces)
                    return rest.isEmpty || rest.hasPrefix(":")
                }) {
                    field = f
                    line = String(line.dropFirst(f.rawValue.count)).trimmingCharacters(in: CharacterSet(charactersIn: ": ").union(.whitespaces))
                }
                line = SpokenText.replace(line, "^([-*•]|\\d+[.)])\\s*") { _ in "" }
                guard let field, line.count > 3, !PaperPipeline.isNone(line) else { continue }
                if !(lines[field] ?? []).contains(line) { lines[field, default: []].append(line) }
            }
        }
    }

    /// The number of noted lines.
    var count: Int { lines.values.reduce(0) { $0 + $1.count } }

    /// The lines under `fields` (plus the plain facts, if any), as "HEADING:\n- line" blocks, at most `budget`
    /// characters.
    func text(_ fields: [Field], budget: Int = 5000) -> String {
        let fields = fields.contains(.facts) || (lines[.facts] ?? []).isEmpty ? fields : fields + [.facts]
        let share = budget / max(fields.count, 1)
        return fields.compactMap { field -> String? in
            guard let items = lines[field], !items.isEmpty else { return nil }
            var block = "\(field.rawValue):"
            for item in items where block.count + item.count < share {
                block += "\n- " + item
            }
            return block
        }.joined(separator: "\n\n")
    }

    var isEmpty: Bool { lines.values.allSatisfy(\.isEmpty) }
}

/// One planned part of the in-depth audio.
struct DeepItem: Codable, Equatable {
    enum Kind: String, Codable { case findings, experiment, figure, limitations, unknowns }

    var kind: Kind
    var id: String
    var heading: String
    /// What the second voice asks before this part.
    var hostLine: String
    /// For an experiment, its name and what it tests; for a figure, its label and caption.
    var subject: String = ""
    var detail: String = ""
    /// How long this part should be, so the whole in-depth audio lasts 10 to 15 minutes.
    var words: Int = 0
}

enum PaperPipeline {
    // MARK: Reading

    static func title(_ source: String, writer: TextWriter) async throws -> String? {
        let reply = try await writer.write([
            .init(role: "system", content: "You find the titles of research papers."),
            .init(role: "user", content: """
                Here is the start of a research paper:

                \(String(source.prefix(2000)))

                What is the title of this paper? Reply with the title only, on one line, exactly as written.
                """),
        ], maxTokens: 80, temperature: 0)
        var t = clean(reply).components(separatedBy: .newlines).first ?? ""
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: " \"'*“”"))
        if t.lowercased().hasPrefix("title:") { t = String(t.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
        return (5...250).contains(t.count) ? t : nil
    }

    static let notesSystem = """
        You extract facts from scientific papers. You copy facts exactly, including numbers, units, names and \
        comparisons. You never add anything that is not in the text.
        """

    /// Notes on one part of the paper under fixed headings. A small model sometimes answers a long part with
    /// almost nothing; then the part is asked about again as a plain list of facts.
    static func notes(_ source: PaperSource, part: Int, writer: TextWriter) async throws -> String {
        let raw = try await writer.write([
            .init(role: "system", content: notesSystem),
            .init(role: "user", content: """
                Take notes on part \(part + 1) of \(source.chunks.count) of the paper "\(source.title)", printed below.

                Use these headings, in this order:
                QUESTION: the research question, aim or hypothesis
                MOTIVATION: why it matters; the problem or gap
                METHODS: data, participants, materials, models and procedures
                EXPERIMENTS: each experiment or analysis: what was tested, how, and its result with numbers
                FIGURES: each figure or table this part describes, as "Figure N: what it shows"
                FINDINGS: the main results and conclusions, with numbers
                LIMITATIONS: limitations or caveats the authors state
                Under each heading write short factual lines starting with "- ", copying numbers and names exactly. \
                Leave out a heading if this part says nothing about it. Cover everything important in this part.

                PART \(part + 1):
                \(source.chunks[part])

                Now write the notes on part \(part + 1), starting with the first heading that applies.
                """),
        ], maxTokens: 900, temperature: 0)
        let reply = clean(raw)
        if PaperNotes([reply]).count >= 3 { return reply }

        let rawFacts = try await writer.write([
            .init(role: "system", content: notesSystem),
            .init(role: "user", content: """
                Here is part \(part + 1) of \(source.chunks.count) of the paper "\(source.title)":

                \(source.chunks[part])

                List the 8 to 15 most important facts in this part: what the researchers asked, did and found, \
                with numbers and names copied exactly. One fact per line, each starting with "- ".
                """),
        ], maxTokens: 700, temperature: 0.2)
        return reply + "\n\nFACTS:\n" + clean(rawFacts)
    }

    // MARK: The overview (5 to 6 minutes)

    enum OverviewPart: String, CaseIterable, Codable {
        case question, importance, methods, findings

        var heading: String {
            switch self {
            case .question: return "The question"
            case .importance: return "Why it matters"
            case .methods: return "What they did"
            case .findings: return "What they found"
            }
        }

        var hostLine: String {
            switch self {
            case .question: return "So, what question are these researchers asking?"
            case .importance: return "And why does that matter?"
            case .methods: return "What did they actually do?"
            case .findings: return "And what did they find?"
            }
        }
    }

    static let overviewWords = 250

    static func overview(_ part: OverviewPart, source: PaperSource, notes: PaperNotes, previous: [String],
                         writer: TextWriter) async throws -> String {
        let (task, fields, query): (String, [PaperNotes.Field], String)
        switch part {
        case .question:
            task = "Explain what question the researchers are asking: the problem they look at and the specific question or hypothesis they test."
            fields = [.question, .motivation]
            query = "aim objective question hypothesis investigate propose goal whether"
        case .importance:
            task = "Explain why this research matters: the background, what was unknown or not working before, and who would care about the answer."
            fields = [.motivation, .question]
            query = "important challenge problem however remains unknown limited prior previous work gap"
        case .methods:
            task = "Explain what the researchers did: their approach, the data or participants, and the main experiments or analyses, simply."
            fields = [.methods, .experiments]
            query = "method data dataset participants experiment trained measured procedure approach design"
        case .findings:
            task = "Explain what they discovered: the main findings with the most important numbers, and what they mean."
            fields = [.findings, .experiments]
            query = "result show found significant improve outperform achieve conclude demonstrate"
        }
        return try await writePart(task: task, words: overviewWords, source: source, notes: notes.text(fields),
                                   excerpts: source.opening + "\n\n" + source.index.excerpts(for: query, budget: 2400),
                                   avoid: previous, writer: writer)
    }

    // MARK: The in-depth audio (10 to 15 minutes)

    /// Main findings, then each experiment, each figure, the limitations and what is not established.
    static func planDeep(source: PaperSource, notes: PaperNotes, writer: TextWriter) async throws -> [DeepItem] {
        var items = [DeepItem(kind: .findings, id: "findings", heading: "The main findings",
                              hostLine: "Let's go deeper. What exactly did this paper find?")]

        let experiments = try await experimentList(notes: notes, writer: writer)
        for (i, e) in experiments.enumerated() {
            let host: String
            switch i {
            case 0: host = "Let's walk through the evidence. The first experiment: \(e.name). What does it demonstrate?"
            case experiments.count - 1: host = "And the last one: \(e.name). What does that show?"
            default: host = "Next: \(e.name). What does this one demonstrate?"
            }
            items.append(DeepItem(kind: .experiment, id: "experiment-\(i + 1)", heading: e.name.prefix(1).uppercased() + e.name.dropFirst(),
                                  hostLine: host, subject: e.name, detail: e.tests))
        }

        let figures = source.figures.prefix(5)
        for (i, f) in figures.enumerated() {
            let host = i == 0
                ? "Now the figures. Start with \(f.label). What's in it, and how does it back up the conclusions?"
                : "What about \(f.label)?"
            items.append(DeepItem(kind: .figure, id: "figure-\(i + 1)", heading: f.label, hostLine: host,
                                  subject: f.label, detail: f.caption))
        }
        if figures.isEmpty, !(notes.lines[.figures] ?? []).isEmpty {
            items.append(DeepItem(kind: .figure, id: "figures", heading: "The figures",
                                  hostLine: "How do the figures back up the conclusions?"))
        }

        items.append(DeepItem(kind: .limitations, id: "limitations", heading: "Limitations and weaknesses",
                              hostLine: "So where is this paper weakest?"))
        items.append(DeepItem(kind: .unknowns, id: "unknowns", heading: "What isn't established yet",
                              hostLine: "Last question. What hasn't this research established?"))
        return sized(items)
    }

    /// About 2,000 words in all (12 to 13 minutes): papers with few experiments and figures get longer parts.
    static func sized(_ items: [DeepItem], total: Int = 2000) -> [DeepItem] {
        func base(_ kind: DeepItem.Kind) -> Double {
            switch kind {
            case .findings: return 320
            case .experiment: return 180
            case .figure: return 140
            case .limitations: return 300
            case .unknowns: return 250
            }
        }
        let sum = items.reduce(0) { $0 + base($1.kind) }
        let scale = Double(total) / max(sum, 1)
        return items.map { item in
            var sized = item
            sized.words = min(max(Int((base(item.kind) * scale / 10).rounded()) * 10, 110), 480)
            return sized
        }
    }

    static func experimentList(notes: PaperNotes, writer: TextWriter) async throws -> [(name: String, tests: String)] {
        let source = notes.text([.experiments, .methods], budget: 4000)
        guard !source.isEmpty else { return [] }
        let reply = try await writer.write([
            .init(role: "system", content: "You organize notes on research papers. You only use what the notes say."),
            .init(role: "user", content: """
                NOTES:
                \(source)

                List the main experiments or analyses in this paper, at most 4, most important first. Merge notes \
                that describe the same experiment. Give each a short descriptive name of 2 to 7 words that says what \
                was tested (for example "English constituency parsing" or "Varying the number of attention heads"), \
                not "Experiment 1", "Methods" or "Results". Write one per line, exactly as:
                name :: what it tests
                Write nothing else.
                """),
        ], maxTokens: 220, temperature: 0)
        var out: [(String, String)] = []
        for line in clean(reply).components(separatedBy: .newlines) {
            let parts = line.components(separatedBy: "::")
            guard parts.count >= 2 else { continue }
            var name = parts[0].trimmingCharacters(in: .whitespaces)
            var previous = ""
            while previous != name {
                previous = name
                name = SpokenText.replace(name, "^([-*•]|\\d+[.)]|(Experiment|Analysis|Study)\\s*\\d*[:.]?)\\s*") { _ in "" }
                    .trimmingCharacters(in: CharacterSet(charactersIn: " \"'()"))
            }
            let generic: Set<String> = ["methods", "method", "results", "result", "findings", "data", "experiments",
                                        "experiment", "analysis", "evaluation", "setup", "training", "discussion"]
            if generic.contains(name.lowercased()) { continue }
            let tests = parts[1...].joined(separator: " ").trimmingCharacters(in: .whitespaces)
            guard (3...80).contains(name.count), !out.contains(where: { $0.0.lowercased() == name.lowercased() }) else { continue }
            out.append((name, tests))
        }
        return Array(out.prefix(4))
    }

    static func deep(_ item: DeepItem, source: PaperSource, notes: PaperNotes, covered: [String],
                     writer: TextWriter) async throws -> String {
        let task: String, words: Int, fields: [PaperNotes.Field], excerpts: String
        switch item.kind {
        case .findings:
            task = "Explain the main findings in depth: each key result, the evidence and numbers behind it, and what it means."
            words = 320
            fields = [.findings, .experiments]
            excerpts = source.index.excerpts(for: "result show found significant improve outperform achieve conclude demonstrate evidence", budget: 3200)
        case .experiment:
            task = """
                Explain the experiment "\(item.subject)" (\(item.detail)): what exactly was done, what it was \
                designed to test, what came out, and what it demonstrates and what it does not.
                """
            words = 180
            fields = [.experiments, .methods, .findings]
            excerpts = source.index.excerpts(for: item.subject + " " + item.detail, budget: 3000)
        case .figure:
            if item.subject.isEmpty {
                task = "Explain what the paper's figures and tables show, and how they support the conclusions."
                excerpts = source.index.excerpts(for: "figure table shows plot panel", budget: 2800)
            } else {
                task = """
                    Explain \(item.subject), whose caption reads: "\(item.detail)". Describe what it shows in a way \
                    a listener can picture without seeing it, then how it supports (or only partly supports) the \
                    paper's conclusions.
                    """
                // passages that refer to the figure by its label: "Figure 2", "Fig. 2", "Fig 2" or "Table 2"
                let number = item.subject.components(separatedBy: " ").last ?? ""
                let labels = item.subject.hasPrefix("Table")
                    ? ["Table \(number)"]
                    : ["Figure \(number)", "Fig. \(number)", "Fig \(number)"]
                excerpts = source.index.excerpts(for: item.detail, budget: 2800, boost: labels)
            }
            words = 140
            fields = [.figures, .findings]
        case .limitations:
            task = """
                Explain the limitations and weaknesses. First the ones the authors acknowledge, then weaknesses a \
                careful reader would notice from how the study was done, for example the size or kind of data, \
                missing comparisons, or how results were measured. Make clear which are the authors' own and which \
                are a reader's concerns, and only raise concerns that follow from what the paper describes.
                """
            words = 300
            fields = [.limitations, .methods, .experiments]
            excerpts = source.index.excerpts(for: "limitation however future work caveat bias small sample only restricted assume cannot", budget: 3200)
        case .unknowns:
            task = """
                Explain what the researchers have not established: which questions stay open, where the evidence \
                stops short (for example correlation versus cause, other settings or populations, long-term \
                effects, or mechanisms), and what would be needed to settle them. Stay with what follows from \
                the paper.
                """
            words = 250
            fields = [.findings, .limitations, .question]
            excerpts = source.index.excerpts(for: "future work remains unclear unknown further open question limitation generalize", budget: 2800)
        }
        return try await writePart(task: task, words: item.words > 0 ? item.words : words, source: source,
                                   notes: notes.text(fields), excerpts: excerpts, avoid: covered, writer: writer)
    }

    // MARK: Questions

    static func questions(source: PaperSource, notes: PaperNotes, writer: TextWriter) async throws -> [String] {
        let input = notes.text([.question, .methods, .experiments, .findings, .limitations], budget: 5000)
        var found: [String] = []
        for temperature: Float in [0.3, 0.7] where found.count < 6 {
            let reply = try await writer.write([
                .init(role: "system", content: "You write study questions about research papers, for a reader who wants to understand the paper deeply."),
                .init(role: "user", content: """
                    PAPER: \(source.title)

                    NOTES:
                    \(input)

                    Write 8 study questions that test deep understanding of this paper's science: why and how \
                    questions about its research question, its methods, its key results, the evidence behind its \
                    claims, and its limits. Good questions look like "Why does ... lead to ...?", "What evidence \
                    shows that ...?", "How did the researchers test whether ...?" or "What does ... not show?". Each \
                    question must be answerable from the notes. Never ask about the authors, the journal, the \
                    conference, the year or why the paper was published. Write one question per line, each ending \
                    with a question mark. No numbering and no answers.
                    """),
            ], maxTokens: 400, temperature: temperature)
            for line in clean(reply).components(separatedBy: .newlines) {
                let q = SpokenText.replace(line.trimmingCharacters(in: .whitespaces), "^([-*•]|\\d+[.)]|Q\\d*[.:])\\s*") { _ in "" }
                let offTopic = ["author", "journal", "conference", "publish", "nips", "neurips", "affiliation", "venue"]
                guard q.hasSuffix("?"), (15...300).contains(q.count),
                      !offTopic.contains(where: { q.lowercased().contains($0) }),
                      !found.contains(where: { $0.lowercased() == q.lowercased() }) else { continue }
                found.append(q)
            }
        }
        return Array(found.prefix(10))
    }

    static func answer(_ question: String, source: PaperSource, notes: PaperNotes, writer: TextWriter) async throws -> String {
        try await writePart(
            task: """
                Answer this question in depth: "\(question)" Answer from the excerpts and notes, starting with the \
                direct answer. If the paper does not address it, say so in one or two sentences instead of guessing; \
                if it only partly settles it, say plainly what it does and does not show.
                """,
            words: 140, source: source,
            notes: notes.text([.findings, .experiments, .methods, .limitations], budget: 3000),
            excerpts: source.index.excerpts(for: question, budget: 2800), avoid: [], writer: writer)
    }

    // MARK: Writing

    static let systemPrompt = """
        You write scripts for an audio show that explains research papers to a smart, curious listener who is not \
        an expert in the field.
        Rules:
        - Use only facts found in the NOTES and EXCERPTS. If something is not there, leave it out. Never invent \
        numbers, names, methods or results.
        - Write for the ear: plain words, varied sentence length, concrete details from the paper, and only rarely \
        a rhetorical question. No lists, headings, markdown, citations, URLs, equations or figure numbers in brackets.
        - Start with the substance of the task. Never open with "Imagine", "Picture", "Think of" or a metaphor, and \
        do not re-introduce the paper or repeat background the listener has already heard.
        - Keep abbreviations and names exactly as the paper writes them; do not expand an abbreviation unless the \
        paper itself says what it stands for.
        - Do not list the authors, their affiliations, the journal, the conference or the year; the listener wants \
        the science. Never guess at the authors' motives.
        - Say numbers and symbols in words a listener can follow: no math notation, subscripts or symbols.
        - Explain each technical term or abbreviation briefly the first time you use it.
        - Be engaging but not hyped: no "groundbreaking", "revolutionary" or "game-changer".
        - Do not greet the listener, do not say "in this paper" or "in this episode", and do not end with a summary.
        """

    static func writePart(task: String, words: Int, source: PaperSource, notes: String, excerpts: String,
                          avoid: [String], writer: TextWriter) async throws -> String {
        var user = """
            PAPER: \(source.title)

            NOTES:
            \(notes.isEmpty ? "(none)" : notes)

            EXCERPTS FROM THE PAPER:
            \(excerpts)

            """
        if !avoid.isEmpty {
            user += "\nALREADY COVERED (do not repeat):\n" + avoid.map { "- " + firstSentence($0) }.joined(separator: "\n") + "\n"
        }
        user += "\nTASK: \(task) Write about \(words) words of spoken script, in one to three paragraphs."
        let messages: [TextRuntime.Message] = [.init(role: "system", content: systemPrompt), .init(role: "user", content: user)]
        let budget = Int32(Double(words) * 1.7) + 80

        var best = ""
        for temperature: Float in [0.4, 0.6] {
            let reply = try await writer.write(messages, maxTokens: budget, temperature: temperature)
            let text = Grounding.removeUnsupportedNumbers(spoken(clean(reply)), source: source.text)
            if wordCount(text) > wordCount(best) { best = text }
            if wordCount(best) >= words / 2 { break }   // long enough; a second try is only for a failed one
        }
        return best
    }

    // MARK: Scripts

    static func overviewScript(title: String, parts: [(OverviewPart, String)]) -> [ScriptLine] {
        var lines = [ScriptLine(speaker: .narrator, text: "Here's an overview of the paper \(title).",
                                chapter: OverviewPart.question.heading, pauseAfter: 0.8)]
        for (i, (part, text)) in parts.enumerated() {
            lines.append(ScriptLine(speaker: .host, text: part.hostLine, chapter: i == 0 ? nil : part.heading, pauseAfter: 0.45))
            lines.append(ScriptLine(speaker: .narrator, text: text, pauseAfter: 1.0))
        }
        lines.append(ScriptLine(speaker: .host, text: "That's the overview. Now you have a framework for reading the paper.", pauseAfter: 0.5))
        return lines
    }

    static func deepScript(title: String, parts: [(DeepItem, String)]) -> [ScriptLine] {
        var lines = [ScriptLine(speaker: .narrator, text: "This is the in-depth look at \(title).", pauseAfter: 0.7)]
        for (item, text) in parts where !text.isEmpty {
            lines.append(ScriptLine(speaker: .host, text: item.hostLine, chapter: item.heading, pauseAfter: 0.45))
            lines.append(ScriptLine(speaker: .narrator, text: text, pauseAfter: 1.0))
        }
        lines.append(ScriptLine(speaker: .host, text: "That's the deep dive. Try the questions next, to check your understanding.", pauseAfter: 0.5))
        return lines
    }

    static func questionsScript(title: String, items: [(question: String, answer: String)]) -> [ScriptLine] {
        var lines = [ScriptLine(speaker: .narrator, text: "Questions on \(title). After each one, pause and try to answer it before you hear the answer.", pauseAfter: 0.8)]
        for (i, qa) in items.enumerated() where !qa.answer.isEmpty {
            lines.append(ScriptLine(speaker: .host, text: "Question \(i + 1). \(qa.question)", chapter: "Question \(i + 1)", pauseAfter: 4.0))
            lines.append(ScriptLine(speaker: .narrator, text: qa.answer, pauseAfter: 1.2))
        }
        return lines
    }

    // MARK: Text helpers

    /// Strips what a small model sometimes adds anyway: think blocks, markdown, headings and bullet marks.
    static func clean(_ raw: String) -> String {
        var s = raw
        if let end = s.range(of: "</think>") { s = String(s[end.upperBound...]) }
        s = s.replacingOccurrences(of: "<think>", with: "")
        var lines: [String] = []
        for line in s.components(separatedBy: .newlines) {
            var l = line.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("#") { l = l.trimmingCharacters(in: CharacterSet(charactersIn: "# ")) }
            l = l.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
            l = SpokenText.replace(l, "`") { _ in "" }
            l = SpokenText.replace(l, "\\s?\\[[0-9,\\s–-]+\\]") { _ in "" }   // citation numbers
            lines.append(l)
        }
        return lines.joined(separator: "\n")
            .replacingOccurrences(of: "\n\n\n", with: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `clean`, then drops list marks and lines that are only a heading, for text that will be read aloud.
    static func spoken(_ text: String) -> String {
        text.components(separatedBy: .newlines).compactMap { line -> String? in
            var l = SpokenText.replace(line, "^([-*•]|\\d+[.)])\\s+") { _ in "" }
            // inline LaTeX the model copied from the notes: $d_k$ -> d k, \sqrt -> square root
            l = SpokenText.replace(l, "\\\\sqrt") { _ in "square root of " }
            l = SpokenText.replace(l, "\\\\(text|mathrm|mathbf|frac|cdot|left|right)") { _ in " " }
            l = SpokenText.replace(l, "[$_{}\\\\^]") { _ in " " }
            l = SpokenText.replace(l, "[ \\t]{2,}") { _ in " " }
            if l.hasSuffix(":"), l.split(separator: " ").count <= 5 { return nil }
            return l
        }.joined(separator: "\n")
    }

    static func isNone(_ line: String) -> Bool {
        let l = line.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " .-"))
        return l.isEmpty || l == "none" || l.hasPrefix("none ") || l == "n/a" || l.hasPrefix("not mentioned")
            || l.hasPrefix("not stated") || l.hasPrefix("no information")
    }

    static func wordCount(_ s: String) -> Int {
        s.split(whereSeparator: { $0.isWhitespace }).count
    }

    static func firstSentence(_ s: String) -> String {
        let first = PassageIndex.sentences(s).first ?? s
        return String(first.prefix(200))
    }
}
