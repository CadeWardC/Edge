import Foundation
import SwiftUI

enum Level: String, CaseIterable, Identifiable {
    case beginner, intermediate, advanced
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var guidance: String {
        switch self {
        case .beginner: return "The learner is a beginner: use very simple HSK 1-2 words and short sentences."
        case .intermediate: return "The learner is intermediate: use everyday HSK 3-4 vocabulary."
        case .advanced: return "The learner is advanced: speak naturally like a native speaker, idioms welcome."
        }
    }
}

/// One message in the conversation.
struct Turn: Identifiable, Equatable {
    enum Role: Equatable { case learner, partner }

    let id = UUID()
    let role: Role
    var text: String
    var pinyin: String
    var english = ""
    /// Tone check of the learner's recording, syllable by syllable.
    var tones: [ToneCheck] = []
    /// The learner's recording (16 kHz) or the partner's generated voice (24 kHz), for replay.
    var audio: [Float] = []
    var audioRate: Double = 16_000

    static func == (a: Turn, b: Turn) -> Bool {
        a.id == b.id && a.text == b.text && a.english == b.english && a.tones == b.tones && a.audio.count == b.audio.count
    }
}

/// The spoken conversation: listen, recognize, check tones, ask DeepSeek or Kimi, speak the reply.
@MainActor
final class Conversation: ObservableObject {
    enum State: Equatable {
        case idle, listening, transcribing, thinking, speaking
        case failed(String)

        var isBusy: Bool { self == .transcribing || self == .thinking }
    }

    static let shared = Conversation()
    static let inputRate: Double = 16_000

    static let defaultPrompt = """
    You are 小林 (Xiǎo Lín), a friendly Mandarin conversation partner for an English-speaking learner. Reply to what \
    the learner says in natural spoken Mandarin with simplified characters: one to three short sentences, usually \
    ending with a question that keeps the conversation going. The learner's words come from speech recognition, so \
    guess the intended meaning when a word looks wrong. If the learner speaks English or seems stuck, help them say \
    it in Chinese.
    """

    @Published private(set) var state: State = .idle
    @Published private(set) var turns: [Turn] = []
    @Published private(set) var level: Double = 0          // mic level 0...1
    @Published private(set) var heardSpeech = false
    @Published var notice: String?

    @AppStorage("provider") var providerRaw = Provider.deepseek.rawValue
    @AppStorage("level") var levelRaw = Level.beginner.rawValue
    @AppStorage("systemPrompt") var customPrompt = ""
    @AppStorage("handsFree") var handsFree = false
    @AppStorage("pauseSeconds") var pauseSeconds = 1.4
    @AppStorage("speechRate") var speechRate = 1.0
    @AppStorage("kokoroVoice") var kokoroVoice = 3

    var provider: Provider { Provider(rawValue: providerRaw) ?? .deepseek }

    private let audio = AudioIO()
    private var meter: Timer?
    private var work: Task<Void, Never>?
    private let stopFlag = AtomicFlag()

    // MARK: Controls

    /// The mic button: start listening, send what was said, or interrupt the reply and listen.
    func micTapped() {
        switch state {
        case .listening:
            finishListening()
        case .speaking:
            stopSpeaking()
            startListening()
        case .idle, .failed:
            startListening()
        default:
            break
        }
    }

    func toggleHandsFree() {
        handsFree.toggle()
        notice = nil
        if handsFree, state == .idle || state.isFailed { startListening() }
        if !handsFree, state == .listening { cancelListening() }
    }

    /// Stops everything (listening, waiting for the reply, speaking) and hands-free.
    func stopAll() {
        handsFree = false
        work?.cancel()
        work = nil
        cancelListening()
        stopSpeaking()
        state = .idle
    }

    func clear() {
        stopAll()
        turns.removeAll()
    }

