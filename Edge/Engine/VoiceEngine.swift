import Foundation

/// Speaks text with sherpa-onnx on the CPU: in a cloned voice (ZipVoice or Pocket TTS) or a built-in one (Kokoro).
/// One model is kept in memory at a time; every call runs on a private serial queue.
final class VoiceEngine: @unchecked Sendable {
    static let shared = VoiceEngine()
    static let sampleRate = 24_000

    struct Request {
        var text: String
        var model: VoiceModel
        /// The voice sample: mono, at `referenceSampleRate` (cloning models only).
        var reference: [Float] = []
        var referenceSampleRate: Int = VoiceEngine.sampleRate
        /// What is said in the sample (ZipVoice needs it; Pocket TTS ignores it).
        var referenceText: String = ""
        /// Kokoro's speaker id for a built-in voice.
        var speakerID: Int = 0
        var speed: Float = 1
        var steps: Int
    }

    private let queue = DispatchQueue(label: "edge.voice", qos: .userInitiated)
    private var loaded: (model: VoiceModel, tts: SherpaOnnxOfflineTtsWrapper)?

    /// Generates `request.text`, handing each finished sentence to `onAudio` with the overall progress (0...1).
    /// Return false from `onAudio` to stop. Returns the sample rate of the audio.
    @discardableResult
    func speak(_ request: Request, onAudio: @escaping @Sendable ([Float], Double) -> Bool) async throws -> Int {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int, Error>) in
            queue.async {
                do {
                    let tts = try self.load(request.model)
                    let sink = AudioSink(onAudio)
                    let box = Unmanaged.passRetained(sink).toOpaque()
                    defer { Unmanaged<AudioSink>.fromOpaque(box).release() }
                    let callback: TtsProgressCallbackWithArg = { samples, n, progress, arg in
                        guard let arg else { return 1 }
                        let sink = Unmanaged<AudioSink>.fromOpaque(arg).takeUnretainedValue()
                        guard let samples, n > 0 else { return sink.stopped ? 0 : 1 }
                        let chunk = Array(UnsafeBufferPointer(start: samples, count: Int(n)))
                        return sink.deliver(chunk, Double(progress)) ? 1 : 0
                    }
                    let config = SherpaOnnxGenerationConfigSwift(
                        silenceScale: 0.2,
                        speed: request.speed,
                        sid: request.model == .kokoro ? request.speakerID : 0,
                        referenceAudio: request.model == .kokoro ? [] : request.reference,
                        referenceSampleRate: request.referenceSampleRate,
                        referenceText: request.model == .best ? request.referenceText : "",
                        numSteps: request.model == .kokoro ? 1 : request.steps
                    )
                    let audio = tts.generateWithConfig(text: request.text, config: config, callback: callback, arg: box)
                    // some models only return the audio at the end instead of sentence by sentence
                    if !sink.delivered && !sink.stopped, audio.audio != nil, audio.n > 0 {
                        _ = sink.deliver(audio.samples, 1)
                    }
                    let rate = audio.audio != nil && audio.sampleRate > 0 ? Int(audio.sampleRate) : Self.sampleRate
                    if !sink.delivered && !sink.stopped {
                        throw AppError("The voice model produced no audio for this text.")
                    }
                    cont.resume(returning: rate)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    /// Frees the loaded model (after any running call).
    func unload() {
        queue.async { self.loaded = nil }
    }

    private func load(_ model: VoiceModel) throws -> SherpaOnnxOfflineTtsWrapper {
        if let loaded, loaded.model == model { return loaded.tts }
        loaded = nil   // free the other model first
        guard ModelStore.isInstalled(model) else {
            throw AppError("The \(model.title) voice model (\(model.modelName)) isn't downloaded yet. Download it in Settings.")
        }
        let dir = ModelStore.directory(model)
        let path = { (name: String) in dir.appendingPathComponent(name).path }
        for name in Self.requiredFiles(model) where !FileManager.default.fileExists(atPath: path(name)) {
            throw AppError("The \(model.modelName) files are incomplete (\(name) is missing). Delete and download it again in Settings.")
        }
        let threads = min(4, max(2, ProcessInfo.processInfo.activeProcessorCount - 2))
        let modelConfig: SherpaOnnxOfflineTtsModelConfig
        switch model {
        case .best:
            let zipvoice = sherpaOnnxOfflineTtsZipvoiceModelConfig(
                tokens: path("tokens.txt"),
                encoder: path("text_encoder.onnx"),
                decoder: path("fm_decoder.onnx"),
                vocoder: path("vocos_24khz.onnx"),
                dataDir: path("espeak-ng-data"),
                lexicon: path("lexicon.txt")
            )
            modelConfig = sherpaOnnxOfflineTtsModelConfig(numThreads: threads, zipvoice: zipvoice)
        case .fast:
            let pocket = sherpaOnnxOfflineTtsPocketModelConfig(
                lmFlow: path("lm_flow.int8.onnx"),
                lmMain: path("lm_main.int8.onnx"),
                encoder: path("encoder.onnx"),
                decoder: path("decoder.int8.onnx"),
                textConditioner: path("text_conditioner.onnx"),
                vocabJson: path("vocab.json"),
                tokenScoresJson: path("token_scores.json")
            )
            modelConfig = sherpaOnnxOfflineTtsModelConfig(numThreads: threads, pocket: pocket)
        case .kokoro:
            let kokoro = sherpaOnnxOfflineTtsKokoroModelConfig(
                model: path("model.onnx"),
                voices: path("voices.bin"),
                tokens: path("tokens.txt"),
                dataDir: path("espeak-ng-data"),
                lexicon: path("lexicon-us-en.txt"),
                lang: "en-us"
            )
            modelConfig = sherpaOnnxOfflineTtsModelConfig(kokoro: kokoro, numThreads: threads)
        }
        var config = sherpaOnnxOfflineTtsConfig(model: modelConfig, maxNumSentences: 1)
        let tts = SherpaOnnxOfflineTtsWrapper(config: &config)
        guard tts.tts != nil else {
            throw AppError("The \(model.modelName) model could not be loaded. Delete and download it again in Settings.")
        }
        loaded = (model, tts)
        return tts
    }

    static func requiredFiles(_ model: VoiceModel) -> [String] {
        switch model {
        case .best:
            return ["tokens.txt", "text_encoder.onnx", "fm_decoder.onnx", "vocos_24khz.onnx", "lexicon.txt", "espeak-ng-data"]
        case .fast:
            return ["lm_flow.int8.onnx", "lm_main.int8.onnx", "encoder.onnx", "decoder.int8.onnx",
                    "text_conditioner.onnx", "vocab.json", "token_scores.json"]
        case .kokoro:
            return ["model.onnx", "voices.bin", "tokens.txt", "lexicon-us-en.txt", "espeak-ng-data"]
        }
    }
}

/// Passes audio from the C callback to Swift; remembers whether anything was delivered or the caller stopped.
private final class AudioSink {
    let fn: @Sendable ([Float], Double) -> Bool
    private(set) var delivered = false
    private(set) var stopped = false

    init(_ fn: @escaping @Sendable ([Float], Double) -> Bool) { self.fn = fn }

    func deliver(_ samples: [Float], _ progress: Double) -> Bool {
        guard !stopped else { return false }
        if !samples.isEmpty { delivered = true }
        if !fn(samples, progress) { stopped = true }
        return !stopped
    }
}
