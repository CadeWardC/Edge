import Foundation
import UIKit

/// Turns papers into audio series, one paper at a time: DeepSeek writes the scripts, the cloned voice reads them.
@MainActor
final class PaperWorker: ObservableObject {
    static let shared = PaperWorker()

    enum Job: Equatable {
        /// Write the scripts (unless they are already there) and voice every part that has no audio yet.
        case make
        /// Write new scripts, then voice them.
        case rewrite
        /// Voice the existing scripts again (after changing the voice).
        case revoice
    }

    @Published private(set) var current: UUID?
    @Published private(set) var status = ""
    @Published private(set) var fraction: Double = 0
    @Published private(set) var queued: [UUID] = []

    private var jobs: [(UUID, Job)] = []
    private var task: Task<Void, Never>?

    private init() {
        BackgroundKeepAlive.shared.onExpire = { [weak self] in
            self?.cancelAll(message: "Paused because iOS ended the background time. Tap Make audio to continue.")
        }
    }

    func isBusy(_ id: UUID) -> Bool { current == id || queued.contains(id) }

    func start(_ id: UUID, _ job: Job) {
        guard !isBusy(id) else { return }
        jobs.append((id, job))
        queued = jobs.map(\.0)
        runNext()
    }

    func cancel(_ id: UUID) {
        if current == id {
            task?.cancel()
        } else {
            jobs.removeAll { $0.0 == id }
            queued = jobs.map(\.0)
        }
    }

    private func cancelAll(message: String) {
        for (id, _) in jobs {
            PaperLibrary.shared.update(id) { $0.message = message }
        }
        jobs.removeAll()
        queued = []
        task?.cancel()
    }

    private func runNext() {
        guard task == nil, !jobs.isEmpty else { return }
        let (id, job) = jobs.removeFirst()
        queued = jobs.map(\.0)
        current = id
        status = "Starting…"
        fraction = 0
        UIApplication.shared.isIdleTimerDisabled = true
        let title = PaperLibrary.shared.paper(id)?.title ?? "Paper"
        BackgroundKeepAlive.shared.begin(title: "Making audio", subtitle: title)
        task = Task {
            var success = true
            do {
                try await run(id, job)
            } catch is CancellationError {
                success = false
                PaperLibrary.shared.update(id) {
                    $0.stage = .failed
                    if $0.message == nil || $0.message?.hasPrefix("Paused") == false { $0.message = "Stopped." }
                }
            } catch {
                success = false
                let message = (error as? URLError)?.code == .cancelled ? "Stopped." : error.localizedDescription
                PaperLibrary.shared.update(id) {
                    $0.stage = .failed
                    $0.message = message
                }
            }
            BackgroundKeepAlive.shared.end(success: success)
            UIApplication.shared.isIdleTimerDisabled = false
            current = nil
            status = ""
            task = nil
            runNext()
        }
    }

    private func report(_ text: String, _ value: Double) {
        status = text
        fraction = value
        let title = PaperLibrary.shared.paper(current ?? UUID())?.title ?? ""
        BackgroundKeepAlive.shared.update(fraction: value, title: text, subtitle: title)
    }

    // MARK: The work

    private func run(_ id: UUID, _ job: Job) async throws {
        let library = PaperLibrary.shared
        guard var paper = library.paper(id) else { return }
        library.update(id) { $0.message = nil }

        let needsScripts = job == .rewrite || !paper.hasScripts || paper.parts.count != paper.partsCount
        if needsScripts {
            try await writeScripts(&paper)
        }

        // voice the parts
        guard let voice = VoiceLibrary.shared.voice(paper.voiceID) ?? VoiceLibrary.shared.voices.first else {
            throw AppError("Add a voice in the Voices tab first.")
        }
        guard ModelStore.shared.isReady(paper.model) else {
            throw AppError("Download the \(paper.model.title) voice model (\(paper.model.modelName)) in Settings first.")
        }
        library.update(id) { $0.stage = .voicing }
        let options = SpeechRenderer.Options(voice: voice, model: paper.model, steps: AppSettings.steps(paper.model))
        let parts = library.paper(id)?.parts ?? paper.parts
        let todo = parts.filter { job != .make || $0.duration == nil || !FileManager.default.fileExists(atPath: PaperLibrary.audioURL(id, part: $0.id).path) }
        for (n, part) in todo.enumerated() {
            try Task.checkCancellation()
            let label = "Voicing part \(part.id) of \(parts.count)"
            report(label, 0)
            library.update(id) { p in
                if let i = p.parts.firstIndex(where: { $0.id == part.id }) { p.parts[i].duration = nil }
            }
            let url = PaperLibrary.audioURL(id, part: part.id)
            let seconds = try await SpeechRenderer.render(part.script, options: options, to: url) { value in
                Task { @MainActor in
                    PaperWorker.shared.report(label, (Double(n) + value) / Double(todo.count))
                }
            }
            library.update(id) { p in
                if let i = p.parts.firstIndex(where: { $0.id == part.id }) { p.parts[i].duration = seconds }
            }
        }
        library.update(id) {
            $0.stage = .done
            $0.message = nil
        }
    }

