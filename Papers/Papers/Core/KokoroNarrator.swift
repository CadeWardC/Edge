import Foundation
import SherpaOnnx

/// The voices of Kokoro-82M v1.0 the app offers (ids in sherpa-onnx's kokoro-multi-lang-v1_0 voices.bin).
enum NarratorVoice: String, CaseIterable, Identifiable, Codable {
    case heart, bella, nicole, michael, fenrir, puck, emma, george

    var id: String { rawValue }

    var speakerID: Int {
        switch self {
        case .heart: return 3
        case .bella: return 2
        case .nicole: return 6
        case .michael: return 16
        case .fenrir: return 14
        case .puck: return 18
        case .emma: return 21
        case .george: return 26
        }
    }

    var label: String {
        switch self {
        case .heart: return "Heart (US, female)"
        case .bella: return "Bella (US, female)"
        case .nicole: return "Nicole (US, female, soft)"
        case .michael: return "Michael (US, male)"
        case .fenrir: return "Fenrir (US, male)"
        case .puck: return "Puck (US, male, lively)"
        case .emma: return "Emma (UK, female)"
        case .george: return "George (UK, male)"
        }
    }

    var isFemale: Bool { [.heart, .bella, .nicole, .emma].contains(self) }

    /// The main voice: it explains.
    static var current: NarratorVoice {
        NarratorVoice(rawValue: UserDefaults.standard.string(forKey: "voice") ?? "") ?? .heart
    }

    /// The second voice: it asks the questions that lead into each part, so the in-depth audio sounds like a
    /// conversation and not a lecture. Defaults to a contrasting voice.
    static var host: NarratorVoice {
        if let v = NarratorVoice(rawValue: UserDefaults.standard.string(forKey: "hostVoice") ?? ""), v != current { return v }
        return current.isFemale ? .michael : .heart
    }
}

/// English speech with Kokoro-82M v1.0 (sherpa-onnx, full-precision ONNX, CPU, so it also runs in the background).
/// Text is phonemized by `EnglishPhonemizer` and handed over as phonemes, one sentence at a time.
final class KokoroNarrator: @unchecked Sendable {
    /// Holds model.onnx, voices.bin, tokens.txt and lexicon-us-en.txt.
    let directory: URL
    static let files = ["model.onnx", "voices.bin", "tokens.txt", "lexicon-us-en.txt"]

    init(directory: URL) {
        self.directory = directory
    }

    private let queue = DispatchQueue(label: "papers.kokoro", qos: .userInitiated)
    private var tts: SherpaOnnxOfflineTtsWrapper?
    private var phonemizer: EnglishPhonemizer?

    /// The sample rate of the generated audio (24 kHz for Kokoro).
    private(set) var sampleRate: Double = 24_000

    /// Loads the model and the lexicon. Throws when the files are missing or broken.
    func load() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try self.loadIfNeeded()
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    /// Phoneme chunks (about a sentence each) for `text`.
    func chunks(for text: String) async throws -> [String] {
        try await load()
        return await withCheckedContinuation { cont in
            queue.async { cont.resume(returning: self.phonemizer?.phonemize(text) ?? []) }
        }
    }

    /// Synthesizes one chunk of phonemes; `speed` above 1 is faster.
    func speak(phonemes: String, voice: NarratorVoice, speed: Float) async throws -> [Float] {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                do {
                    try self.loadIfNeeded()
                    guard let tts = self.tts else { throw EngineError.load("The voice is not loaded.") }
                    let codepoints = phonemes.unicodeScalars.map { Int32($0.value) }
                    let config = SherpaOnnxGenerationConfigSwift(silenceScale: 0.2, speed: speed, sid: voice.speakerID,
                                                                 phonemeCodepoints: [codepoints])
                    let audio = tts.generateWithConfig(text: "", config: config, callback: nil, arg: nil)
                    cont.resume(returning: audio.samples)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    /// Words the phonemizer had to guess so far.
    func guessedWords() async -> [String] {
        await withCheckedContinuation { cont in
            queue.async { cont.resume(returning: self.phonemizer?.guessedWords.sorted() ?? []) }
        }
    }

    func unload() {
        queue.async {
            self.tts = nil
            self.phonemizer = nil
        }
    }

    private func loadIfNeeded() throws {
        let path = { (name: String) in self.directory.appendingPathComponent(name).path }
        // the wrapper stops the app on a missing file, so check first
        guard Self.files.allSatisfy({ FileManager.default.fileExists(atPath: path($0)) }) else {
            throw EngineError.load("The voice files are missing. Download the models again in Settings.")
        }
        if phonemizer == nil {
            phonemizer = try EnglishPhonemizer(lexiconURL: directory.appendingPathComponent("lexicon-us-en.txt"))
        }
        if tts != nil { return }
        let kokoro = sherpaOnnxOfflineTtsKokoroModelConfig(
            model: path("model.onnx"),
            voices: path("voices.bin"),
            tokens: path("tokens.txt"),
            lang: "en-us"
        )
        let model = sherpaOnnxOfflineTtsModelConfig(kokoro: kokoro, numThreads: 4, debug: 0)
        var config = sherpaOnnxOfflineTtsConfig(model: model, maxNumSentences: 1)
        let wrapper = SherpaOnnxOfflineTtsWrapper(config: &config)
        guard wrapper.tts != nil else { throw EngineError.load("Could not load the Kokoro voice model.") }
        sampleRate = Double(wrapper.sampleRate)
        tts = wrapper
    }
}
