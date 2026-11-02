import AVFoundation
import Foundation
import Speech

/// On-device Mandarin recognition (SenseVoice) and speech (Kokoro), with the iPhone's own recognizer and voice
/// as fallbacks until the models are downloaded. Model calls run on a private serial queue.
final class SpeechEngines: @unchecked Sendable {
    static let shared = SpeechEngines()
    static let ttsSampleRate = 24_000

    private let queue = DispatchQueue(label: "shuo.speech", qos: .userInitiated)
    private var recognizer: SherpaOnnxOfflineRecognizer?
    private var tts: SherpaOnnxOfflineTtsWrapper?

    private var threads: Int { min(4, max(2, ProcessInfo.processInfo.activeProcessorCount - 2)) }

    // MARK: Recognition

    /// What was said in Mandarin. Uses SenseVoice when it is downloaded, otherwise the iPhone's recognizer.
    func transcribe(_ samples: [Float], sampleRate: Double) async throws -> String {
        if ModelStore.isInstalled(.recognition) {
            return try await withCheckedThrowingContinuation { cont in
                queue.async {
                    guard let recognizer = self.loadRecognizer() else {
                        cont.resume(throwing: AppError("SenseVoice could not be loaded. Delete and download it again in Settings."))
                        return
                    }
                    let result = recognizer.decode(samples: samples, sampleRate: Int(sampleRate))
                    cont.resume(returning: result.text.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }
        }
        return try await AppleRecognizer.transcribe(samples, sampleRate: sampleRate)
    }

    private func loadRecognizer() -> SherpaOnnxOfflineRecognizer? {
        if let recognizer { return recognizer }
        let dir = ModelStore.directory(.recognition)
        let model = dir.appendingPathComponent("model.int8.onnx").path
        let tokens = dir.appendingPathComponent("tokens.txt").path
        // the wrapper stops the app on a bad model, so check the files first
        guard FileManager.default.fileExists(atPath: model), FileManager.default.fileExists(atPath: tokens) else { return nil }
        let senseVoice = sherpaOnnxOfflineSenseVoiceModelConfig(model: model, language: "zh", useInverseTextNormalization: true)
        let modelConfig = sherpaOnnxOfflineModelConfig(tokens: tokens, numThreads: threads, senseVoice: senseVoice)
        var config = sherpaOnnxOfflineRecognizerConfig(featConfig: sherpaOnnxFeatureConfig(sampleRate: 16_000, featureDim: 80),
                                                       modelConfig: modelConfig)
        recognizer = SherpaOnnxOfflineRecognizer(config: &config)
        return recognizer
    }

    // MARK: Speech

    /// Speaks `text` with Kokoro, handing each sentence's audio to `onAudio`; return false to stop.
    /// Returns false when Kokoro isn't downloaded (the caller then uses the iPhone's voice).
    func synthesize(_ text: String, speakerID: Int, speed: Float,
                    onAudio: @escaping @Sendable ([Float], Double) -> Bool) async throws -> Bool {
        guard ModelStore.isInstalled(.voice) else { return false }
        return try await withCheckedThrowingContinuation { cont in
            queue.async {
                guard let tts = self.loadTTS() else {
                    cont.resume(throwing: AppError("The Mandarin voice could not be loaded. Delete and download it again in Settings."))
                    return
                }
                let sink = Sink(onAudio)
                let box = Unmanaged.passRetained(sink).toOpaque()
                defer { Unmanaged<Sink>.fromOpaque(box).release() }
                let callback: TtsProgressCallbackWithArg = { samples, n, _, arg in
                    guard let arg else { return 1 }
                    let sink = Unmanaged<Sink>.fromOpaque(arg).takeUnretainedValue()
                    guard let samples, n > 0 else { return sink.stopped ? 0 : 1 }
                    return sink.deliver(Array(UnsafeBufferPointer(start: samples, count: Int(n)))) ? 1 : 0
                }
                let config = SherpaOnnxGenerationConfigSwift(silenceScale: 0.2, speed: speed, sid: speakerID)
                let audio = tts.generateWithConfig(text: text, config: config, callback: callback, arg: box)
                if !sink.delivered && !sink.stopped, audio.audio != nil, audio.n > 0 {
                    _ = sink.deliver(audio.samples)
                }
                cont.resume(returning: true)
            }
        }
    }

    private func loadTTS() -> SherpaOnnxOfflineTtsWrapper? {
        if let tts { return tts }
        let dir = ModelStore.directory(.voice)
        let path = { (name: String) in dir.appendingPathComponent(name).path }
        for name in ["model.onnx", "voices.bin", "tokens.txt", "lexicon-zh.txt", "dict", "espeak-ng-data"]
        where !FileManager.default.fileExists(atPath: path(name)) {
            return nil
        }
        let kokoro = sherpaOnnxOfflineTtsKokoroModelConfig(
            model: path("model.onnx"),
            voices: path("voices.bin"),
            tokens: path("tokens.txt"),
            dataDir: path("espeak-ng-data"),
            dictDir: path("dict"),
            lexicon: "\(path("lexicon-us-en.txt")),\(path("lexicon-zh.txt"))",
            lang: "zh"
        )
        let model = sherpaOnnxOfflineTtsModelConfig(kokoro: kokoro, numThreads: threads)
        // dates, phone numbers and numbers are read as Chinese words
        var config = sherpaOnnxOfflineTtsConfig(
            model: model,
            ruleFsts: ["date-zh.fst", "phone-zh.fst", "number-zh.fst"].map(path).joined(separator: ","),
            maxNumSentences: 1
        )
        let wrapper = SherpaOnnxOfflineTtsWrapper(config: &config)
        guard wrapper.tts != nil else { return nil }
        tts = wrapper
        return wrapper
    }

    func unload() {
        queue.async {
            self.recognizer = nil
            self.tts = nil
        }
    }
}

private final class Sink {
    let fn: @Sendable ([Float], Double) -> Bool
    private(set) var delivered = false
    private(set) var stopped = false

    init(_ fn: @escaping @Sendable ([Float], Double) -> Bool) { self.fn = fn }

    func deliver(_ samples: [Float]) -> Bool {
        guard !stopped else { return false }
        if !samples.isEmpty { delivered = true }
        if !fn(samples, Double(SpeechEngines.ttsSampleRate)) { stopped = true }
        return !stopped
    }
}

/// The iPhone's Mandarin speech recognizer (on device where supported), used until SenseVoice is downloaded.
enum AppleRecognizer {
    static func transcribe(_ samples: [Float], sampleRate: Double) async throws -> String {
        let status = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
        }
        guard status == .authorized else {
            throw AppError("Download the Mandarin recognition model in Settings, or allow Speech Recognition for Shuō in iOS Settings.")
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")), recognizer.isAvailable else {
            throw AppError("The iPhone's Mandarin recognizer isn't available. Download the Mandarin recognition model in Settings.")
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("utterance.wav")
        try AudioIO.writeWAV(samples, sampleRate: sampleRate, to: url)
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        return try await withCheckedThrowingContinuation { cont in
            var done = false
            recognizer.recognitionTask(with: request) { result, error in
                guard !done else { return }
                if let result, result.isFinal {
                    done = true
                    cont.resume(returning: result.bestTranscription.formattedString)
                } else if let error {
                    done = true
                    // "no speech detected" comes back as an error
                    if (error as NSError).code == 1110 { cont.resume(returning: "") } else { cont.resume(throwing: error) }
                }
            }
        }
    }
}

/// The iPhone's Chinese voice, used until Kokoro is downloaded.
@MainActor
final class AppleSpeaker: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = AppleSpeaker()
    private let synthesizer = AVSpeechSynthesizer()
    private var finish: (() -> Void)?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// Speaks and calls `done` when finished or stopped.
    func speak(_ text: String, rate: Float, done: @escaping () -> Void) {
        stop()
        let utterance = AVSpeechUtterance(string: text)
        // the best installed Mandarin voice (enhanced or premium ones can be added in iOS Settings › Accessibility)
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == "zh-CN" }
        utterance.voice = voices.max { $0.quality.rawValue < $1.quality.rawValue } ?? AVSpeechSynthesisVoice(language: "zh-CN")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * rate
        finish = done
        try? AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP])
        synthesizer.speak(utterance)
    }

    func stop() {
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        complete()
    }

    var isSpeaking: Bool { synthesizer.isSpeaking }

    private func complete() {
        let f = finish
        finish = nil
        f?()
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.complete() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.complete() }
    }
}
