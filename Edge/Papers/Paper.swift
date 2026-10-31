import Foundation

/// An imported paper and its audio series.
struct Paper: Identifiable, Codable, Equatable {
    enum Stage: String, Codable {
        case new, writing, voicing, done, failed
    }

    struct Part: Identifiable, Codable, Equatable {
        var id: Int            // 1-based position in the series
        var title: String
        var focus: String
        var script: String = ""
        /// Seconds of audio, once it has been voiced.
        var duration: Double?
    }

    var id = UUID()
    var title: String
    var added = Date()
    var stage: Stage = .new
    var message: String?
    var parts: [Part] = []

    // how this paper's series is made (starts from the defaults in Settings)
    var partsCount: Int
    var minutesPerPart: Int
    var voiceID: UUID?
    var model: VoiceModel
    /// nil uses the prompt from Settings.
    var customPrompt: String?

    var totalDuration: Double { parts.compactMap(\.duration).reduce(0, +) }
    var hasScripts: Bool { !parts.isEmpty && parts.allSatisfy { !$0.script.isEmpty } }
}

/// The saved papers: Documents/Papers/<id>/paper.pdf, text.txt and part-N.m4a, indexed in papers.json.
@MainActor
final class PaperLibrary: ObservableObject {
    static let shared = PaperLibrary()

    @Published private(set) var papers: [Paper] = []

    nonisolated static var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Papers", isDirectory: true)
    }
    nonisolated static func folder(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString, isDirectory: true) }
    nonisolated static func pdfURL(_ id: UUID) -> URL { folder(id).appendingPathComponent("paper.pdf") }
    nonisolated static func textURL(_ id: UUID) -> URL { folder(id).appendingPathComponent("text.txt") }
    nonisolated static func audioURL(_ id: UUID, part: Int) -> URL { folder(id).appendingPathComponent("part-\(part).m4a") }
    private static var indexURL: URL { directory.appendingPathComponent("papers.json") }

    private init() {
        if let data = try? Data(contentsOf: Self.indexURL),
           var saved = try? JSONDecoder().decode([Paper].self, from: data) {
            // work that was running when the app was closed did not finish
            for i in saved.indices where saved[i].stage == .writing || saved[i].stage == .voicing {
                saved[i].stage = .failed
                saved[i].message = "Stopped when the app closed. Tap Make audio to continue."
            }
            papers = saved
        }
    }

    func paper(_ id: UUID) -> Paper? { papers.first { $0.id == id } }

    func importPDF(_ url: URL) throws -> Paper {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let d = UserDefaults.standard
        var paper = Paper(
            title: url.deletingPathExtension().lastPathComponent,
            partsCount: AppSettings.partsCount,
            minutesPerPart: AppSettings.minutesPerPart,
            voiceID: d.string(forKey: AppSettings.Key.defaultVoice).flatMap(UUID.init(uuidString:)),
            model: AppSettings.voiceModel
        )
        if paper.voiceID == nil { paper.voiceID = VoiceLibrary.shared.voices.first?.id }
        try FileManager.default.createDirectory(at: Self.folder(paper.id), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: url, to: Self.pdfURL(paper.id))
        papers.insert(paper, at: 0)
        save()
        return paper
    }

    func update(_ id: UUID, _ body: (inout Paper) -> Void) {
        guard let i = papers.firstIndex(where: { $0.id == id }) else { return }
        body(&papers[i])
        save()
    }

    func delete(_ id: UUID) {
        papers.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: Self.folder(id))
        save()
    }

    private func save() {
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(papers) {
            try? data.write(to: Self.indexURL, options: .atomic)
        }
    }
}

/// App settings stored in UserDefaults (the API key is in the Keychain).
enum AppSettings {
    enum Key {
        static let model = "deepseekModel"
        static let baseURL = "deepseekBaseURL"
        static let prompt = "narrationPrompt"
        static let parts = "partsCount"
        static let minutes = "minutesPerPart"
        static let defaultVoice = "defaultVoice"
        static let voiceModel = "voiceModel"
        static let bestSteps = "bestSteps"
        static let fastSteps = "fastSteps"
        static let speed = "speechSpeed"
    }

    static let defaultPrompt = """
    You write audio scripts that explain scientific papers to a curious, smart listener who is not an expert in the field. \
    Sound like a great science podcast host: clear, warm and concrete. Explain jargon the first time it comes up, use \
    examples and analogies, say what the results mean and how confident we can be in them, and point out limitations. \
    Stay faithful to the paper and don't invent details. This will be read aloud by a text-to-speech voice, so write \
    plain spoken prose only: no markdown, headings, bullet points, citations, URLs, or figure and table numbers. Write \
    numbers, units, symbols and equations the way they would be said out loud.
    """

