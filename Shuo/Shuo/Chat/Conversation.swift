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

    var id = UUID()
    let role: Role
    var text: String
    var pinyin: String
    var english = ""
    /// Tone check of the learner's recording, syllable by syllable.
    var tones: [ToneCheck] = []
    /// The learner's recording (16 kHz) or the partner's generated voice (24 kHz), for replay.
    var audio: [Float] = []
    var audioRate: Double = 16_000
    /// How fast it was, e.g. "heard in 0.3 s" or "first word 1.1 s after you stopped".
    var timing: String?

    static func == (a: Turn, b: Turn) -> Bool {
        a.id == b.id && a.text == b.text && a.english == b.english && a.tones == b.tones && a.audio.count == b.audio.count && a.timing == b.timing
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
    @AppStorage("pauseSeconds") var pauseSeconds = 1.5
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
        work = Task { await reply(since: Date()) }
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
        let stoppedAt = Date()
        work = Task { await handle(samples, stoppedAt: stoppedAt) }
    }

    private func handle(_ samples: [Float], stoppedAt: Date) async {
        let text: String
        do {
            // a little silence around the speech helps the recognizer catch the first and last syllables
            let padded = [Float](repeating: 0, count: Int(Self.inputRate * 0.15)) + samples
                + [Float](repeating: 0, count: Int(Self.inputRate * 0.3))
            text = try await SpeechEngines.shared.transcribe(padded, sampleRate: Self.inputRate)
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
        turn.timing = String(format: "heard in %.1f s", Date().timeIntervalSince(stoppedAt))
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
        await reply(since: stoppedAt)
    }

    // MARK: Replying

    /// Asks the chat model and speaks its reply sentence by sentence as it streams in.
    /// `since` is when the learner stopped talking, for the timing shown under the reply.
    private func reply(since: Date) async {
        state = .thinking
        stopFlag.set(false)
        let level = Level(rawValue: levelRaw) ?? .beginner
        let prompt = (customPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Self.defaultPrompt : customPrompt)
            + "\n\n" + level.guidance + "\n\n"
            + "Format: write your reply in Chinese characters only, then a line containing only ---, then its English translation. Nothing else."
        var messages = [ChatClient.Message(role: "system", content: prompt)]
        for t in turns.suffix(16) {
            messages.append(.init(role: t.role == .learner ? "user" : "assistant", content: t.text))
        }
        let provider = self.provider
        let partner = Turn(role: .partner, text: "", pinyin: "")
        let feed = ReplyFeed(turnID: partner.id)
        let (sentences, continuation) = AsyncStream<String>.makeStream()
        feed.continuation = continuation
        defer { continuation.finish() }
        let speaking = Task { await speakSentences(sentences, turnID: partner.id, since: since) }
        do {
            let raw = try await ChatClient(provider: provider).stream(messages, model: provider.model) { sofar in
                Task { @MainActor in Conversation.shared.update(feed, with: sofar, final: false) }
            }
            if Task.isCancelled { speaking.cancel(); return }
            update(feed, with: raw, final: true)
            if !feed.spokeAnything {
                speaking.cancel()
                turns.removeAll { $0.id == partner.id }
                throw AppError("\(provider.title) didn't reply in Chinese. Try again.")
            }
        } catch {
            if Task.isCancelled { return }
            stopFlag.set(true)
            state = .failed(error.localizedDescription)
            handsFree = false
        }
    }

    /// Shows the reply as it streams in and hands each finished Chinese sentence to the voice.
    private func update(_ feed: ReplyFeed, with sofar: String, final: Bool) {
        guard sofar.count >= feed.seenLength || final else { return }   // an older update arriving late
        feed.seenLength = sofar.count
        let (reply, english, replyComplete) = Self.split(sofar)
        if !reply.isEmpty {
            if let i = turns.firstIndex(where: { $0.id == feed.turnID }) {
                turns[i].text = reply
                if final || replyComplete { turns[i].pinyin = Pinyin.romanize(reply) }
                if final { turns[i].english = english }
            } else {
                // the id the speaker uses to attach the audio and timing
                turns.append(Turn(id: feed.turnID, role: .partner, text: reply, pinyin: ""))
            }
        }
        // sentences end at Chinese or Western sentence punctuation, or a line break
        let enders: Set<Character> = ["。", "！", "？", "!", "?", "；", ";", "…", "\n"]
        let chars = Array(reply)
        var i = feed.emitted
        var start = feed.emitted
        while i < chars.count {
            if enders.contains(chars[i]) {
                feed.emit(String(chars[start...i]))
                start = i + 1
            }
            i += 1
        }
        feed.emitted = start
        if (replyComplete || final) && start < chars.count {
            feed.emit(String(chars[start...]))
            feed.emitted = chars.count
        }
        if replyComplete || final { feed.continuation?.finish() }
    }

    /// The Chinese reply, the English translation, and whether the reply part is complete (the --- line arrived).
    static func split(_ raw: String) -> (String, String, Bool) {
        let lines = raw.components(separatedBy: "\n")
        if let sep = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("---") }) {
            let reply = lines[..<sep].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            let english = lines[(sep + 1)...].joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            return (reply, english, true)
        }
        // a partly received separator line ("-", "--") is not part of the reply
        var reply = raw
        while let last = reply.last, last == "-" || last == "\n" || last == " " { reply.removeLast() }
        return (reply.trimmingCharacters(in: .whitespacesAndNewlines), "", false)
    }

    // MARK: Speaking

    /// Speaks sentences as they arrive: Kokoro streams each one into the player; the iPhone voice queues them.
    private func speakSentences(_ sentences: AsyncStream<String>, turnID: UUID, since: Date) async {
        let flag = stopFlag
        let firstAudio = TimeBox()
        let markSpoken: @MainActor () -> Void = { [weak self] in
            guard let self, let at = firstAudio.value,
                  let i = self.turns.firstIndex(where: { $0.id == turnID }) else { return }
            self.turns[i].timing = String(format: "first word %.1f s after you stopped", at.timeIntervalSince(since))
        }
        if ModelStore.isInstalled(.voice) {
            let audio = self.audio
            let collected = SampleBox()
            var started = false
            for await sentence in sentences {
                if flag.value || Task.isCancelled { break }
                let speech = Self.speakable(sentence)
                guard !speech.isEmpty else { continue }
                if !started {
                    started = true
                    audio.setPlaybackRate(1)
                    audio.beginStream()
                    if state == .thinking { state = .speaking }
                }
                do {
                    for piece in Self.pieces(speech) where !flag.value {
                        _ = try await SpeechEngines.shared.synthesize(piece, speakerID: kokoroVoice, speed: Float(speechRate)) { chunk, rate in
                            if flag.value { return false }
                            firstAudio.markOnce()
                            audio.enqueue(chunk, sampleRate: rate)
                            collected.append(chunk)
                            return true
                        }
                    }
                } catch {
                    audio.stopPlayback()
                    state = .failed(error.localizedDescription)
                    handsFree = false
                    return
                }
                markSpoken()
            }
            guard started, !flag.value else { return }
            audio.endStream()
            if let i = turns.firstIndex(where: { $0.id == turnID }) {
                turns[i].audio = collected.value
                turns[i].audioRate = Double(SpeechEngines.ttsSampleRate)
            }
            audio.whenPlaybackDrained { [weak self] in self?.doneSpeaking() }
        } else {
            var started = false
            for await sentence in sentences {
                if flag.value || Task.isCancelled { break }
                let speech = Self.speakable(sentence)
                guard !speech.isEmpty else { continue }
                if !started {
                    started = true
                    AppleSpeaker.shared.stop()
                    if state == .thinking { state = .speaking }
                }
                firstAudio.markOnce()
                AppleSpeaker.shared.enqueue(speech, rate: Float(speechRate))
                markSpoken()
            }
            guard started, !flag.value else { return }
            AppleSpeaker.shared.finishQueue { [weak self] in self?.doneSpeaking() }
        }
    }

    /// A long sentence cut at commas into pieces of at most ~40 characters, so the voice model never gets
    /// more than it can handle in one go (and the first piece is ready sooner).
    static func pieces(_ sentence: String, limit: Int = 40) -> [String] {
        guard sentence.count > limit else { return [sentence] }
        var out: [String] = []
        var current = ""
        for c in sentence {
            current.append(c)
            if "，、,：:".contains(c) && current.count >= 8 {
                out.append(current)
                current = ""
            } else if current.count >= limit * 3 / 2 {
                out.append(current)   // no comma for a long stretch: cut anyway
                current = ""
            }
        }
        if !current.isEmpty {
            if current.count < 4, let last = out.popLast() { out.append(last + current) } else { out.append(current) }
        }
        // join neighbours back up to the limit so there aren't many tiny pieces
        var merged: [String] = []
        for p in out {
            if let last = merged.last, last.count + p.count <= limit { merged[merged.count - 1] = last + p } else { merged.append(p) }
        }
        return merged
    }

    /// Only the Chinese is spoken (no pinyin or English the model may have added in brackets).
    static func speakable(_ sentence: String) -> String {
        let s = sentence
            .replacingOccurrences(of: #"\([^)]*\)|（[^）]*）"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return s.contains(where: Pinyin.isHanzi) ? s : ""
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

/// Tracks one streamed reply: what has been shown, and which sentences went to the voice.
@MainActor
final class ReplyFeed {
    let turnID: UUID
    var seenLength = 0
    var emitted = 0
    var spokeAnything = false
    var continuation: AsyncStream<String>.Continuation?

    init(turnID: UUID) { self.turnID = turnID }

    func emit(_ sentence: String) {
        guard sentence.contains(where: Pinyin.isHanzi) else { return }
        spokeAnything = true
        continuation?.yield(sentence)
    }
}

final class TimeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var time: Date?
    var value: Date? { lock.lock(); defer { lock.unlock() }; return time }
    func markOnce() { lock.lock(); if time == nil { time = Date() }; lock.unlock() }
}

final class SampleBox: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    var value: [Float] { lock.lock(); defer { lock.unlock() }; return samples }
    func append(_ chunk: [Float]) { lock.lock(); samples += chunk; lock.unlock() }
}
