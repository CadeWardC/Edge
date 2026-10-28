import AVFoundation

/// Microphone capture (resampled to the model's input rate) and streaming playback on one AVAudioEngine.
final class AudioIO: @unchecked Sendable {
    static let maxRecordingSeconds: Double = 30

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var playbackFormat: AVAudioFormat?

    private let lock = NSLock()
    private var recorded: [Float] = []
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private(set) var isRecording = false

    /// Scheduled but not yet played buffers; playback is finished when this hits zero.
    private var pendingBuffers = 0
    /// Bumped by stopPlayback() so completions of flushed buffers are ignored.
    private var playbackGeneration = 0
    private var onPlaybackDrained: (() -> Void)?

    init() {
        engine.attach(player)
    }

    static func requestMicrophone() async -> Bool {
        await withCheckedContinuation { cont in
            AVAudioApplication.requestRecordPermission { cont.resume(returning: $0) }
        }
    }

    private func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default,
                                options: [.defaultToSpeaker, .allowBluetoothA2DP, .allowBluetooth])
        try session.setActive(true)
    }

    private func ensurePlayerConnected(sampleRate: Double) {
        if let fmt = playbackFormat, fmt.sampleRate == sampleRate { return }
        let fmt = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        engine.disconnectNodeOutput(player)
        engine.connect(player, to: engine.mainMixerNode, format: fmt)
        playbackFormat = fmt
    }

    private func startEngineIfNeeded() throws {
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
    }

    // MARK: Recording

    func startRecording(sampleRate: Double) throws {
        try configureSession()
        stopPlayback()

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw LFMError.inference("No microphone input is available.")
        }
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        converter = AVAudioConverter(from: inputFormat, to: target)
        targetFormat = target

        lock.lock(); recorded.removeAll(keepingCapacity: true); lock.unlock()

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.append(buffer)
        }
        // the player needs a format before the engine starts
        ensurePlayerConnected(sampleRate: playbackFormat?.sampleRate ?? 24_000)
        try startEngineIfNeeded()
        isRecording = true
    }

    private func append(_ buffer: AVAudioPCMBuffer) {
        guard let converter, let targetFormat else { return }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let data = out.floatChannelData?[0], out.frameLength > 0 else { return }

        let maxSamples = Int(Self.maxRecordingSeconds * targetFormat.sampleRate)
        lock.lock()
        let room = max(0, maxSamples - recorded.count)
        recorded.append(contentsOf: UnsafeBufferPointer(start: data, count: min(room, Int(out.frameLength))))
        lock.unlock()
    }

    var recordedSeconds: Double {
        guard let targetFormat else { return 0 }
        lock.lock(); defer { lock.unlock() }
        return Double(recorded.count) / targetFormat.sampleRate
    }

    /// Stops the microphone and returns the recording at the requested sample rate.
    func stopRecording() -> [Float] {
        engine.inputNode.removeTap(onBus: 0)
        isRecording = false
        lock.lock(); defer { lock.unlock() }
        let samples = recorded
        recorded.removeAll()
        return samples
    }

    // MARK: Playback

    /// Queues a chunk of mono PCM; chunks play back to back as they arrive.
    func enqueue(_ samples: [Float], sampleRate: Double) {
        guard !samples.isEmpty else { return }
        do {
            try configureSession()
            ensurePlayerConnected(sampleRate: sampleRate)
            try startEngineIfNeeded()
        } catch {
            return
        }
        guard let fmt = playbackFormat,
              let buffer = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buffer.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }

        lock.lock()
        pendingBuffers += 1
        let generation = playbackGeneration
        lock.unlock()
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            self?.bufferFinished(generation: generation)
        }
        if !player.isPlaying {
            player.play()
        }
    }

    private func bufferFinished(generation: Int) {
        lock.lock()
        guard generation == playbackGeneration else {
            lock.unlock()
            return
        }
        pendingBuffers = max(0, pendingBuffers - 1)
        let done = pendingBuffers == 0 ? onPlaybackDrained : nil
        if done != nil { onPlaybackDrained = nil }
        lock.unlock()
        if let done { DispatchQueue.main.async(execute: done) }
    }

    /// Calls `completion` on the main queue once everything queued so far has played.
    func whenPlaybackDrained(_ completion: @escaping () -> Void) {
        lock.lock()
        if pendingBuffers == 0 {
            lock.unlock()
            DispatchQueue.main.async(execute: completion)
            return
        }
        onPlaybackDrained = completion
        lock.unlock()
    }

    func play(_ samples: [Float], sampleRate: Double) {
        stopPlayback()
        enqueue(samples, sampleRate: sampleRate)
    }

    func stopPlayback() {
        lock.lock()
        playbackGeneration += 1
        pendingBuffers = 0
        let done = onPlaybackDrained
        onPlaybackDrained = nil
        lock.unlock()
        player.stop()
        if let done { DispatchQueue.main.async(execute: done) }
    }
}
