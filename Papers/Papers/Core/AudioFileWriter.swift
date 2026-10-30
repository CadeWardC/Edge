import AVFoundation

/// Writes mono float samples into an AAC .m4a file.
final class AudioFileWriter {
    private var file: AVAudioFile?
    private let format: AVAudioFormat
    private(set) var frames: Int64 = 0

    var seconds: Double { Double(frames) / format.sampleRate }

    init(url: URL, sampleRate: Double) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        self.file = file
        format = file.processingFormat
    }

    func write(_ samples: [Float]) throws {
        guard let file, !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return }
        samples.withUnsafeBufferPointer { src in
            channel.update(from: src.baseAddress!, count: samples.count)
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        try file.write(from: buffer)
        frames += Int64(samples.count)
    }

    func writeSilence(seconds: Double) throws {
        try write([Float](repeating: 0, count: Int(seconds * format.sampleRate)))
    }

    /// Finishes the file (the encoder flushes when the file is released).
    func close() {
        file = nil
    }
}
