import Foundation
import UIKit

/// Works through imported papers and recordings one at a time, entirely on the phone.
///
/// A paper: its text is pulled out of the PDF; Qwen3.5 reads it a part at a time into structured notes; it writes
/// the overview, which Kokoro records first so it can be heard early; then the in-depth parts (findings, each
/// experiment, each figure, limitations, open questions) and the study questions with answers, which are recorded
/// last. A recording: Parakeet transcribes it, then Qwen3.5 summarizes the transcript into bullet points.
///
/// Every step is saved as soon as it is done, so work that was stopped carries on where it left off.
@MainActor
final class WorkQueue: ObservableObject {
    static let shared = WorkQueue()

    @Published private(set) var isRunning = false
    /// The paper or recording being worked on.
    @Published private(set) var currentID: UUID?
    /// Set when iOS took the background time away; the work continues when the app is opened.
    @Published private(set) var pausedInBackground = false

    private let library = Library.shared
    private let recordings = RecordingLibrary.shared
    private let models = ModelStore.shared
    private let keepAlive = BackgroundKeepAlive.shared
    private let narrator = KokoroNarrator(directory: ModelStore.kokoroDirectoryURL)
    private var runtime: TextRuntime?
    private var runTask: Task<Void, Never>?
    private var cancelFlag = CancelFlag()
    private var completedInRun = 0

    private enum Job {
        case paper(UUID), recording(UUID)
    }