    /// Typed input skips recognition (and the tone check).
    func send(text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !state.isBusy else { return }
        stopSpeaking()
        turns.append(Turn(role: .learner, text: t, pinyin: Pinyin.romanize(t)))
        work = Task { await reply() }
    }

    func replay(_ turn: Turn) {
        guard state == .idle || state.isFailed || state == .speaking else { return }
        stopSpeaking()
        if !turn.audio.isEmpty {
            audio.setPlaybackRate(1)
            audio.play(turn.audio, sampleRate: turn.audioRate)
        } else if turn.role == .partner {
            AppleSpeaker.shared.speak(turn.text, rate: Float(speechRate)) {}
        }
    }

    // MARK: Listening

    private func startListening() {
        Task {
            guard await AudioIO.requestMicrophone() else {
                state = .failed("Microphone access is off. Allow it in iOS Settings › Privacy › Microphone.")
                handsFree = false
                return
            }
            do {
                try audio.startRecording(sampleRate: Self.inputRate)
            } catch {
                state = .failed(error.localizedDescription)
                return
            }
            state = .listening
            level = 0
            heardSpeech = false
            meter?.invalidate()
            meter = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
                Task { @MainActor in Conversation.shared.tick() }
            }
        }
    }

    private func tick() {
        guard state == .listening else { return }
        let activity = audio.voiceActivity
        level = activity.level
        heardSpeech = activity.speechDetected
        let seconds = audio.recordedSeconds
        if seconds >= AudioIO.maxRecordingSeconds {
            finishListening()
        } else if activity.speechDetected, activity.silenceSeconds >= pauseSeconds {
            finishListening()
        } else if !activity.speechDetected, seconds >= (handsFree ? 20 : 8) {
            cancelListening()
            if handsFree {
                handsFree = false
                notice = "Hands-free paused: nothing was said for a while. Tap ∞ to start again."
            }
        }
    }

    private func cancelListening() {
        meter?.invalidate()
        meter = nil
        if audio.isRecording { _ = audio.stopRecording() }
        level = 0
        if state == .listening { state = .idle }
    }

    private func finishListening() {
        guard state == .listening else { return }
        meter?.invalidate()
        meter = nil
        level = 0
        let samples = audio.stopRecording(trimSilence: true)
        guard Double(samples.count) >= Self.inputRate * 0.4 else {
            state = .idle
            continueHandsFree()
            return
        }
        state = .transcribing
        work = Task { await handle(samples) }
    }

    private func handle(_ samples: [Float]) async {
        let text: String
        do {
            text = try await SpeechEngines.shared.transcribe(samples, sampleRate: Self.inputRate)
        } catch {
            state = .failed(error.localizedDescription)
            handsFree = false
            return
        }
        if Task.isCancelled { return }
        guard text.contains(where: Pinyin.isHanzi) || text.contains(where: \.isLetter) else {
            notice = "I didn't catch that. Try again a little closer to the phone."
            state = .idle
            continueHandsFree()
            return
        }
        notice = nil
        var turn = Turn(role: .learner, text: text, pinyin: Pinyin.romanize(text))
        turn.audio = samples
        turn.audioRate = Self.inputRate
        turns.append(turn)
        let id = turn.id
        let rate = Self.inputRate
        // the tone check runs alongside the request
        Task.detached(priority: .userInitiated) {
            let checks = ToneChecker.check(samples: samples, sampleRate: rate, transcript: text)
            await MainActor.run {
                if let i = Conversation.shared.turns.firstIndex(where: { $0.id == id }) {
                    Conversation.shared.turns[i].tones = checks
                }
            }
        }
        await reply()
    }

    // MARK: Replying

    private func reply() async {
        state = .thinking
        let level = Level(rawValue: levelRaw) ?? .beginner
        let prompt = (customPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Self.defaultPrompt : customPrompt)
            + "\n\n" + level.guidance + "\n\n"
            + #"Answer with a JSON object only, in this form: {"reply": "your reply in Chinese characters", "english": "its English translation"}"#
        var messages = [ChatClient.Message(role: "system", content: prompt)]
        for t in turns.suffix(16) {
            messages.append(.init(role: t.role == .learner ? "user" : "assistant", content: t.text))
        }
        let provider = self.provider
        do {
            let raw = try await ChatClient(provider: provider).complete(messages, model: provider.model, json: true)
            if Task.isCancelled { return }
            let (reply, english) = Self.parse(raw)
            guard !reply.isEmpty else { throw AppError("\(provider.title) didn't reply in Chinese. Try again.") }
            let turn = Turn(role: .partner, text: reply, pinyin: Pinyin.romanize(reply), english: english)
            turns.append(turn)
            await speak(turn)
        } catch {
            if Task.isCancelled { return }
            state = .failed(error.localizedDescription)
            handsFree = false
        }
    }

    /// The reply and translation from the model's JSON (or the whole text when it ignored the format).
    static func parse(_ raw: String) -> (String, String) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end {
            text = String(text[start...end])
            if let data = text.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let reply = (obj["reply"] as? String) ?? (obj["chinese"] as? String) ?? ""
                let english = (obj["english"] as? String) ?? (obj["translation"] as? String) ?? ""
                return (reply.trimmingCharacters(in: .whitespacesAndNewlines), english.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        return (raw.trimmingCharacters(in: .whitespacesAndNewlines), "")
    }

    // MARK: Speaking

    private func speak(_ turn: Turn) async {
        state = .speaking
        stopFlag.set(false)
        // only the Chinese is spoken (no pinyin or English the model may have added in brackets)
        let speech = turn.text
            .replacingOccurrences(of: #"\([^)]*\)|（[^）]*）"#, with: "", options: .regularExpression)
        let audio = self.audio
        let flag = stopFlag
        let collected = SampleBox()
        audio.setPlaybackRate(1)
        audio.beginStream(expectedSeconds: Double(speech.count) * 0.25 / max(speechRate, 0.5))
        do {
            let usedKokoro = try await SpeechEngines.shared.synthesize(speech, speakerID: kokoroVoice, speed: Float(speechRate)) { chunk, rate in
                if flag.value { return false }
                audio.enqueue(chunk, sampleRate: rate)
                collected.append(chunk)
                return true
            }
            if usedKokoro {
                audio.endStream()
                if let i = turns.firstIndex(where: { $0.id == turn.id }) {
                    turns[i].audio = collected.value
                    turns[i].audioRate = Double(SpeechEngines.ttsSampleRate)
                }
                audio.whenPlaybackDrained { [weak self] in self?.doneSpeaking() }
            } else {
                audio.stopPlayback()
                AppleSpeaker.shared.speak(speech, rate: Float(speechRate)) { [weak self] in self?.doneSpeaking() }
            }
        } catch {
            audio.stopPlayback()
            state = .failed(error.localizedDescription)
            handsFree = false
        }
    }

    private func doneSpeaking() {
        guard state == .speaking else { return }
        state = .idle
        continueHandsFree()
    }

    private func stopSpeaking() {
        stopFlag.set(true)
        audio.stopPlayback()
        AppleSpeaker.shared.stop()
        if state == .speaking { state = .idle }
    }

    /// In hands-free mode the mic opens again after each reply.
    private func continueHandsFree() {
        guard handsFree else { return }
        Task {
            // let the speaker's last sound die away so it isn't heard as the learner
            try? await Task.sleep(nanoseconds: 450_000_000)
            if handsFree, state == .idle { startListening() }
        }
    }
}

extension Conversation.State {
    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}

final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return _value }
    func set(_ v: Bool) { lock.lock(); _value = v; lock.unlock() }
}

final class SampleBox: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    var value: [Float] { lock.lock(); defer { lock.unlock() }; return samples }
    func append(_ chunk: [Float]) { lock.lock(); samples += chunk; lock.unlock() }
}