    static var deepSeekModel: String { UserDefaults.standard.string(forKey: Key.model) ?? DeepSeekClient.knownModels[0] }
    static var prompt: String {
        let p = UserDefaults.standard.string(forKey: Key.prompt) ?? ""
        return p.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? defaultPrompt : p
    }
    static var partsCount: Int { clamp(UserDefaults.standard.object(forKey: Key.parts) as? Int ?? 3, 1, 12) }
    static var minutesPerPart: Int { clamp(UserDefaults.standard.object(forKey: Key.minutes) as? Int ?? 4, 1, 20) }
    static var voiceModel: VoiceModel { VoiceModel(rawValue: UserDefaults.standard.string(forKey: Key.voiceModel) ?? "") ?? .fast }
    static func steps(_ model: VoiceModel) -> Int {
        model == .best
            ? clamp(UserDefaults.standard.object(forKey: Key.bestSteps) as? Int ?? 8, 2, 24)
            : clamp(UserDefaults.standard.object(forKey: Key.fastSteps) as? Int ?? 2, 1, 8)
    }
    static var speed: Double {
        let s = UserDefaults.standard.double(forKey: Key.speed)
        return s > 0 ? s : 1.0
    }

    private static func clamp(_ v: Int, _ lo: Int, _ hi: Int) -> Int { min(max(v, lo), hi) }
}

/// The DeepSeek requests for a paper's audio series. The paper text comes first in every request, so DeepSeek's
/// prompt cache serves it again cheaply for the outline and each part.
enum ScriptPrompts {
    static func words(minutes: Int) -> Int { minutes * 150 }

    static func paperBlock(_ text: String) -> String {
        "Here is a scientific paper.\n\n<paper>\n\(text)\n</paper>\n\n"
    }

    static func outline(paper: String, parts: Int, minutes: Int) -> String {
        paperBlock(paper) + """
        Plan an audio series of \(parts) parts about this paper, about \(minutes) minutes each, that together cover it \
        well in a natural order for a listener. Reply with exactly \(parts) lines and nothing else, each in this form:
        Part N: short title | one sentence on what this part covers
        """
    }

    static func part(paper: String, outline: [Paper.Part], index: Int, minutes: Int) -> String {
        let total = outline.count
        let words = words(minutes: minutes)
        let part = outline[index]
        var position: String
        if total == 1 {
            position = "This is the only part: open by naming the paper and what question it answers, cover the whole paper, and end with the takeaways."
        } else if index == 0 {
            position = "This is the first part: open by naming the paper and the question it answers. Don't cover what later parts will."
        } else if index == total - 1 {
            position = "This is the last part: pick up where part \(index) left off without re-introducing the paper, and end with the takeaways and open questions."
        } else {
            position = "This is a middle part: pick up where part \(index) left off without re-introducing the paper, and don't cover what other parts will."
        }
        let plan = outline.map { "Part \($0.id): \($0.title) | \($0.focus)" }.joined(separator: "\n")
        return paperBlock(paper) + """
        The audio series has \(total) part\(total == 1 ? "" : "s"):
        \(plan)

        Write the script for part \(part.id), "\(part.title)": \(part.focus)
        \(position)
        Aim for about \(words) words (about \(minutes) minutes read aloud). Reply with the script only.
        """
    }

    /// Reads "Part N: title | focus" lines; fills in plain titles when the model ignored the format.
    static func parseOutline(_ text: String, parts: Int) -> [Paper.Part] {
        var out: [Paper.Part] = []
        for raw in text.components(separatedBy: .newlines) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            line = line.trimmingCharacters(in: CharacterSet(charactersIn: "*#-• "))
            guard !line.isEmpty else { continue }
            if let colon = line.firstIndex(of: ":"), line[..<colon].lowercased().contains("part") {
                line = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            } else if out.isEmpty && !line.contains("|") {
                continue   // a preamble line
            }
            let pieces = line.split(separator: "|", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            let title = pieces[0].trimmingCharacters(in: CharacterSet(charactersIn: "*\"")).trimmingCharacters(in: .whitespaces)
            out.append(Paper.Part(id: out.count + 1, title: title.isEmpty ? "Part \(out.count + 1)" : title,
                                  focus: pieces.count > 1 ? pieces[1] : ""))
            if out.count == parts { break }
        }
        while out.count < parts {
            out.append(Paper.Part(id: out.count + 1, title: "Part \(out.count + 1)", focus: "Continue covering the paper."))
        }
        return out
    }

    /// The paper's title as DeepSeek reads it, from the first line of a short request.
    static func title(paper: String) -> String {
        "<paper>\n\(paper.prefix(6000))\n</paper>\n\nWhat is the title of this paper? Reply with the title only."
    }
}
