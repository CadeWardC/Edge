import Foundation

/// Voices text into an .m4a file with a cloned or built-in voice, chunk by chunk, reporting progress.
enum SpeechRenderer {
    struct Options {
        var voice: Voice
        /// The cloning model for a cloned voice; built-in voices always use Kokoro.
        var model: VoiceModel
        var speed: Double = AppSettings.speed
        var steps: Int

        var effectiveModel: VoiceModel { voice.isBuiltIn ? .kokoro : model }
    }

    /// Writes `text` spoken by `options.voice` to `url`; returns the seconds of audio.
    /// `progress` gets 0...1. Stops (throwing CancellationError) when the task is cancelled.
    static func render(_ text: String, options: Options, to url: URL,
                       progress: @escaping @Sendable (Double) -> Void) async throws -> Double {
        let chunks = self.chunks(clean(text))
        guard !chunks.isEmpty else { throw AppError("There is nothing to say.") }
        let model = options.effectiveModel
        if model == .best && options.voice.transcript.trimmingCharacters(in: .whitespaces).isEmpty {
            throw AppError("The Best voice needs the transcript of “\(options.voice.name)”. Add it in Voices, or use Fast.")
        }
        let reference = try await MainActor.run { try VoiceLibrary.shared.samples(for: options.voice) }
        let writer = try AudioFileWriter(url: url, sampleRate: Double(VoiceEngine.sampleRate))
        defer { writer.close() }
        let cancelled = AtomicFlag()
        let failure = ErrorBox()
        let totalCharacters = Double(chunks.reduce(0) { $0 + $1.count })
        var done = 0.0

        try await withTaskCancellationHandler {
            for (i, chunk) in chunks.enumerated() {
                try Task.checkCancellation()
                let before = done
                let weight = Double(chunk.count) / totalCharacters
                let request = VoiceEngine.Request(
                    text: chunk, model: model, reference: reference,
                    referenceSampleRate: VoiceEngine.sampleRate, referenceText: options.voice.transcript,
                    speakerID: options.voice.builtInID ?? 0,
                    speed: Float(options.speed), steps: AppSettings.steps(model))
                try await VoiceEngine.shared.speak(request) { samples, p in
                    if cancelled.value { return false }
                    do {
                        try writer.write(samples)
                    } catch {
                        failure.set(error)
                        return false
                    }
                    progress(min(1, before + weight * p))
                    return true
                }
                if let error = failure.value { throw error }
                try Task.checkCancellation()
                done += weight
                progress(min(1, done))
                if i < chunks.count - 1 {
                    // a breath between paragraphs
                    try writer.writeSilence(seconds: chunk.hasSuffix("\n") ? 0.6 : 0.25)
                }
            }
        } onCancel: {
            cancelled.set(true)
        }
        return writer.seconds
    }

    /// Text as it should be read: no markdown, citations or URLs.
    static func clean(_ text: String) -> String {
        var s = text
        let rules: [(String, String)] = [
            ("```[\\s\\S]*?```", " "),
            ("!?\\[([^\\]]*)\\]\\([^)]*\\)", "$1"),             // markdown links
            ("https?://\\S+", ""),
            ("\\[(\\d+([,–-]\\s*\\d+)*)\\]", ""),             // [12], [3-5]
            ("(?m)^\\s{0,3}#{1,6}\\s*", ""),                   // headings
            ("(?m)^\\s*[-*•]\\s+", ""),                        // bullets
            ("[*_`~]{1,3}", ""),
            ("[ \\t]{2,}", " "),
        ]
        for (pattern, template) in rules {
            s = s.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Paragraphs, with long ones split at sentence ends into pieces of at most ~350 characters.
    /// A trailing "\n" marks the end of a paragraph (a longer pause follows).
    static func chunks(_ text: String, limit: Int = 350) -> [String] {
        var out: [String] = []
        let paragraphs = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        for paragraph in paragraphs {
            var pieces: [String] = []
            var current = ""
            paragraph.enumerateSubstrings(in: paragraph.startIndex..., options: .bySentences) { sentence, _, _, _ in
                guard let sentence = sentence?.trimmingCharacters(in: .whitespaces), !sentence.isEmpty else { return }
                if !current.isEmpty && current.count + sentence.count + 1 > limit {
                    pieces.append(current)
                    current = sentence
                } else {
                    current = current.isEmpty ? sentence : current + " " + sentence
                }
            }
            if !current.isEmpty { pieces.append(current) }
            if pieces.isEmpty { pieces = [paragraph] }
            pieces[pieces.count - 1] += "\n"
            out += pieces
        }
        return out
    }
}

final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return _value }
    func set(_ v: Bool) { lock.lock(); _value = v; lock.unlock() }
}

final class ErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Error?
    var value: Error? { lock.lock(); defer { lock.unlock() }; return _value }
    func set(_ e: Error) { lock.lock(); _value = e; lock.unlock() }
}

extension AudioFileWriter: @unchecked Sendable {}
