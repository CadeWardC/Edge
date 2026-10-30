import AVFoundation
import Foundation
import SherpaOnnx

struct TranscriptSegment: Codable, Equatable, Hashable {
    var start: Double
    var end: Double
    var text: String
}

/// Transcribes an audio or video file on device: AVFoundation decodes it to 16 kHz mono, Silero VAD cuts it into
/// stretches of speech, and NVIDIA Parakeet TDT 0.6B v3 (sherpa-onnx, int8) writes each one out with punctuation
/// and capitals. Parakeet handles English and 24 other European languages.
final class Transcriber {
    /// Holds encoder.int8.onnx, decoder.int8.onnx, joiner.int8.onnx, tokens.txt and silero_vad.onnx.
    static let files = ["encoder.int8.onnx", "decoder.int8.onnx", "joiner.int8.onnx", "tokens.txt", "silero_vad.onnx"]
    static let sampleRate = 16_000

    private let recognizer: SherpaOnnxOfflineRecognizer
    private let vadPath: String

    init(directory: URL, threads: Int = 4) throws {
        let path = { (name: String) in directory.appendingPathComponent(name).path }
        // the wrappers stop the app on a missing file, so check first
        guard Self.files.allSatisfy({ FileManager.default.fileExists(atPath: path($0)) }) else {
            throw EngineError.load("The speech recognition files are missing. Download them again.")
        }
        let transducer = sherpaOnnxOfflineTransducerModelConfig(
            encoder: path("encoder.int8.onnx"), decoder: path("decoder.int8.onnx"), joiner: path("joiner.int8.onnx"))
        let model = sherpaOnnxOfflineModelConfig(tokens: path("tokens.txt"), transducer: transducer,
                                                 numThreads: threads, modelType: "nemo_transducer")
        var config = sherpaOnnxOfflineRecognizerConfig(featConfig: sherpaOnnxFeatureConfig(sampleRate: Self.sampleRate, featureDim: 80),
                                                       modelConfig: model)
        recognizer = SherpaOnnxOfflineRecognizer(config: &config)
        vadPath = path("silero_vad.onnx")
    }

    /// The duration of a media file, in seconds (0 when it has no readable audio).
    static func duration(of url: URL) async -> Double {
        let asset = AVURLAsset(url: url)
        guard let d = try? await asset.load(.duration) else { return 0 }
        return d.seconds.isFinite ? d.seconds : 0
    }

    /// Transcribes `url`. `onSegment` gets each piece as soon as it is written, with the share of the file done.
    func transcribe(_ url: URL, from startSecond: Double = 0, isCancelled: @escaping () -> Bool,
                    onSegment: (TranscriptSegment?, Double) -> Void) async throws {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw EngineError.inference("This file has no audio track.") }
        let total = max(try await asset.load(.duration).seconds, 0.1)

        let reader = try AVAssetReader(asset: asset)
        if startSecond > 0 {
            reader.timeRange = CMTimeRange(start: CMTime(seconds: startSecond, preferredTimescale: 600), end: .positiveInfinity)
        }
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw EngineError.inference("This audio format cannot be read.") }
        reader.add(output)
        guard reader.startReading() else {
            throw EngineError.inference(reader.error?.localizedDescription ?? "This audio could not be read.")
        }

        // speech stretches of up to 25 s, split at pauses of half a second
        let silero = sherpaOnnxSileroVadModelConfig(model: vadPath, threshold: 0.45, minSilenceDuration: 0.5,
                                                    minSpeechDuration: 0.25, windowSize: 512, maxSpeechDuration: 25)
        var vadConfig = sherpaOnnxVadModelConfig(sileroVad: silero, sampleRate: Int32(Self.sampleRate), numThreads: 1)
        let vad = SherpaOnnxVoiceActivityDetectorWrapper(config: &vadConfig, buffer_size_in_seconds: 60)
        let offset = startSecond
        var pending: [Float] = []
        var readSeconds = startSecond

        func drain() {
            while !vad.isEmpty() {
                let segment = vad.front()
                let start = offset + Double(segment.start) / Double(Self.sampleRate)
                let samples = segment.samples
                vad.pop()
                let text = recognizer.decode(samples: samples, sampleRate: Self.sampleRate).text
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let end = start + Double(samples.count) / Double(Self.sampleRate)
                onSegment(text.isEmpty ? nil : TranscriptSegment(start: start, end: end, text: text), min(end / total, 1))
            }
        }

        while let buffer = output.copyNextSampleBuffer() {
            if isCancelled() {
                reader.cancelReading()
                throw CancellationError()
            }
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let bytes = CMBlockBufferGetDataLength(block)
            var chunk = [Float](repeating: 0, count: bytes / MemoryLayout<Float>.size)
            chunk.withUnsafeMutableBytes { raw in
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes, destination: raw.baseAddress!)
            }
            pending += chunk
            readSeconds += Double(chunk.count) / Double(Self.sampleRate)
            // the VAD works in windows of 512 samples
            let usable = pending.count - pending.count % 512
            if usable > 0 {
                vad.acceptWaveform(samples: Array(pending[..<usable]))
                pending.removeFirst(usable)
                drain()
            }
            onSegment(nil, min(readSeconds / total, 1))
        }
        if reader.status == .failed {
            throw EngineError.inference(reader.error?.localizedDescription ?? "Reading the audio failed.")
        }
        if !pending.isEmpty {
            vad.acceptWaveform(samples: pending + [Float](repeating: 0, count: 512 - pending.count % 512))
        }
        vad.flush()
        drain()
        onSegment(nil, 1)
    }
}
