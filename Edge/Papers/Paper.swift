import Foundation

/// One audio made from a paper: what DeepSeek is asked to write, and how long it should be.
struct AudioPrompt: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var prompt: String
    var minMinutes: Int
    var maxMinutes: Int
    var enabled = true

    var lengthLabel: String { minMinutes == maxMinutes ? "\(minMinutes) min" : "\(minMinutes)–\(maxMinutes) min" }

    static let introduction = AudioPrompt(
        id: UUID(uuidString: "00000000-0000-4000-8000-100000000001")!,
        name: "Introduction",
        prompt: """
        Write a light, friendly introduction to this research paper for someone hearing about it for the first time. \
        In plain language, say what the paper is about, the question it asks, why it matters, roughly how the authors \
        went about it, and the headline finding. Keep it a very light overview: no deep methods, only the numbers that \
        really matter, and a quick explanation for any technical term. End with a sentence on why it is worth knowing about.
        """,
        minMinutes: 5, maxMinutes: 6)

    static let inDepth = AudioPrompt(
        id: UUID(uuidString: "00000000-0000-4000-8000-100000000002")!,
        name: "In-depth recap",
        prompt: """
        Write an in-depth recap of this research paper for a listener who wants to really understand it. Cover the \
        background and motivation, the exact research question, the methods and data in enough detail to follow, the \
        key results with the important numbers, how the authors interpret them, the limitations and open questions, and \
        how the work fits into its field. Explain technical terms the first time they come up and use concrete examples. \
        Stay faithful to the paper and don't invent details.
        """,
        minMinutes: 15, maxMinutes: 16)

    static let defaults = [introduction, inDepth]
}

/// An imported paper and its audios.
struct Paper: Identifiable, Codable, Equatable {
    enum Stage: String, Codable {
        case new, writing, voicing, done, failed
    }

    /// One finished (or in-progress) audio of the paper.
    struct Part: Identifiable, Codable, Equatable {
        var id: Int            // 1-based position
        var title: String
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

    /// The audios to make (a copy of the prompts in Settings, editable per paper).
    var prompts: [AudioPrompt]
    var voiceID: UUID?
    var model: VoiceModel

    var enabledPrompts: [AudioPrompt] { prompts.filter(\.enabled) }
    var totalDuration: Double { parts.compactMap(\.duration).reduce(0, +) }
    var hasScripts: Bool { !parts.isEmpty && parts.allSatisfy { !$0.script.isEmpty } }

    init(title: String, prompts: [AudioPrompt], voiceID: UUID?, model: VoiceModel) {
        self.title = title
        self.prompts = prompts
        self.voiceID = voiceID
        self.model = model
    }

    // papers saved by earlier versions have no prompts
    private enum CodingKeys: String, CodingKey {
        case id, title, added, stage, message, parts, prompts, voiceID, model
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        added = try c.decodeIfPresent(Date.self, forKey: .added) ?? Date()
        stage = try c.decodeIfPresent(Stage.self, forKey: .stage) ?? .new
        message = try c.decodeIfPresent(String.self, forKey: .message)
        parts = (try? c.decodeIfPresent([Part].self, forKey: .parts)) ?? []
        prompts = (try? c.decodeIfPresent([AudioPrompt].self, forKey: .prompts)) ?? AppSettings.audioPrompts
        voiceID = try c.decodeIfPresent(UUID.self, forKey: .voiceID)
        model = (try? c.decodeIfPresent(VoiceModel.self, forKey: .model)) ?? .fast
    }
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
            prompts: AppSettings.audioPrompts,
            voiceID: d.string(forKey: AppSettings.Key.defaultVoice).flatMap(UUID.init(uuidString:)),
            model: AppSettings.voiceModel
        )
        if VoiceLibrary.shared.voice(paper.voiceID) == nil { paper.voiceID = Voice.defaultVoice.id }
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
        static let prompts = "audioPrompts"
        static let defaultVoice = "defaultVoice"
        static let voiceModel = "voiceModel"
        static let bestSteps = "bestSteps"
        static let fastSteps = "fastSteps"
        static let speed = "speechSpeed"
    }

    static var deepSeekModel: String { UserDefaults.standard.string(forKey: Key.model) ?? DeepSeekClient.knownModels[0] }

    /// The audios made for each new paper (Introduction and In-depth recap unless changed).
    static var audioPrompts: [AudioPrompt] {
        get {
            guard let data = UserDefaults.standard.data(forKey: Key.prompts),
                  let list = try? JSONDecoder().decode([AudioPrompt].self, from: data), !list.isEmpty else {
                return AudioPrompt.defaults
            }
            return list
        }
        set {
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: Key.prompts)
        }
    }

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

/// The DeepSeek requests for a paper's audios. The paper text comes first in every request, so DeepSeek's
/// prompt cache serves it again cheaply for each audio.
enum ScriptPrompts {
    /// Rules every script follows, whatever the prompt says: it is read aloud by a voice model.
    static let speechRules = """
    The script will be read aloud by a text-to-speech voice, so write natural spoken prose only: no markdown, headings, \
    bullet points, citations, URLs, or figure and table numbers. Write numbers, units, symbols and equations the way \
    they are said out loud. Sound like a warm, clear podcast host talking to one curious listener.
    """

    static func words(minutes: Int) -> Int { minutes * 150 }

    static func paperBlock(_ text: String) -> String {
        "Here is a scientific paper.\n\n<paper>\n\(text)\n</paper>\n\n"
    }

    static func script(paper: String, prompt: AudioPrompt) -> String {
        let low = words(minutes: prompt.minMinutes), high = words(minutes: prompt.maxMinutes)
        return paperBlock(paper) + """
        Write the script for "\(prompt.name)": \(prompt.lengthLabel) read aloud, about \(low)–\(high) words. \
        Start by naming the paper. Reply with the script only.
        """
    }

    /// The paper's title as DeepSeek reads it.
    static func title(paper: String) -> String {
        "<paper>\n\(paper.prefix(6000))\n</paper>\n\nWhat is the title of this paper? Reply with the title only."
    }
}
