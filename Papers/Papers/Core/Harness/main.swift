// The Papers test harness (macOS): runs the app's own pipeline code with the real models on real inputs and prints
// every output, so prompts, grounding, phonemization and transcription can be checked before anything ships.
// Built by Papers/Package.swift and run by .github/workflows/papers-eval.yml; not part of the app.
import Foundation

var options: [String: [String]] = [:]
var key = ""
for arg in CommandLine.arguments.dropFirst() {
    if arg.hasPrefix("--") { key = String(arg.dropFirst(2)); options[key, default: []] += [] } else { options[key, default: []].append(arg) }
}
func option(_ name: String) -> String? { options[name]?.first }

setvbuf(stdout, nil, _IOLBF, 0)
let started = Date()
func log(_ s: String) { print(String(format: "[%6.0fs] ", Date().timeIntervalSince(started)) + s) }
func banner(_ s: String) { print("\n========== \(s) ==========") }

final class HarnessWriter: TextWriter {
    let runtime: TextRuntime
    var tokensOut = 0
    var calls = 0

    init(runtime: TextRuntime) { self.runtime = runtime }

    func write(_ messages: [TextRuntime.Message], maxTokens: Int32, temperature: Float) async throws -> String {
        let prompt = try await runtime.prompt(messages)
        final class Sink: @unchecked Sendable { var text = ""; var pieces = 0 }
        let sink = Sink()
        let t0 = Date()
        try await runtime.generate(prompt: prompt, maxTokens: maxTokens, temperature: temperature) { piece in
            sink.text += piece
            sink.pieces += 1
            return true
        }
        calls += 1
        tokensOut += sink.pieces
        let dt = Date().timeIntervalSince(t0)
        log("model call \(calls): prompt \(prompt.count) chars, reply \(sink.pieces) pieces in \(String(format: "%.1f", dt)) s")
        if sink.pieces < 40 { print("   short reply: \(sink.text.debugDescription)") }
        return sink.text
    }
}

let out = URL(fileURLWithPath: option("out") ?? "harness-out", isDirectory: true)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

guard let modelPath = option("model") else { fatalError("--model path/to/model.gguf is required") }
let runtime = try await TextRuntime.load(modelPath: modelPath, contextSize: 12288, useGPU: options["gpu"] != nil)
let writer = HarnessWriter(runtime: runtime)
let narrator = option("kokoro").map { KokoroNarrator(directory: URL(fileURLWithPath: $0, isDirectory: true)) }

func record(_ lines: [ScriptLine], name: String) async throws {
    guard let narrator else { return }
    let url = out.appendingPathComponent(name)
    let t0 = Date()
    let result = try await ScriptRecorder.record(lines, narrator: narrator, voice: .heart, host: .michael, speed: 1.0,
                                                 to: url, progress: { _ in }, isCancelled: { false })
    let words = lines.reduce(0) { $0 + PaperPipeline.wordCount($1.text) }
    log("recorded \(name): \(words) words, \(formatTime(result.duration)) long, in \(Int(Date().timeIntervalSince(t0))) s")
    for c in result.chapters { print("   chapter \(formatTime(c.start))  \(c.title)") }
}

func formatTime(_ seconds: Double) -> String {
    String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60)
}

// MARK: Papers