    private init() {
        keepAlive.onExpire = { [weak self] in
            self?.pausedInBackground = true
            self?.stopRun()
            Notifier.post(title: "Paused", body: "iOS needed the phone's resources. Open Papers to finish.")
        }
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil,
                                               queue: .main) { _ in
            MainActor.assumeIsolated { WorkQueue.shared.start() }
        }
    }

    private var nextJob: Job? {
        guard models.isReady else { return nil }
        var jobs: [(Date, Job)] = library.pending.map { ($0.added, .paper($0.id)) }
        // a recording that still needs transcribing waits for the speech model
        jobs += recordings.pending.filter { $0.transcriptionDone || models.speechReady }.map { ($0.added, .recording($0.id)) }
        return jobs.min { $0.0 < $1.0 }?.1
    }

    private var pendingCount: Int { library.pending.count + recordings.pending.count }

    /// Starts working through the queue, if there is anything to do and the models are in place.
    func start() {
        guard !isRunning, nextJob != nil else { return }
        isRunning = true
        pausedInBackground = false
        completedInRun = 0
        cancelFlag = CancelFlag()
        keepAlive.begin(title: pendingCount == 1 ? "Working on 1 item" : "Working on \(pendingCount) items", subtitle: "")
        runTask = Task { await run() }
    }

    /// Stops the item being worked on (it stays where it got to) and the rest of the queue.
    func stopRun() {
        cancelFlag.set()
        runTask?.cancel()
    }

    func deletePaper(_ id: UUID) {
        SummaryPlayer.shared.unload(paper: id)
        if currentID == id { stopRun() }
        library.delete(id)
    }

    func deleteRecording(_ id: UUID) {
        SummaryPlayer.shared.unload(recording: id)
        if currentID == id { stopRun() }
        recordings.delete(id)
    }

    func retryPaper(_ id: UUID) {
        library.retry(id)
        start()
    }

    func retryRecording(_ id: UUID) {
        recordings.retry(id)
        start()
    }

    /// Makes the whole summary again (`scriptToo`) or only records the audio again, for example with new voices.
    func regenerate(_ id: UUID, scriptToo: Bool) {
        SummaryPlayer.shared.unload(paper: id)
        afterStopping(id) {
            if scriptToo { self.library.resetSummary(id) } else { self.library.resetAudio(id) }
        }
    }

    func resummarize(_ id: UUID) {
        afterStopping(id) { self.recordings.resummarize(id) }
    }

    private func afterStopping(_ id: UUID, _ change: @escaping () -> Void) {
        if currentID == id { stopRun() }
        Task {
            // let a stopped run finish saving before the change
            while isRunning && currentID == id { try? await Task.sleep(nanoseconds: 100_000_000) }
            change()
            start()
        }
    }

    private func run() async {
        var succeeded = true
        while !Task.isCancelled, !cancelFlag.isSet, let job = nextJob {
            do {
                switch job {
                case .paper(let id):
                    currentID = id
                    try await processPaper(id)
                    if library.paper(id)?.isWorking == true {
                        throw EngineError.inference("The summary stopped in an unexpected state. Tap Try again.")
                    }
                case .recording(let id):
                    currentID = id
                    try await processRecording(id)
                    if recordings.recording(id)?.isWorking == true {
                        throw EngineError.inference("The summary stopped in an unexpected state. Tap Try again.")
                    }
                }
                completedInRun += 1
            } catch {
                if cancelFlag.isSet || error is CancellationError { break }
                succeeded = false
                let message = error.localizedDescription
                switch job {
                case .paper(let id): library.update(id) { $0.stage = .failed; $0.error = message }
                case .recording(let id): recordings.update(id) { $0.stage = .failed; $0.error = message }
                }
            }
        }
        currentID = nil
        await closeRuntime()
        narrator.unload()
        keepAlive.end(success: succeeded && !cancelFlag.isSet)
        isRunning = false
        // something was added while the last item was finishing
        if !cancelFlag.isSet && nextJob != nil { start() }
    }

    // MARK: A paper

    private func processPaper(_ id: UUID) async throws {
        guard let paper = library.paper(id) else { return }

        // 1. the text
        let textURL = Library.textURL(id)
        if paper.stage == .queued || paper.stage == .reading || !FileManager.default.fileExists(atPath: textURL.path) {
            setPaper(id) { $0.stage = .reading; $0.stageProgress = 0; $0.error = nil }
            let extracted = try await PDFText.extract(from: Library.pdfURL(id)) { fraction in
                Task { @MainActor in WorkQueue.shared.paperProgress(id, fraction) }
            }
            try extracted.text.write(to: textURL, atomically: true, encoding: .utf8)
            let chunkCount = PDFText.chunks(extracted.text).count
            setPaper(id) { p in
                if p.title == nil { p.title = extracted.metadataTitle }
                p.chunkCount = chunkCount
                p.notes = []
                p.stage = .notes
                p.stageProgress = 0
            }
        }
        let text = try String(contentsOf: textURL, encoding: .utf8)
        if library.paper(id)?.title == nil {
            let found = try await PaperPipeline.title(text, writer: writer)
            setPaper(id) { p in
                let fallback = p.displayTitle
                p.title = found ?? fallback
            }
        }
        let source = PaperSource(title: library.paper(id)?.displayTitle ?? "", text: text)

        // 2. notes on each part
        if stage(id) == .notes {
            setPaper(id) { $0.chunkCount = source.chunks.count }
            for i in min(library.paper(id)?.notes.count ?? 0, source.chunks.count)..<source.chunks.count {
                setPaper(id) { $0.stageProgress = Double(i) / Double(source.chunks.count) }
                let note = try await PaperPipeline.notes(source, part: i, writer: writer)
                setPaper(id) { $0.notes.append(note) }
            }
            setPaper(id) { $0.stage = .overview; $0.stageProgress = 0 }
        }
        let notes = PaperNotes(library.paper(id)?.notes ?? [])

        // 3. the overview, recorded straight away so it can be heard while the rest is written
        if stage(id) == .overview {
            let parts = PaperPipeline.OverviewPart.allCases
            for part in parts.dropFirst(library.paper(id)?.overview.count ?? 0) {
                let done = library.paper(id)?.overview ?? []
                setPaper(id) { $0.stageProgress = Double(done.count) / Double(parts.count) }
                let text = try await PaperPipeline.overview(part, source: source, notes: notes, previous: done.map(\.text), writer: writer)
                setPaper(id) { $0.overview.append(ScriptPart(id: part.rawValue, heading: part.heading, text: text)) }
            }
            setPaper(id) { $0.stage = .recordOverview; $0.stageProgress = 0 }
        }
        if stage(id) == .recordOverview, let p = library.paper(id) {
            let parts = p.overview.compactMap { part in PaperPipeline.OverviewPart(rawValue: part.id).map { ($0, part.text) } }
            try await record(id, .overview, lines: PaperPipeline.overviewScript(title: p.displayTitle, parts: parts))
            setPaper(id) { $0.stage = .deep; $0.stageProgress = 0 }
            Notifier.post(title: "Overview ready", body: "\(p.displayTitle) · the in-depth audio and questions are on the way.")
        }

        // 4. the in-depth parts
        if stage(id) == .deep {
            if library.paper(id)?.deepPlan == nil {
                let plan = try await PaperPipeline.planDeep(source: source, notes: notes, writer: writer)
                setPaper(id) { $0.deepPlan = plan }
            }
            let plan = library.paper(id)?.deepPlan ?? []
            for item in plan.dropFirst(library.paper(id)?.deep.count ?? 0) {
                let done = library.paper(id)?.deep ?? []
                setPaper(id) { $0.stageProgress = Double(done.count) / Double(max(plan.count, 1)) }
                let text = try await PaperPipeline.deep(item, source: source, notes: notes, covered: done.map(\.text), writer: writer)
                setPaper(id) { $0.deep.append(ScriptPart(id: item.id, heading: item.heading, text: text)) }
            }
            setPaper(id) { $0.stage = .questions; $0.stageProgress = 0 }
        }

        // 5. study questions and their answers
        if stage(id) == .questions {
            if library.paper(id)?.questionList == nil {
                let list = try await PaperPipeline.questions(source: source, notes: notes, writer: writer)
                setPaper(id) { $0.questionList = list }
            }
            let list = library.paper(id)?.questionList ?? []
            for question in list.dropFirst(library.paper(id)?.questions.count ?? 0) {
                let done = library.paper(id)?.questions.count ?? 0
                setPaper(id) { $0.stageProgress = Double(done) / Double(max(list.count, 1)) }
                let answer = try await PaperPipeline.answer(question, source: source, notes: notes, writer: writer)
                setPaper(id) { $0.questions.append(QuestionAnswer(question: question, answer: answer)) }
            }
            setPaper(id) { $0.stage = .recordDeep; $0.stageProgress = 0 }
        }

        // 6. the in-depth and question audio
        if stage(id) == .recordDeep, let p = library.paper(id) {
            let plan = p.deepPlan ?? []
            let parts = p.deep.compactMap { part in plan.first { $0.id == part.id }.map { ($0, part.text) } }
            try await record(id, .deep, lines: PaperPipeline.deepScript(title: p.displayTitle, parts: parts))
            setPaper(id) { $0.stage = .recordQuestions; $0.stageProgress = 0 }
        }
        if stage(id) == .recordQuestions, let p = library.paper(id) {
            if !p.questions.isEmpty {
                let items = p.questions.map { (question: $0.question, answer: $0.answer) }
                try await record(id, .questions, lines: PaperPipeline.questionsScript(title: p.displayTitle, items: items))
            }
            setPaper(id) { $0.stage = .ready; $0.stageProgress = 1 }
            Notifier.post(title: "Ready to listen", body: "\(p.displayTitle) · overview, in-depth audio and questions.")
        }
    }

    private func stage(_ id: UUID) -> Paper.Stage? { library.paper(id)?.stage }

    private func record(_ id: UUID, _ kind: TrackKind, lines: [ScriptLine]) async throws {
        // the summary model is not needed while recording: free its memory for the voice
        await closeRuntime()
        let storedSpeed = UserDefaults.standard.double(forKey: "speechSpeed")
        let speed = Float(storedSpeed > 0 ? storedSpeed : 1.0)
        let dest = Library.audioURL(id, kind)
        let temp = Library.folder(id).appendingPathComponent("\(kind.rawValue)-recording.m4a")
        let flag = cancelFlag
        let voice = NarratorVoice.current
        let result = try await ScriptRecorder.record(lines, narrator: narrator, voice: voice, host: NarratorVoice.host,
                                                     speed: speed, to: temp,
                                                     progress: { f in Task { @MainActor in WorkQueue.shared.paperProgress(id, f) } },
                                                     isCancelled: { flag.isSet })
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: temp, to: dest)
        setPaper(id) { $0.tracks[kind] = Track(duration: result.duration, chapters: result.chapters, voice: voice) }
    }

    // MARK: A recording

    private func processRecording(_ id: UUID) async throws {
        guard let start = recordings.recording(id) else { return }
        if !start.transcriptionDone {
            guard models.speechReady else {
                throw EngineError.load("Download speech recognition in the Audio tab first.")
            }
            setRecording(id) { $0.stage = .transcribing; $0.error = nil }
            // the summary model and the voice are not needed while transcribing
            await closeRuntime()
            narrator.unload()
            let directory = ModelStore.speechDirectoryURL
            let transcriber = try await Task.detached(priority: .userInitiated) { try Transcriber(directory: directory) }.value
            let from = start.transcribedUntil
            let kept = start.segments.filter { $0.end <= from + 0.01 }
            let flag = cancelFlag
            let box = SegmentBox(kept)
            let media = RecordingLibrary.mediaURL(start)
            try await transcriber.transcribe(media, from: from, isCancelled: { flag.isSet }) { segment, fraction in
                if let segment { box.append(segment) }
                // save every few percent, so a stopped transcription loses little
                if let snapshot = box.snapshotIfDue(fraction) {
                    Task { @MainActor in WorkQueue.shared.saveTranscript(id, snapshot.segments, until: snapshot.until, fraction: fraction) }
                }
            }
            let segments = box.segments
            setRecording(id) { r in
                r.segments = segments
                r.transcribedUntil = r.duration
                r.transcriptionDone = true
                r.stage = .summarizing
                r.stageProgress = 0
                r.notes = []
            }
        }

        guard let r = recordings.recording(id), r.summary == nil else {
            setRecording(id) { $0.stage = .ready }
            return
        }
        setRecording(id) { $0.stage = .summarizing; $0.error = nil }
        guard !r.segments.isEmpty else {
            setRecording(id) { r in
                r.summary = TranscriptSummary(title: "", overview: "No speech was found in this recording.", keyPoints: [], actionItems: [])
                r.stage = .ready
            }
            return
        }
        let parts = TranscriptPipeline.parts(r.segments)
        for i in min(r.notes.count, parts.count)..<parts.count {
            setRecording(id) { $0.stageProgress = Double(i) / Double(parts.count + 1) }
            let note = try await TranscriptPipeline.notes(part: parts[i], index: i, of: parts.count, writer: writer)
            setRecording(id) { $0.notes.append(note) }
        }
        let summary = try await TranscriptPipeline.summarize(notes: recordings.recording(id)?.notes ?? [],
                                                             transcript: r.transcriptText, writer: writer)
        setRecording(id) { r in
            r.summary = summary
            r.stage = .ready
            r.stageProgress = 1
        }
        Notifier.post(title: "Transcript ready", body: recordings.recording(id)?.displayTitle ?? "")
    }

    private func saveTranscript(_ id: UUID, _ segments: [TranscriptSegment], until: Double, fraction: Double) {
        guard let r = recordings.recording(id), !r.transcriptionDone, until >= r.transcribedUntil, currentID == id else { return }
        setRecording(id) { r in
            r.segments = segments
            r.transcribedUntil = until
            r.stageProgress = fraction
        }
    }

    // MARK: The summary model

    private var writer: TextWriter { QueueWriter(queue: self) }

    /// Runs one request through the summary model. Uses the GPU in the foreground (or in the background when the
    /// system allows it) and the CPU otherwise; a request the GPU refuses is run again on the CPU.
    fileprivate func complete(_ messages: [TextRuntime.Message], maxTokens: Int32, temperature: Float) async throws -> String {
        let runtime = try await loadRuntime()
        let flag = cancelFlag
        for attempt in 0..<2 {
            try Task.checkCancellation()
            if flag.isSet { throw CancellationError() }
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
        guard let url = models.chatModelURL else {
            throw EngineError.load("The summary model is missing. Download it in Settings.")
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber
        // a model that does not fit in the memory iOS gives the app runs on the CPU straight from the file
        let stream = !ModelStore.fits(modelBytes: size?.int64Value ?? 0)
        guard !stream || ModelStore.fits(modelBytes: 0) else {
            let free = ByteCountFormatter.string(fromByteCount: ModelStore.availableMemory, countStyle: .memory)
            throw EngineError.load("There isn't enough free memory to run the summary model (\(free) available). Close other apps and try again.")
        }
        let loaded = try await TextRuntime.load(modelPath: url.path, contextSize: 12288, useGPU: wantsGPU && !stream,
                                                streamWeights: stream)
        runtime = loaded
        return loaded
    }

    private func closeRuntime() async {
        await runtime?.close()
        runtime = nil
    }

    // MARK: State

    private func setPaper(_ id: UUID, _ change: (inout Paper) -> Void) {
        library.update(id, change)
        reportProgress()
    }

    private func setRecording(_ id: UUID, _ change: (inout Recording) -> Void) {
        recordings.update(id, change)
        reportProgress()
    }

    /// Updates the progress of a paper's current stage when it moved by at least 3% (saving on every tick is wasteful).
    fileprivate func paperProgress(_ id: UUID, _ fraction: Double) {
        guard let p = library.paper(id), abs(fraction - p.stageProgress) >= 0.03 || fraction >= 1 else { return }
        setPaper(id) { $0.stageProgress = fraction }
    }

    private func reportProgress() {
        let total = completedInRun + pendingCount
        guard total > 0, let id = currentID else { return }
        let title: String, subtitle: String, current: Double
        if let p = library.paper(id) {
            title = p.displayTitle
            subtitle = p.statusText
            current = p.overallProgress
        } else if let r = recordings.recording(id) {
            title = r.displayTitle
            subtitle = r.statusText
            current = r.overallProgress
        } else {
            return
        }
        keepAlive.update(fraction: (Double(completedInRun) + current) / Double(total), title: title, subtitle: subtitle)
    }
}

/// Lets the shared pipelines call the queue's model.
private struct QueueWriter: TextWriter {
    let queue: WorkQueue

    func write(_ messages: [TextRuntime.Message], maxTokens: Int32, temperature: Float) async throws -> String {
        try await queue.complete(messages, maxTokens: maxTokens, temperature: temperature)
    }
}

/// Transcript segments gathered off the main thread, handed over every few percent.
private final class SegmentBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [TranscriptSegment]
    private var lastSaved = 0.0

    init(_ initial: [TranscriptSegment]) { items = initial }

    var segments: [TranscriptSegment] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }

    func append(_ s: TranscriptSegment) {
        lock.lock()
        items.append(s)
        lock.unlock()
    }

    func snapshotIfDue(_ fraction: Double) -> (segments: [TranscriptSegment], until: Double)? {
        lock.lock()
        defer { lock.unlock() }
        guard fraction - lastSaved >= 0.03 else { return nil }
        lastSaved = fraction
        return (items, items.last?.end ?? 0)
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
