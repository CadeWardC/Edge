import Foundation
import UIKit

/// Turns queued PDFs into audio summaries, one paper at a time, entirely on the phone:
///
/// 1. the text is pulled out of the PDF (PDFKit, OCR for scanned pages),
/// 2. Qwen3.5-2B reads it a part at a time and takes notes,
/// 3. it writes the four sections of the script from the notes (question, why it matters, what they did,
///    what they found),
/// 4. Kokoro reads the script into summary.m4a.
///
/// Every step is saved as soon as it is done, so a summary that was stopped carries on where it left off.
@MainActor
final class SummaryQueue: ObservableObject {
    static let shared = SummaryQueue()

    @Published private(set) var isRunning = false
    @Published private(set) var currentID: UUID?
    /// Set when iOS took the background time away; the work continues when the app is opened.
    @Published private(set) var pausedInBackground = false

    private let library = Library.shared
    private let keepAlive = BackgroundKeepAlive.shared
    private let narrator = KokoroNarrator()
    private var runtime: TextRuntime?
    private var runTask: Task<Void, Never>?
    private var cancelFlag = CancelFlag()
    private var completedInRun = 0

    private init() {
        keepAlive.onExpire = { [weak self] in
            self?.pausedInBackground = true
            self?.stopRun()
            Notifier.post(title: "Summary paused", body: "Open Papers to finish it.")
        }
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil,
                                               queue: .main) { _ in
            MainActor.assumeIsolated { SummaryQueue.shared.start() }
        }
    }

    /// Starts working through the queue, if there is anything to do and the models are in place.
    func start() {
        guard !isRunning, ModelStore.shared.isReady, !library.pending.isEmpty else { return }
        isRunning = true
        pausedInBackground = false
        completedInRun = 0
        cancelFlag = CancelFlag()
        let first = library.pending.first
        keepAlive.begin(title: "Summarizing \(library.pending.count == 1 ? "a paper" : "\(library.pending.count) papers")",
                        subtitle: first?.displayTitle ?? "")
        runTask = Task { await run() }
    }

    /// Stops the paper being worked on (it stays where it got to) and the rest of the queue.
    func stopRun() {
        cancelFlag.set()
        runTask?.cancel()
    }

    /// Removes a paper, stopping its summary first if it is being made.
    func delete(_ id: UUID) {
        if currentID == id {
            stopRun()
        }
        library.delete(id)
    }

    func retry(_ id: UUID) {
        library.retry(id)
        start()
    }

    func regenerate(_ id: UUID, scriptToo: Bool) {
        if currentID == id { stopRun() }
        Task {
            // let a stopped run finish saving before the reset
            while isRunning && currentID == id { try? await Task.sleep(nanoseconds: 100_000_000) }
            if scriptToo { library.resetSummary(id) } else { library.resetAudio(id) }
            start()
        }
    }

    private func run() async {
        var succeeded = true
        while !Task.isCancelled, let next = library.pending.first {
            currentID = next.id
            do {
                try await process(next.id)
                completedInRun += 1
                if library.paper(next.id)?.isWorking == true {
                    throw EngineError.inference("The summary stopped in an unexpected state. Tap Try again.")
                }
            } catch is CancellationError {
                break
            } catch {
                if cancelFlag.isSet { break }
                succeeded = false
                library.update(next.id) { p in
                    p.stage = .failed
                    p.error = error.localizedDescription
                }
            }
        }
        currentID = nil
        await runtime?.close()
        runtime = nil
        narrator.unload()
        keepAlive.end(success: succeeded && !cancelFlag.isSet)
        isRunning = false
        // something was added while the last paper was finishing
        if !cancelFlag.isSet && !library.pending.isEmpty { start() }
    }

    // MARK: One paper

    private func process(_ id: UUID) async throws {
        guard var paper = library.paper(id) else { return }

        // 1. the text
        let textURL = Library.textURL(id)
        if paper.stage == .queued || paper.stage == .reading || !FileManager.default.fileExists(atPath: textURL.path) {
            set(id) { $0.stage = .reading; $0.stageProgress = 0; $0.error = nil }
            let extracted = try await PDFText.extract(from: Library.pdfURL(id)) { fraction in
                Task { @MainActor in SummaryQueue.shared.progress(id, fraction, step: 0.1) }
            }
            try extracted.text.write(to: textURL, atomically: true, encoding: .utf8)
            if paper.title == nil, let title = extracted.metadataTitle {
                set(id) { $0.title = title }
            }
            set(id) { p in
                p.chunkCount = PDFText.chunks(extracted.text).count
                p.notes = []
                p.sections = []
                p.stage = .notes
                p.stageProgress = 0
            }
        }
        let text = try String(contentsOf: textURL, encoding: .utf8)
        let chunks = PDFText.chunks(text)
        paper = library.paper(id) ?? paper

        if paper.title == nil {
            let reply = try await complete(SummaryPrompts.title(firstPage: String(text.prefix(2500))),
                                           maxTokens: 80, temperature: 0)
            let found = SummaryPrompts.cleanTitle(reply)
            set(id) { p in
                let fallback = p.displayTitle
                p.title = found ?? fallback
            }
        }
        let title = library.paper(id)?.displayTitle ?? paper.displayTitle

        // 2. notes on each part
        if paper.stage == .notes {
            set(id) { $0.stage = .notes; $0.chunkCount = chunks.count }
            for i in min(library.paper(id)?.notes.count ?? 0, chunks.count)..<chunks.count {
                set(id) { $0.stageProgress = Double(i) / Double(chunks.count) }
                let reply = try await complete(
                    SummaryPrompts.notes(title: title, part: i + 1, of: chunks.count, text: chunks[i]),
                    maxTokens: 300, temperature: 0.3)
                let note = SummaryPrompts.cleanScript(reply)
                set(id) { $0.notes.append(note) }
            }
            set(id) { $0.stage = .writing; $0.stageProgress = 0 }
        }

        // 3. the script, one section at a time
        if library.paper(id)?.stage == .writing {
            let opening = String(text.prefix(2500))
            for kind in SectionKind.allCases.dropFirst(library.paper(id)?.sections.count ?? 0) {
                let done = library.paper(id)?.sections ?? []
                set(id) { $0.stageProgress = Double(done.count) / Double(SectionKind.allCases.count) }
                let messages = SummaryPrompts.section(kind, title: title, opening: opening,
                                                      notes: library.paper(id)?.notes ?? [], previous: done)
                let first = try await complete(messages, maxTokens: 520, temperature: 0.6)
                var script = SummaryPrompts.cleanScript(first)
                if SummaryPrompts.wordCount(script) < 90 {
                    // too short to be useful: one more try
                    let again = try await complete(messages, maxTokens: 520, temperature: 0.8)
                    let retry = SummaryPrompts.cleanScript(again)
                    if SummaryPrompts.wordCount(retry) > SummaryPrompts.wordCount(script) { script = retry }
                }
                set(id) { $0.sections.append(Paper.Section(kind: kind, text: script)) }
            }
            set(id) { $0.stage = .recording; $0.stageProgress = 0 }
        }

        // 4. the audio
        if library.paper(id)?.stage == .recording {
            // the summary model is not needed any more: free its memory for the voice
            await runtime?.close()
            runtime = nil
            try await record(id)
        }
    }

    // MARK: Writing

    /// Runs one request through the summary model and returns its reply. Uses the GPU in the foreground (or in the
    /// background when the system allows it) and the CPU otherwise; a request the GPU refuses is run again on the CPU.
    private func complete(_ messages: [TextRuntime.Message], maxTokens: Int32, temperature: Float) async throws -> String {
        let runtime = try await loadRuntime()
        let flag = cancelFlag
        for attempt in 0..<2 {
            try Task.checkCancellation()
            let gpu = attempt == 0 && wantsGPU
            try await runtime.setGPU(gpu)
            let prompt = try await runtime.prompt(messages)
            let collector = TextCollector(flag)
            do {
                try await runtime.generate(prompt: prompt, maxTokens: maxTokens, temperature: temperature) { piece in
                    collector.append(piece)
                }
                if flag.isSet { throw CancellationError() }
                return collector.text
            } catch {
                if flag.isSet { throw CancellationError() }
                if gpu { continue }   // most likely the app went to the background mid-request
                throw error
            }
        }
        throw EngineError.inference("The summary model failed.")
    }

    private var wantsGPU: Bool {
        UIApplication.shared.applicationState != .background || keepAlive.backgroundGPU
    }

    private func loadRuntime() async throws -> TextRuntime {
        if let runtime { return runtime }
        guard let url = ModelStore.shared.chatModelURL else {
            throw EngineError.load("The summary model is missing. Download it in Settings.")
        }
        let loaded = try await TextRuntime.load(modelPath: url.path, contextSize: 8192, useGPU: wantsGPU)
        runtime = loaded
        return loaded
    }

    // MARK: Recording

    private func record(_ id: UUID) async throws {
        guard let paper = library.paper(id) else { return }
        let voice = NarratorVoice.current
        let storedSpeed = UserDefaults.standard.double(forKey: "speechSpeed")
        let speed = Float(storedSpeed > 0 ? storedSpeed : 1.0)

        // the spoken parts: an intro, then each section with its signpost, then a closing line
        var parts: [(chapter: Int?, text: String)] = [(0, "Here is an overview of the paper: \(paper.displayTitle).")]
        for (i, section) in paper.sections.enumerated() {
            parts.append((i == 0 ? nil : i, section.kind.spokenHeading + " " + section.text))
        }
        parts.append((nil, "That's the overview. You now have a framework for reading the paper."))

        var chunked: [(chapter: Int?, chunks: [String])] = []
        for part in parts {
            let chunks = try await narrator.chunks(for: part.text)
            chunked.append((part.chapter, chunks))
        }
        let total = max(chunked.reduce(0) { $0 + $1.chunks.count }, 1)

        let temp = Library.folder(id).appendingPathComponent("summary-recording.m4a")
        try? FileManager.default.removeItem(at: temp)
        let writer = try AudioFileWriter(url: temp, sampleRate: narrator.sampleRate)
        var chapterStarts = Array(repeating: 0.0, count: paper.sections.count)
        var done = 0
        for (index, part) in chunked.enumerated() {
            if let chapter = part.chapter, chapter < chapterStarts.count {
                chapterStarts[chapter] = writer.seconds
            }
            for chunk in part.chunks {
                try Task.checkCancellation()
                let samples = try await narrator.speak(phonemes: chunk, voice: voice, speed: speed)
                try writer.write(samples)
                try writer.writeSilence(seconds: 0.12)
                done += 1
                progress(id, Double(done) / Double(total), step: 0.04)
            }
            if index < chunked.count - 1 { try writer.writeSilence(seconds: 0.7) }
        }
        let duration = writer.seconds
        writer.close()

        let dest = Library.audioURL(id)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: temp, to: dest)
        set(id) { p in
            p.duration = duration
            p.chapterStarts = chapterStarts
            p.voice = voice
            p.playbackPosition = 0
            p.stage = .ready
            p.stageProgress = 1
        }
        Notifier.post(title: "Summary ready", body: "\(paper.displayTitle) · \(Paper.format(duration))")
    }

    // MARK: State

    private func set(_ id: UUID, _ change: (inout Paper) -> Void) {
        library.update(id, change)
        reportProgress()
    }

    /// Updates the progress of the current stage when it moved by at least `step` (saving on every tick is wasteful).
    private func progress(_ id: UUID, _ fraction: Double, step: Double) {
        guard let p = library.paper(id), fraction - p.stageProgress >= step || fraction >= 1 else { return }
        set(id) { $0.stageProgress = fraction }
    }

    private func reportProgress() {
        let pending = library.pending
        let total = completedInRun + pending.count
        guard total > 0 else { return }
        let current = pending.first { $0.id == currentID }
        let fraction = (Double(completedInRun) + (current?.overallProgress ?? 0)) / Double(total)
        keepAlive.update(fraction: fraction,
                         title: current.map { "Summarizing \($0.displayTitle)" } ?? "Summarizing",
                         subtitle: current?.statusText ?? "")
    }
}

/// A stop switch the model's text callback can check from its own thread.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }
}

/// Gathers streamed text; returns false (stop) once the flag is set.
private final class TextCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""
    private let flag: CancelFlag

    init(_ flag: CancelFlag) { self.flag = flag }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }

    func append(_ piece: String) -> Bool {
        lock.lock()
        buffer += piece
        lock.unlock()
        return !flag.isSet
    }
}
