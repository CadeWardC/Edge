import AVFoundation
import CoreMedia

/// Reading voice samples and writing generated speech.
enum AudioClip {
    /// The longest voice sample kept. Longer samples make cloning slower without making it closer.
    static let maxSampleSeconds = 15.0

    /// Any audio (or video) file as mono float samples at `sampleRate`.
    static func load(_ url: URL, sampleRate: Double = Double(VoiceEngine.sampleRate)) throws -> [Float] {
        do {
            let samples = try loadWithAudioFile(url, sampleRate: sampleRate)
            if !samples.isEmpty { return samples }
        } catch {
            // videos and some formats can't be opened as audio files; the asset reader decodes anything playable
        }
        return try loadWithAssetReader(url, sampleRate: sampleRate)
    }

    /// Decodes the first audio track of any media file AVFoundation can play (.m4a, .mp3, .mp4, .mov, ...).
    static func loadWithAssetReader(_ url: URL, sampleRate: Double) throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .audio).first else {
            throw AppError("This file has no sound that can be read.")
        }
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? AppError("This recording can't be read.")
        }
        var samples: [Float] = []
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            guard length > 0 else { continue }
            var chunk = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            let status = chunk.withUnsafeMutableBytes { raw in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: raw.count, destination: raw.baseAddress!)
            }
            if status == kCMBlockBufferNoErr { samples += chunk }
        }
        if reader.status == .failed {
            throw reader.error ?? AppError("This recording can't be read.")
        }
        guard !samples.isEmpty else { throw AppError("This recording is empty.") }
        return samples
    }

    private static func loadWithAudioFile(_ url: URL, sampleRate: Double) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let input = file.processingFormat
        guard let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: input, to: output) else {
            throw AppError("This audio format can't be read.")
        }
        let chunk: AVAudioFrameCount = 16_384
        var samples: [Float] = []
        samples.reserveCapacity(Int(Double(file.length) * sampleRate / input.sampleRate) + 1024)
        var finished = false
        while true {
            guard let out = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: chunk) else { break }
            var error: NSError?
            let status = converter.convert(to: out, error: &error) { _, inputStatus in
                if finished {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                guard let buffer = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: chunk) else {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    try file.read(into: buffer, frameCount: chunk)
                } catch {
                    finished = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                if buffer.frameLength == 0 {
                    finished = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                inputStatus.pointee = .haveData
                return buffer
            }
            if let error { throw error }
            if out.frameLength > 0, let data = out.floatChannelData?[0] {
                samples.append(contentsOf: UnsafeBufferPointer(start: data, count: Int(out.frameLength)))
            }
            if status == .endOfStream || status == .error || (out.frameLength == 0 && finished) { break }
        }
        return samples
    }

    /// A voice sample ready for cloning: silence trimmed from both ends, cut at a pause before
    /// `maxSampleSeconds`, and normalized.
    static func prepareSample(_ samples: [Float], sampleRate: Double = Double(VoiceEngine.sampleRate)) -> [Float] {
        let frame = Int(sampleRate * 0.02)
        guard samples.count > frame * 10 else { return samples }
        let energies: [Float] = stride(from: 0, to: samples.count - frame, by: frame).map { start in
            var sum: Float = 0
            for i in start..<(start + frame) { sum += samples[i] * samples[i] }
            return (sum / Float(frame)).squareRoot()
        }
        let peak = energies.max() ?? 0
        guard peak > 0 else { return samples }
        let threshold = peak * 0.06
        guard let first = energies.firstIndex(where: { $0 > threshold }),
              let last = energies.lastIndex(where: { $0 > threshold }) else { return samples }
        var start = max(0, first * frame - Int(sampleRate * 0.1))
        var end = min(samples.count, (last + 1) * frame + Int(sampleRate * 0.15))
        let maxCount = Int(maxSampleSeconds * sampleRate)
        if end - start > maxCount {
            // end at the quietest moment in the last few seconds before the limit, so a word isn't cut
            let limitFrame = (start + maxCount) / frame
            let searchFrom = max(first, limitFrame - Int(4 / 0.02))
            let searchTo = min(limitFrame, energies.count)
            if searchFrom < searchTo, let quiet = (searchFrom..<searchTo).min(by: { energies[$0] < energies[$1] }) {
                end = quiet * frame
            } else {
                end = start + maxCount
            }
        }
        start = min(start, end)
        var clip = Array(samples[start..<end])
        let maxAbs = clip.reduce(Float(0)) { max($0, abs($1)) }
        if maxAbs > 0 {
            let gain = min(0.9 / maxAbs, 8)
            for i in clip.indices { clip[i] *= gain }
        }
        return clip
    }

    /// Writes mono float samples as a 16-bit WAV file.
    static func writeWAV(_ samples: [Float], sampleRate: Double, to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: url)
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return }
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        try file.write(from: buffer)
    }

    static func duration(of url: URL) -> Double {
        guard let file = try? AVAudioFile(forReading: url) else { return 0 }
        return Double(file.length) / file.fileFormat.sampleRate
    }
}

/// Writes mono float samples into an AAC .m4a file as they are generated.
final class AudioFileWriter {
    private var file: AVAudioFile?
    private let format: AVAudioFormat
    private(set) var frames: Int64 = 0

    var seconds: Double { Double(frames) / format.sampleRate }

    init(url: URL, sampleRate: Double) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: url)
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
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
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
