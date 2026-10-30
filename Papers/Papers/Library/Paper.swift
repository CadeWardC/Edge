import Foundation

/// One imported PDF and everything made from it, saved as state.json in its own folder:
/// Documents/Papers/<id>/ holds paper.pdf, text.txt (the extracted text) and summary.m4a.
struct Paper: Codable, Identifiable, Equatable {
    enum Stage: String, Codable {
        case queued       // waiting for its turn
        case reading      // pulling the text out of the PDF
        case notes        // taking notes on each part of the paper
        case writing      // writing the four parts of the script
        case recording    // reading the script out loud into summary.m4a
        case ready
        case failed
    }

    struct Section: Codable, Equatable, Identifiable {
        var kind: SectionKind
        var text: String
        var id: SectionKind { kind }
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
    var sections: [Section] = []

    /// The finished audio.
    var duration: Double?
    /// Where each section starts in summary.m4a, in seconds (same order as `sections`).
    var chapterStarts: [Double] = []
    var voice: NarratorVoice?
    var playbackPosition: Double = 0
    var lastPlayed: Date?

    var displayTitle: String {
        if let title, !title.isEmpty { return title }
        return (fileName as NSString).deletingPathExtension
    }

    var isWorking: Bool { ![.ready, .failed].contains(stage) }

    /// Rough share of the whole job that is done, for progress bars.
    var overallProgress: Double {
        let p = min(max(stageProgress, 0), 1)
        switch stage {
        case .queued: return 0
        case .reading: return 0.03 * p
        case .notes: return 0.03 + 0.45 * p
        case .writing: return 0.48 + 0.32 * p
        case .recording: return 0.80 + 0.20 * p
        case .ready: return 1
        case .failed: return 0
        }
    }

    var statusText: String {
        switch stage {
        case .queued: return "Waiting"
        case .reading: return "Reading the PDF"
        case .notes: return chunkCount > 0 ? "Taking notes, part \(min(notes.count + 1, chunkCount)) of \(chunkCount)" : "Taking notes"
        case .writing: return "Writing the summary, \(min(sections.count + 1, SectionKind.allCases.count)) of \(SectionKind.allCases.count)"
        case .recording: return "Recording the audio, \(Int(stageProgress * 100))%"
        case .ready:
            guard let duration else { return "Ready" }
            return "Ready · \(Self.format(duration))"
        case .failed: return error ?? "Failed"
        }
    }

    static func format(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// The four parts of every summary: the framework for reading the paper.
enum SectionKind: String, Codable, CaseIterable {
    case question, importance, methods, findings

    var heading: String {
        switch self {
        case .question: return "The question"
        case .importance: return "Why it matters"
        case .methods: return "What they did"
        case .findings: return "What they found"
        }
    }

    /// Spoken before the section, as a signpost.
    var spokenHeading: String {
        switch self {
        case .question: return "First, the question."
        case .importance: return "Why it matters."
        case .methods: return "What they did."
        case .findings: return "What they found."
        }
    }

    var symbol: String {
        switch self {
        case .question: return "questionmark.circle"
        case .importance: return "exclamationmark.circle"
        case .methods: return "wrench.and.screwdriver"
        case .findings: return "lightbulb"
        }
    }
}
