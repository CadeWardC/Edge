import Foundation
import SwiftUI

struct Turn: Identifiable, Equatable {
    enum Role { case learner, tutor }

    let id = UUID()
    let role: Role
    var text: String                 // learner transcript, or the raw tutor answer
    var reply = TutorReply()
    var audio: [Float] = []
    var audioSampleRate: Double = 24_000
    var isStreaming = false
    var feedback: TutorReply?        // shown under the learner's bubble once the tutor has answered
    var tones: [ToneCheck] = []      // pitch-based tone check of the learner's recording
}

@MainActor
final class TutorSession: ObservableObject {
    enum State: Equatable {
        case notLoaded
        case loading
        case idle
        case listening
        case transcribing
        case thinking
        case speaking
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .transcribing, .thinking, .speaking, .loading: return true
            default: return false
            }
        }
    }

    @Published private(set) var state: State = .notLoaded
    @Published private(set) var turns: [Turn] = []
    @Published private(set) var recordingSeconds: Double = 0
    @Published private(set) var inputLevel: Double = 0
    @Published private(set) var heardSpeech = false

    @AppStorage("voice") var voiceRaw = Voice.female.rawValue
    @AppStorage("level") var levelRaw = LearnerLevel.beginner.rawValue
    @AppStorage("speakReplies") var speakReplies = true
    @AppStorage("checkTones") var checkTones = true
    @AppStorage("autoSend") var autoSend = true
    @AppStorage("pauseSeconds") var pauseSeconds = 1.6
    @AppStorage("handsFree") var handsFree = false
    @AppStorage("speechOnCPU") var speechOnCPU = false

    /// Listening gives up when nothing is said for this long.
    static let noSpeechTimeout: Double = 8

    private var runtime: LFMRuntime?
    private let audio = AudioIO()
    private var history: [TutorPrompts.Exchange] = []
    private var meter: Timer?
    // read from the engine queue inside callbacks, so it is not main-actor state
    private let cancelFlag = AtomicFlag()
    private var cancelled: Bool { cancelFlag.value }

    var voice: Voice { Voice(rawValue: voiceRaw) ?? .female }
    var level: LearnerLevel { LearnerLevel(rawValue: levelRaw) ?? .beginner }

    func load(model: URL, mmproj: URL) async {
        guard runtime == nil, state != .loading else { return }
        state = .loading
        do {
            runtime = try await LFMRuntime.load(modelPath: model.path, mmprojPath: mmproj.path, speechOnGPU: !speechOnCPU)
            state = .idle
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func unload() async {
        stop()
        let old = runtime
        runtime = nil
        state = .notLoaded
        await old?.close()
    }

    /// Loads the model again, e.g. after switching where speech runs.
    func reload(model: URL, mmproj: URL) async {
        await unload()
        await load(model: model, mmproj: mmproj)
    }

    // MARK: Conversation

    func toggleRecording() async {
        switch state {
        case .listening:
            await finishRecording()
        case .idle, .failed:
            guard runtime != nil else { return }
            await startRecording()
        case .speaking:
            // interrupting the tutor goes straight to listening
            stop()
            await startRecording()
        default:
            break
        }
    }

    private func startRecording() async {
        guard await AudioIO.requestMicrophone() else {
            state = .failed("Microphone access is off. Enable it in Settings › Privacy › Microphone.")
            return
        }
        do {
            try audio.startRecording(sampleRate: runtime?.inputSampleRate ?? 16_000)
            state = .listening
            recordingSeconds = 0
            inputLevel = 0
            heardSpeech = false
            meter = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.meterTick() }
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Every 0.1 s while listening: update the meter, and send once the learner has spoken and paused.
    private func meterTick() {
        guard state == .listening else { return }
        let activity = audio.voiceActivity
        recordingSeconds = audio.recordedSeconds
        inputLevel = activity.level
        heardSpeech = activity.speechDetected

        if recordingSeconds >= AudioIO.maxRecordingSeconds {
            Task { await finishRecording() }
        } else if autoSend, activity.speechDetected, activity.silenceSeconds >= pauseSeconds {
            Task { await finishRecording() }
        } else if autoSend, !activity.speechDetected, recordingSeconds >= Self.noSpeechTimeout {
            cancelListening()
            if !handsFree {
                state = .failed("I didn't hear anything. Tap the mic and try again.")
            }
        }
    }

    /// Stops listening without sending anything.
    func cancelListening() {
        guard state == .listening else { return }
        meter?.invalidate()
        meter = nil
        _ = audio.stopRecording()
        inputLevel = 0
        state = .idle
    }

    private func finishRecording() async {
        guard state == .listening else { return }
        meter?.invalidate()
        meter = nil
        inputLevel = 0
        let samples = audio.stopRecording(trimSilence: true)
        let minSamples = Int((runtime?.inputSampleRate ?? 16_000) * 0.4)
        guard samples.count >= minSamples else {
            state = .idle
            return
        }
        await respond(toSpeech: samples)
    }

    /// Typed input skips speech recognition.
    func send(text: String) async {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, state == .idle || state.isFailedState else { return }
        let turn = Turn(role: .learner, text: t)
        turns.append(turn)
        await answer(learnerID: turn.id, learner: t)
    }

    /// Edits a turn if it still exists (the conversation may have been cleared meanwhile).
    private func update(_ id: UUID, _ body: (inout Turn) -> Void) {
        guard let i = turns.firstIndex(where: { $0.id == id }) else { return }
        body(&turns[i])
    }

    private func setTones(_ checks: [ToneCheck], for id: UUID) {
        update(id) { $0.tones = checks }
    }

    private func remove(_ id: UUID) {
        turns.removeAll { $0.id == id }
    }

    private func respond(toSpeech samples: [Float]) async {
        guard let runtime else { return }
        cancelFlag.set(false)
        state = .transcribing

        let turn = Turn(role: .learner, text: "", isStreaming: true)
        let id = turn.id
        turns.append(turn)
        let transcript = TextAccumulator()
        let flag = cancelFlag
        do {
            try await runtime.generate(prompt: TutorPrompts.asr(), audio: samples, maxTokens: 200, temperature: 0) { piece in
                let sofar = transcript.append(piece).trimmingCharacters(in: .whitespacesAndNewlines)
                Task { @MainActor in
                    self.update(id) { if $0.isStreaming { $0.text = sofar } }
                }
                return !flag.value
            }
        } catch {
            remove(id)
            state = .failed(error.localizedDescription)
            return
        }
        let text = transcript.value.trimmingCharacters(in: .whitespacesAndNewlines)
        update(id) {
            $0.text = text
            $0.isStreaming = false
        }
        if cancelled {
            state = .idle
            return
        }
        if text.isEmpty {
            remove(id)
            state = .failed("I didn't catch that. Hold the phone closer and try again.")
            return
        }
        if checkTones {
            // pitch analysis runs on the CPU alongside the tutor's answer on the GPU
            let sampleRate = runtime.inputSampleRate
            Task.detached(priority: .userInitiated) { [weak self] in
                let checks = ToneChecker.check(samples: samples, sampleRate: sampleRate, transcript: text)
                await self?.setTones(checks, for: id)
            }
        }
        await answer(learnerID: id, learner: text)
    }

    private func answer(learnerID: UUID, learner: String) async {
        guard let runtime else { return }
        cancelFlag.set(false)
        state = .thinking

        let prompt = TutorPrompts.chat(history: history, learner: learner, level: level)
        let turn = Turn(role: .tutor, text: "", isStreaming: true)
        let id = turn.id
        turns.append(turn)

        let raw = TextAccumulator()
        let flag = cancelFlag
        do {
            try await runtime.generate(prompt: prompt, maxTokens: 384, temperature: 0.3) { piece in
                let sofar = raw.append(piece)
                let parsed = TutorReply.parse(sofar)
                Task { @MainActor in
                    self.update(id) {
                        guard $0.isStreaming else { return }
                        $0.text = sofar
                        $0.reply = parsed
                    }
                }
                return !flag.value
            }
        } catch {
            remove(id)
            state = .failed(error.localizedDescription)
            return
        }

        let text = raw.value.trimmingCharacters(in: .whitespacesAndNewlines)
        let reply = TutorReply.parse(text)
        update(id) {
            $0.text = text
            $0.reply = reply
            $0.isStreaming = false
        }
        update(learnerID) { $0.feedback = reply }
        if !text.isEmpty {
            history.append(.init(learner: learner, tutorRaw: text))
        }

        let speech = reply.speakableReply
        guard speakReplies, !speech.isEmpty, !cancelled, turns.contains(where: { $0.id == id }) else {
            state = .idle
            if !cancelled { listenAgainIfHandsFree() }
            return
        }
        await speak(speech, into: id)
    }

    private func speak(_ text: String, into id: UUID) async {
        guard let runtime else { return }
        state = .speaking
        let audio = self.audio
        let flag = cancelFlag
        // Mandarin runs at most ~6-7 syllables a second; much less audio than that means the voice stopped early
        let minSeconds = Double(text.filter(Pinyin.isHanzi).count) * 0.12

        for attempt in 1...2 {
            let pcm = PCMAccumulator()
            audio.beginStream()
            do {
                try await runtime.speak(prompt: TutorPrompts.tts(text, voice: voice)) { chunk, rate in
                    if flag.value { return false }
                    audio.enqueue(chunk, sampleRate: rate)
                    pcm.append(chunk, rate: rate)
                    return true
                }
            } catch {
                audio.stopPlayback()
                state = .failed(error.localizedDescription)
                return
            }
            audio.endStream()
            let (samples, rate) = pcm.value
            update(id) {
                $0.audio = samples
                $0.audioSampleRate = rate
            }
            saveDiagnostics(samples, sampleRate: rate, text: text, attempt: attempt)
            if cancelled {
                state = .idle
                return
            }
            let seconds = Double(samples.count) / rate
            if seconds >= minSeconds || attempt == 2 {
                break
            }
            NSLog("%@", "Edge: speech stopped early (\(String(format: "%.1f", seconds)) s for \(text.count) characters), generating it again")
        }

        audio.whenPlaybackDrained { [weak self] in
            guard let self, self.state == .speaking else { return }
            self.state = .idle
            self.listenAgainIfHandsFree()
        }
    }

    /// Hands-free conversation: the mic opens again once the tutor has finished.
    private func listenAgainIfHandsFree() {
        guard handsFree, state == .idle, runtime != nil else { return }
        Task { await startRecording() }
    }

    /// Keeps the last reply's audio in Files › Edge › Diagnostics, to tell a short voice from a playback problem.
    private func saveDiagnostics(_ samples: [Float], sampleRate: Double, text: String, attempt: Int) {
        let dir = ModelStore.modelsDirectory.appendingPathComponent("Diagnostics", isDirectory: true)
        let seconds = Double(samples.count) / sampleRate
        let note = "text: \(text)\nattempt: \(attempt)\naudio: \(String(format: "%.2f", seconds)) s at \(Int(sampleRate)) Hz\n"
        Task.detached(priority: .utility) {
            try? AudioIO.writeWAV(samples, sampleRate: sampleRate, to: dir.appendingPathComponent("last-reply.wav"))
            try? note.write(to: dir.appendingPathComponent("last-reply.txt"), atomically: true, encoding: .utf8)
        }
    }

    func replay(_ turn: Turn) {
        guard !turn.audio.isEmpty, !state.isBusy, state != .listening else { return }
        audio.play(turn.audio, sampleRate: turn.audioSampleRate)
    }

    func stop() {
        cancelFlag.set(true)
        cancelListening()
        audio.stopPlayback()
        if state == .speaking { state = .idle }
    }

    func reset() {
        stop()
        turns.removeAll()
        history.removeAll()
        if runtime != nil { state = .idle }
    }
}

extension TutorSession.State {
    var isFailedState: Bool {
        if case .failed = self { return true }
        return false
    }
}

/// PCM streamed from the engine queue; the final value is read once generation returns.
final class PCMAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    private var rate: Double = 24_000
    var value: ([Float], Double) { lock.lock(); defer { lock.unlock() }; return (samples, rate) }
    func append(_ chunk: [Float], rate r: Double) { lock.lock(); samples += chunk; rate = r; lock.unlock() }
}

/// Text streamed from the engine queue; the final value is read once generation returns.
final class TextAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    var value: String { lock.lock(); defer { lock.unlock() }; return text }
    func append(_ piece: String) -> String { lock.lock(); defer { lock.unlock() }; text += piece; return text }
}

final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return _value }
    func set(_ v: Bool) { lock.lock(); _value = v; lock.unlock() }
}
