import Foundation
import SherpaOnnx

/// Mandarin speech with Kokoro-82M v1.1-zh (sherpa-onnx, full-precision ONNX, CPU).
/// Loaded on first use and kept until `unload()`; every call runs on a private serial queue.
final class KokoroSpeaker: @unchecked Sendable {
    /// Speaker ids in voices.bin: 0-2 are English, 3-57 Chinese female (zf_001…), 58-102 Chinese male (zm_009…).
    static func speakerID(for voice: Voice) -> Int {
        voice == .female ? 3 : 58
    }

    private let queue = DispatchQueue(label: "edge.kokoro", qos: .userInitiated)
    private var tts: SherpaOnnxOfflineTtsWrapper?

    /// Speaks `text`, handing each sentence's audio to `onChunk` as soon as it is ready; return false to stop.
    /// `speed` above 1 is faster. Returns false when the model files are missing.
    func speak(_ text: String, voice: Voice, speed: Float,
               onChunk: @escaping @Sendable ([Float], Double) -> Bool) async -> Bool {
        await withCheckedContinuation { cont in
            queue.async {
                guard let tts = self.loadIfNeeded() else {
                    cont.resume(returning: false)
                    return
                }
                let sink = ChunkSink(rate: Double(tts.sampleRate), onChunk)
                let box = Unmanaged.passRetained(sink).toOpaque()
                defer { Unmanaged<ChunkSink>.fromOpaque(box).release() }
                let callback: TtsProgressCallbackWithArg = { samples, n, _, arg in
                    guard let samples, let arg, n > 0 else { return 1 }
                    let sink = Unmanaged<ChunkSink>.fromOpaque(arg).takeUnretainedValue()
                    let chunk = Array(UnsafeBufferPointer(start: samples, count: Int(n)))
                    return sink.fn(chunk, sink.rate) ? 1 : 0
                }
                let config = SherpaOnnxGenerationConfigSwift(silenceScale: 0.2, speed: speed,
                                                              sid: Self.speakerID(for: voice))
                _ = tts.generateWithConfig(text: text, config: config, callback: callback, arg: box)
                cont.resume(returning: true)
            }
        }
    }

    func unload() {
        queue.async { self.tts = nil }
    }

    private func loadIfNeeded() -> SherpaOnnxOfflineTtsWrapper? {
        if let tts { return tts }
        // the wrapper stops the app on a missing file, so check first
        guard ModelStore.kokoroFiles.keys.allSatisfy({
            FileManager.default.fileExists(atPath: ModelStore.kokoroURL($0).path)
        }) else { return nil }
        let path = { (name: String) in ModelStore.kokoroURL(name).path }
        let kokoro = sherpaOnnxOfflineTtsKokoroModelConfig(
            model: path("model.onnx"),
            voices: path("voices.bin"),
            tokens: path("tokens.txt"),
            lexicon: "\(path("lexicon-us-en.txt")),\(path("lexicon-zh.txt"))",
            lang: "zh"
        )
        let model = sherpaOnnxOfflineTtsModelConfig(kokoro: kokoro, numThreads: 2, debug: 0)
        // dates, phone numbers and numbers are read out as Chinese words
        var config = sherpaOnnxOfflineTtsConfig(
            model: model,
            ruleFsts: ["date-zh.fst", "phone-zh.fst", "number-zh.fst"].map(path).joined(separator: ","),
            maxNumSentences: 1
        )
        let wrapper = SherpaOnnxOfflineTtsWrapper(config: &config)
        guard wrapper.tts != nil else { return nil }
        tts = wrapper
        return tts
    }
}

private final class ChunkSink {
    let rate: Double
    let fn: @Sendable ([Float], Double) -> Bool
    init(rate: Double, _ fn: @escaping @Sendable ([Float], Double) -> Bool) {
        self.rate = rate
        self.fn = fn
    }
}