    private func writeScripts(_ paper: inout Paper) async throws {
        let id = paper.id
        let library = PaperLibrary.shared
        library.update(id) {
            $0.stage = .writing
            $0.parts = []
        }
        for part in 1...max(paper.partsCount, 1) {
            try? FileManager.default.removeItem(at: PaperLibrary.audioURL(id, part: part))
        }

        report("Reading the PDF", 0.02)
        let text = try await paperText(id)

        let client = DeepSeekClient()
        let model = AppSettings.deepSeekModel
        let system = DeepSeekClient.Message(role: "system", content: paper.customPrompt ?? AppSettings.prompt)
        let maxTokens = model.contains("reasoner") ? 32_000 : min(8_000, ScriptPrompts.words(minutes: paper.minutesPerPart) * 2 + 800)

        // a better title than the file name
        if let title = try? await client.complete(model: DeepSeekClient.knownModels[0], messages: [
            .init(role: "user", content: ScriptPrompts.title(paper: text))], maxTokens: 80, temperature: 0) {
            let clean = title.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"*#")))
            if (8...300).contains(clean.count) { library.update(id) { $0.title = clean } }
        }

        var outline: [Paper.Part]
        if paper.partsCount <= 1 {
            outline = [Paper.Part(id: 1, title: library.paper(id)?.title ?? "The paper", focus: "The whole paper.")]
        } else {
            report("Planning \(paper.partsCount) parts", 0.05)
            let answer = try await client.complete(model: model, messages: [
                system, .init(role: "user", content: ScriptPrompts.outline(paper: text, parts: paper.partsCount, minutes: paper.minutesPerPart)),
            ], maxTokens: model.contains("reasoner") ? 16_000 : 1_500, temperature: 0.4)
            outline = ScriptPrompts.parseOutline(answer, parts: paper.partsCount)
        }
        library.update(id) { $0.parts = outline }

        let partCount = outline.count
        for i in outline.indices {
            try Task.checkCancellation()
            let label = "Writing part \(i + 1) of \(partCount)"
            report(label, 0.1 + 0.9 * Double(i) / Double(partCount))
            let expectedWords = Double(ScriptPrompts.words(minutes: paper.minutesPerPart))
            let request = ScriptPrompts.part(paper: text, outline: outline, index: i, minutes: paper.minutesPerPart)
            let script = try await client.complete(model: model, messages: [
                system, .init(role: "user", content: request),
            ], maxTokens: maxTokens) { sofar in
                let words = Double(sofar.split(separator: " ").count)
                Task { @MainActor in
                    PaperWorker.shared.report(label, 0.1 + 0.9 * (Double(i) + min(words / expectedWords, 0.98)) / Double(partCount))
                }
            }
            outline[i].script = script.trimmingCharacters(in: .whitespacesAndNewlines)
            library.update(id) { $0.parts = outline }
        }
        paper = library.paper(id) ?? paper
    }

    /// The paper's text, extracted once and kept next to the PDF.
    private func paperText(_ id: UUID) async throws -> String {
        let cached = PaperLibrary.textURL(id)
        if let text = try? String(contentsOf: cached, encoding: .utf8), !text.isEmpty { return text }
        let extracted = try await PDFText.extract(from: PaperLibrary.pdfURL(id)) { value in
            Task { @MainActor in PaperWorker.shared.report("Reading the PDF", 0.02 + 0.03 * value) }
        }
        try? extracted.text.write(to: cached, atomically: true, encoding: .utf8)
        if let title = extracted.metadataTitle {
            PaperLibrary.shared.update(id) { $0.title = title }
        }
        return extracted.text
    }
}
