import Foundation

/// The three things a paper is turned into, each its own audio file.
enum TrackKind: String, Codable, CaseIterable, Identifiable {
    case overview, deep, questions

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .deep: return "In depth"
        case .questions: return "Questions"
        }
    }

    var subtitle: String {
        switch self {
        case .overview: return "5–6 min · the question, why it matters, what they did, what they found"
        case .deep: return "10–15 min · findings, experiments, figures, limitations, open questions"
        case .questions: return "Study questions with in-depth answers"
        }
    }

    var fileName: String { "\(rawValue).m4a" }
}

struct Track: Codable, Equatable {
    var duration: Double
    var chapters: [Chapter]
    var voice: NarratorVoice?
    var position: Double = 0
}

/// A written part of a script, shown under the player.
struct ScriptPart: Codable, Equatable, Identifiable {
    var id: String
    var heading: String
    var text: String
}

struct QuestionAnswer: Codable, Equatable, Identifiable {
    var question: String
    var answer: String
    var id: String { question }
}

/// One imported PDF and everything made from it, saved as state.json in its own folder:
/// Documents/Papers/<id>/ holds paper.pdf, text.txt (the extracted text) and an .m4a per track.
struct Paper: Codable, Identifiable, Equatable {
    enum Stage: String, Codable {
        case queued             // waiting for its turn
        case reading            // pulling the text out of the PDF
        case notes              // taking notes on each part of the paper
        case overview           // writing the overview
        case recordOverview     // reading the overview into overview.m4a
        case deep               // writing the in-depth parts
        case questions          // writing the study questions and their answers
        case recordDeep         // recording deep.m4a
        case recordQuestions    // recording questions.m4a
        case ready
        case failed
    }

    var id = UUID()
    var fileName: String
    var added = Date()
    var title: String?
    var stage: Stage = .queued
    /// Progress within the current stage, 0...1.
    var stageProgress: Double = 0
    var error: String?

    /// Notes on each chunk of the paper (filled in order, so a restart picks up where it stopped).
    var chunkCount = 0
    var notes: [String] = []

    var overview: [ScriptPart] = []
    var deepPlan: [DeepItem]?
    var deep: [ScriptPart] = []
    var questionList: [String]?
    var questions: [QuestionAnswer] = []

    var tracks: [TrackKind: Track] = [:]
    var lastPlayed: Date?

    init(fileName: String) {
        self.fileName = fileName
    }

    var displayTitle: String {
        if let title, !title.isEmpty { return title }
        return (fileName as NSString).deletingPathExtension
    }

    var isWorking: Bool { ![.ready, .failed].contains(stage) }

    /// Rough share of the whole job that is done, for progress bars.
    var overallProgress: Double {
        let p = min(max(stageProgress, 0), 1)
        let weights: [(Stage, Double)] = [(.reading, 0.02), (.notes, 0.30), (.overview, 0.12), (.recordOverview, 0.06),
                                          (.deep, 0.25), (.questions, 0.12), (.recordDeep, 0.09), (.recordQuestions, 0.04)]
        switch stage {
        case .queued, .failed: return 0
        case .ready: return 1
        default:
            var done = 0.0
            for (s, w) in weights {
                if s == stage { return done + w * p }
                done += w
            }
            return done
        }
    }

    var statusText: String {
        switch stage {
        case .queued: return "Waiting"
        case .reading: return "Reading the PDF"
        case .notes: return chunkCount > 0 ? "Reading part \(min(notes.count + 1, chunkCount)) of \(chunkCount)" : "Reading the paper"
        case .overview: return "Writing the overview"
        case .recordOverview: return "Recording the overview, \(Int(stageProgress * 100))%"
        case .deep:
            let total = deepPlan?.count ?? 0
            return total > 0 ? "Writing the in-depth part \(min(deep.count + 1, total)) of \(total)" : "Planning the in-depth audio"
        case .questions:
            let total = questionList?.count ?? 0
            return total > 0 ? "Answering question \(min(questions.count + 1, total)) of \(total)" : "Writing study questions"
        case .recordDeep: return "Recording the in-depth audio, \(Int(stageProgress * 100))%"
        case .recordQuestions: return "Recording the questions, \(Int(stageProgress * 100))%"
        case .ready:
            let total = tracks.values.reduce(0) { $0 + $1.duration }
            return total > 0 ? "Ready · \(Self.format(total)) of audio" : "Ready"
        case .failed: return error ?? "Failed"
        }
    }

    static func format(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    // Decoding tolerates missing keys, so state saved by an older build still loads.
    private enum CodingKeys: String, CodingKey {
        case id, fileName, added, title, stage, stageProgress, error, chunkCount, notes, overview, deepPlan, deep,
             questionList, questions, tracks, lastPlayed
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        fileName = try c.decodeIfPresent(String.self, forKey: .fileName) ?? "Paper.pdf"
        added = try c.decodeIfPresent(Date.self, forKey: .added) ?? Date()
        title = try c.decodeIfPresent(String.self, forKey: .title)
        stage = (try? c.decodeIfPresent(Stage.self, forKey: .stage)) ?? .queued
        stageProgress = try c.decodeIfPresent(Double.self, forKey: .stageProgress) ?? 0
        error = try c.decodeIfPresent(String.self, forKey: .error)
        chunkCount = try c.decodeIfPresent(Int.self, forKey: .chunkCount) ?? 0
        notes = try c.decodeIfPresent([String].self, forKey: .notes) ?? []
        overview = (try? c.decodeIfPresent([ScriptPart].self, forKey: .overview)) ?? []
        deepPlan = try? c.decodeIfPresent([DeepItem].self, forKey: .deepPlan)
        deep = (try? c.decodeIfPresent([ScriptPart].self, forKey: .deep)) ?? []
        questionList = try? c.decodeIfPresent([String].self, forKey: .questionList)
        questions = (try? c.decodeIfPresent([QuestionAnswer].self, forKey: .questions)) ?? []
        tracks = (try? c.decodeIfPresent([TrackKind: Track].self, forKey: .tracks)) ?? [:]
        lastPlayed = try c.decodeIfPresent(Date.self, forKey: .lastPlayed)
    }
}
