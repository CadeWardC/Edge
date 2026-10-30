import Foundation
import SherpaOnnx

/// Mandarin speech recognition with SenseVoice-Small (sherpa-onnx, int8 ONNX, CPU).
/// Loaded on first use and kept until `unload()`; every call runs on a private serial queue.
final class SenseVoiceRecognizer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "edge.sensevoice", qos: .userInitiated)
    private var recognizer: SherpaOnnxOfflineRecognizer?

    /// Text of the recording, or nil when the model files are missing.
    func transcribe(_ samples: [Float], sampleRate: Double) async -> String? {
        await withCheckedContinuation { cont in
            queue.async {
                guard let recognizer = self.loadIfNeeded() else {
                    cont.resume(returning: nil)
                    return
                }
                let result = recognizer.decode(samples: samples, sampleRate: Int(sampleRate))
                cont.resume(returning: result.text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
    }

    func unload() {
        queue.async { self.recognizer = nil }
    }

    private func loadIfNeeded() -> SherpaOnnxOfflineRecognizer? {
        if let recognizer { return recognizer }
        let model = ModelStore.senseVoiceModelURL.path
        let tokens = ModelStore.senseVoiceTokensURL.path
        // the wrapper stops the app on a missing file, so check first
        guard FileManager.default.fileExists(atPath: model), FileManager.default.fileExists(atPath: tokens) else {
            return nil
        }
        let senseVoice = sherpaOnnxOfflineSenseVoiceModelConfig(
            model: model,
            language: "zh",
            useInverseTextNormalization: true   // digits and punctuation
        )
        let modelConfig = sherpaOnnxOfflineModelConfig(tokens: tokens, numThreads: 2, debug: 0, senseVoice: senseVoice)
        let featConfig = sherpaOnnxFeatureConfig(sampleRate: 16_000, featureDim: 80)
        var config = sherpaOnnxOfflineRecognizerConfig(featConfig: featConfig, modelConfig: modelConfig)
        recognizer = SherpaOnnxOfflineRecognizer(config: &config)
        return recognizer
    }
}