for pdf in options["pdf"] ?? [] {
    banner("PAPER \(pdf)")
    let extracted = try await PDFText.extract(from: URL(fileURLWithPath: pdf)) { _ in }
    log("text: \(extracted.text.count) characters; metadata title: \(extracted.metadataTitle ?? "none")")
    let title: String
    if let t = extracted.metadataTitle {
        title = t
    } else {
        title = try await PaperPipeline.title(extracted.text, writer: writer) ?? "Untitled"
    }
    let source = PaperSource(title: title, text: extracted.text)
    log("title: \(title); \(source.chunks.count) parts; \(source.index.passages.count) passages")
    for f in source.figures { print("   \(f.label): \(f.caption.prefix(140))") }
    print("--- text sample ---\n\(extracted.text.prefix(1200))\n--- end of sample ---")

    var rawNotes: [String] = []
    for i in source.chunks.indices {
        let note = try await PaperPipeline.notes(source, part: i, writer: writer)
        rawNotes.append(note)
        print("--- notes on part \(i + 1) (\(PaperNotes([note]).count) lines) ---\n\(note.prefix(2500))")
    }
    let notes = PaperNotes(rawNotes)
    banner("NOTES (merged)")
    print(notes.text(PaperNotes.Field.allCases, budget: 20_000))

    if option("stop-after") == "notes" { continue }

    banner("OVERVIEW")
    var overview: [(PaperPipeline.OverviewPart, String)] = []
    for part in PaperPipeline.OverviewPart.allCases {
        let text = try await PaperPipeline.overview(part, source: source, notes: notes, previous: overview.map(\.1), writer: writer)
        overview.append((part, text))
        print("\n## \(part.heading) (\(PaperPipeline.wordCount(text)) words)\n\(text)")
    }

    banner("IN DEPTH")
    let plan = try await PaperPipeline.planDeep(source: source, notes: notes, writer: writer)
    for item in plan { print("   plan: [\(item.kind.rawValue)] \(item.heading) — host: \(item.hostLine)") }
    var deep: [(DeepItem, String)] = []
    for item in plan {
        let text = try await PaperPipeline.deep(item, source: source, notes: notes, covered: deep.map(\.1), writer: writer)
        deep.append((item, text))
        print("\n## \(item.heading) (\(PaperPipeline.wordCount(text)) words)\n\(text)")
    }

    banner("QUESTIONS")
    let questions = try await PaperPipeline.questions(source: source, notes: notes, writer: writer)
    var qa: [(question: String, answer: String)] = []
    for q in questions {
        let a = try await PaperPipeline.answer(q, source: source, notes: notes, writer: writer)
        qa.append((q, a))
        print("\nQ: \(q)\nA (\(PaperPipeline.wordCount(a)) words): \(a)")
    }

    let stem = URL(fileURLWithPath: pdf).deletingPathExtension().lastPathComponent
    if narrator != nil {
        banner("RECORDING")
        try await record(PaperPipeline.overviewScript(title: title, parts: overview), name: "\(stem)-overview.m4a")
        try await record(PaperPipeline.deepScript(title: title, parts: deep), name: "\(stem)-in-depth.m4a")
        try await record(PaperPipeline.questionsScript(title: title, items: qa), name: "\(stem)-questions.m4a")
        if let guessed = await narrator?.guessedWords(), !guessed.isEmpty {
            print("words read by spelling rules (\(guessed.count)): \(guessed.joined(separator: ", "))")
        }
    }
}

// MARK: Audio

if let asr = option("asr") {
    for audio in options["audio"] ?? [] {
        banner("AUDIO \(audio)")
        let transcriber = try Transcriber(directory: URL(fileURLWithPath: asr, isDirectory: true))
        let url = URL(fileURLWithPath: audio)
        log("duration \(formatTime(await Transcriber.duration(of: url)))")
        var segments: [TranscriptSegment] = []
        let t0 = Date()
        try await transcriber.transcribe(url, isCancelled: { false }) { segment, _ in
            if let segment { segments.append(segment) }
        }
        log("transcribed \(segments.count) segments in \(String(format: "%.1f", Date().timeIntervalSince(t0))) s")
        print(TranscriptPipeline.text(segments))
        let parts = TranscriptPipeline.parts(segments)
        var notes: [String] = []
        for (i, part) in parts.enumerated() {
            notes.append(try await TranscriptPipeline.notes(part: part, index: i, of: parts.count, writer: writer))
        }
        let summary = try await TranscriptPipeline.summarize(notes: notes, transcript: TranscriptPipeline.text(segments), writer: writer)
        banner("SUMMARY")
        print("TITLE: \(summary.title)\nOVERVIEW: \(summary.overview)\nKEY POINTS:")
        summary.keyPoints.forEach { print("- \($0)") }
        print("ACTION ITEMS:")
        summary.actionItems.forEach { print("- \($0)") }
    }
}

await runtime.close()
log("done: \(writer.calls) model calls, \(writer.tokensOut) tokens written")
