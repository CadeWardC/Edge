import Foundation

/// One line of a spoken script: who says it and what.
struct ScriptLine {
    enum Speaker { case narrator, host }

    var speaker: Speaker
    var text: String
    /// Starts a chapter with this title.
    var chapter: String?
    /// Silence after the line, in seconds.
    var pauseAfter: Double = 0.6
}

struct Chapter: Codable, Equatable, Hashable {
    var title: String
    var start: Double
}

/// Reads a script into an .m4a with two Kokoro voices, small pauses between sentences and longer ones between
/// paragraphs and speakers, which is what makes long synthetic speech pleasant to follow.
enum ScriptRecorder {
    static func record(_ lines: [ScriptLine], narrator: KokoroNarrator, voice: NarratorVoice, host: NarratorVoice,
                       speed: Float, to url: URL, progress: @escaping (Double) -> Void,
                       isCancelled: @escaping () -> Bool) async throws -> (duration: Double, chapters: [Chapter]) {
        // phonemize everything first, so progress is measured in sentences
        var plan: [(line: ScriptLine, paragraphs: [[String]])] = []
        for line in lines {
            var paragraphs: [[String]] = []
            for paragraph in line.text.components(separatedBy: "\n") where !paragraph.trimmingCharacters(in: .whitespaces).isEmpty {
                let chunks = try await narrator.chunks(for: paragraph)
                if !chunks.isEmpty { paragraphs.append(chunks) }
            }
            plan.append((line, paragraphs))
        }
        let total = max(plan.reduce(0) { $0 + $1.paragraphs.reduce(0) { $0 + $1.count } }, 1)

        try? FileManager.default.removeItem(at: url)
        try await narrator.load()
        let writer = try AudioFileWriter(url: url, sampleRate: narrator.sampleRate)
        var chapters: [Chapter] = []
        var done = 0
        try writer.writeSilence(seconds: 0.3)
        for (line, paragraphs) in plan {
            if let title = line.chapter {
                chapters.append(Chapter(title: title, start: max(writer.seconds - 0.2, 0)))
            }
            let v = line.speaker == .host ? host : voice
            // the host speaks a touch faster, like someone asking a quick question
            let s = line.speaker == .host ? speed * 1.04 : speed
            for (p, chunks) in paragraphs.enumerated() {
                for (c, chunk) in chunks.enumerated() {
                    if isCancelled() { throw CancellationError() }
                    let samples = try await narrator.speak(phonemes: chunk, voice: v, speed: s)
                    try writer.write(trimSilence(samples))
                    let lastOfParagraph = c == chunks.count - 1
                    if !lastOfParagraph {
                        try writer.writeSilence(seconds: chunk.hasSuffix("?") ? 0.32 : 0.22)
                    } else if p < paragraphs.count - 1 {
                        try writer.writeSilence(seconds: 0.55)
                    }
                    done += 1
                    progress(Double(done) / Double(total))
                }
            }
            try writer.writeSilence(seconds: line.pauseAfter)
        }
        try writer.writeSilence(seconds: 0.5)
        let duration = writer.seconds
        writer.close()
        return (duration, chapters)
    }

    /// Kokoro pads each sentence with a little silence of its own; trimming it keeps the pacing even.
    static func trimSilence(_ samples: [Float], threshold: Float = 0.004) -> [Float] {
        guard let first = samples.firstIndex(where: { abs($0) > threshold }),
              let last = samples.lastIndex(where: { abs($0) > threshold }) else { return samples }
        let lead = max(first - 480, 0)                 // keep 20 ms before the speech
        let tail = min(last + 1_200, samples.count - 1) // and 50 ms after
        return Array(samples[lead...tail])
    }
}
