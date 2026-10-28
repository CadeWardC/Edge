import AVFoundation

/// Microphone capture (resampled to the model's input rate) and streaming playback.
/// Recording and playback use separate engines: the mic engine only lives while recording,
/// so the playback engine never runs with an active input.
final class AudioIO: @unchecked Sendable {
    static let maxRecordingSeconds: Double = 30
    /// Audio queued before playback starts, so a slower-than-realtime voice does not stutter.
    static let prebufferSeconds: Double = 0.6

    private let lock = NSLock()

    // MARK: Recording state
    private var recordEngine: AVAudioEngine?
    private var recorded: [Float] = []
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private(set) var isRecording = false

    // MARK: Playback state (touched on playQueue only, except where locked)
    private let playQueue = DispatchQueue(label: "edge.audio.playback")
    private let playEngine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var playFormat: AVAudioFormat?
    private var streaming = false
    private var started = false
    private var waiting: [AVAudioPCMBuffer] = []   // queued before playback starts
    /// Bumped by stopPlayback() so completions of flushed buffers are ignored.
    private var generation = 0
    private var pendingSeconds: Double = 0          // scheduled and not yet played (locked)
    private var onDrained: (() -> Void)?            // locked

    init() {
        playEngine.attach(player)
        let center = NotificationCenter.default
        center.addObserver(forName: .AVAudioEngineConfigurationChange, object: playEngine, queue: nil) { [weak self] _ in
            self?.playQueue.async { self?.recoverPlayback() }
        }
        center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap { AVAudioSession.InterruptionType(rawValue: $0) }
            if type == .ended {
                self?.playQueue.async { self?.recoverPlayback() }
            }
        }
    }

    static func requestMicrophone() async -> Bool {
        await withCheckedContinuation { cont in
            AVAudioApplication.requestRecordPermission { cont.resume(returning: $0) }
        }
    }

    /// Sets up the shared audio session once; later calls only re-activate it.
    private static var sessionConfigured = false
    private static func activateSession() throws {
        let session = AVAudioSession.sharedInstance()
        if !sessionConfigured {
            try session.setCategory(.playAndRecord, mode: .default,
                                    options: [.defaultToSpeaker, .allowBluetoothA2DP, .allowBluetooth])
            sessionConfigured = true
        }
        try session.setActive(true)
    }

    // MARK: Recording

    func startRecording(sampleRate: Double) throws {
        stopPlayback()
        try Self.activateSession()

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw LFMError.inference("No microphone input is available.")
        }
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        converter = AVAudioConverter(from: inputFormat, to: target)
        targetFormat = target

        lock.lock(); recorded.removeAll(keepingCapacity: true); lock.unlock()

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.append(buffer)
        }
        engine.prepare()
        try engine.start()
        recordEngine = engine
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

    /// Stops and releases the microphone, returning the recording at the requested sample rate.
    func stopRecording() -> [Float] {
        if let engine = recordEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        recordEngine = nil
        isRecording = false
        lock.lock(); defer { lock.unlock() }
        let samples = recorded
        recorded.removeAll()
        return samples
    }

    // MARK: Playback

    /// Starts a stream of chunks; playback begins once `prebufferSeconds` are queued or the stream ends.
    func beginStream() {
        stopPlayback()
        playQueue.async {
            self.streaming = true
            self.started = false
            self.waiting.removeAll()
        }
    }

    /// Queues a chunk of mono PCM.
    func enqueue(_ samples: [Float], sampleRate: Double) {
        guard !samples.isEmpty else { return }
        playQueue.async {
            guard let buffer = self.makeBuffer(samples, sampleRate: sampleRate) else { return }
            if self.started || !self.streaming {
                self.schedule(buffer)
                self.startIfNeeded()
            } else {
                self.waiting.append(buffer)
                let queued = self.waiting.reduce(0) { $0 + Double($1.frameLength) / $1.format.sampleRate }
                if queued >= Self.prebufferSeconds {
                    self.startWaiting()
                }
            }
        }
    }

    /// Marks the end of the stream: whatever is still waiting starts playing.
    func endStream() {
        playQueue.async {
            self.streaming = false
            self.startWaiting()
        }
    }

    func play(_ samples: [Float], sampleRate: Double) {
        beginStream()
        enqueue(samples, sampleRate: sampleRate)
        endStream()
    }

    func stopPlayback() {
        lock.lock()
        let done = onDrained
        onDrained = nil
        pendingSeconds = 0
        lock.unlock()
        playQueue.async {
            self.generation += 1
            self.waiting.removeAll()
            self.started = false
            self.player.stop()
        }
        if let done { DispatchQueue.main.async(execute: done) }
    }

    /// Calls `completion` on the main queue once everything queued so far has played.
    /// A timer backs up the buffer completions, in case iOS stopped the audio engine.
    func whenPlaybackDrained(_ completion: @escaping () -> Void) {
        playQueue.async {
            self.lock.lock()
            let remaining = self.pendingSeconds + self.waiting.reduce(0) { $0 + Double($1.frameLength) / $1.format.sampleRate }
            guard remaining > 0 else {
                self.lock.unlock()
                DispatchQueue.main.async(execute: completion)
                return
            }
            var fired = false
            let once = { [weak self] in
                guard let self else { return }
                self.lock.lock()
                let run = !fired
                fired = true
                if self.onDrained != nil, run { self.onDrained = nil }
                self.lock.unlock()
                if run { DispatchQueue.main.async(execute: completion) }
            }
            self.onDrained = once
            self.lock.unlock()
            DispatchQueue.main.asyncAfter(deadline: .now() + remaining + 1.5) { once() }
        }
    }

    /// Writes mono PCM as a 16-bit WAV file.
    static func writeWAV(_ samples: [Float], sampleRate: Double, to url: URL) throws {
        var data = Data()
        func put<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let rate = UInt32(sampleRate)
        data.append(contentsOf: Array("RIFF".utf8)); put(UInt32(36 + samples.count * 2))
        data.append(contentsOf: Array("WAVEfmt ".utf8)); put(UInt32(16)); put(UInt16(1)); put(UInt16(1))
        put(rate); put(rate * 2); put(UInt16(2)); put(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); put(UInt32(samples.count * 2))
        for s in samples { put(Int16(max(-1, min(1, s)) * 32767)) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    // MARK: Playback internals (playQueue)

    private func makeBuffer(_ samples: [Float], sampleRate: Double) -> AVAudioPCMBuffer? {
        if playFormat?.sampleRate != sampleRate {
            let fmt = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
            let wasRunning = playEngine.isRunning
            if wasRunning { playEngine.stop() }
            playEngine.disconnectNodeOutput(player)
            playEngine.connect(player, to: playEngine.mainMixerNode, format: fmt)
            playFormat = fmt
        }
        guard let fmt = playFormat,
              let buffer = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(samples.count)) else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buffer.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        return buffer
    }

    private func startWaiting() {
        let buffers = waiting
        waiting.removeAll()
        for b in buffers { schedule(b) }
        if !buffers.isEmpty || started { startIfNeeded() }
    }

    private func schedule(_ buffer: AVAudioPCMBuffer) {
        let seconds = Double(buffer.frameLength) / buffer.format.sampleRate
        lock.lock(); pendingSeconds += seconds; lock.unlock()
        let gen = generation
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            guard let self else { return }
            self.playQueue.async {
                guard gen == self.generation else { return }
                self.lock.lock()
                self.pendingSeconds = max(0, self.pendingSeconds - seconds)
                let done = self.pendingSeconds < 0.001 && self.waiting.isEmpty && !self.streaming ? self.onDrained : nil
                self.lock.unlock()
                done?()
            }
        }
    }

    private func startIfNeeded() {
        do {
            try Self.activateSession()
            if !playEngine.isRunning {
                playEngine.prepare()
                try playEngine.start()
            }
            if !player.isPlaying { player.play() }
            started = true
        } catch {
            NSLog("Edge audio: could not start playback: \(error)")
        }
    }

    /// iOS stopped the engine (route change, interruption): restart it and keep playing what is queued.
    private func recoverPlayback() {
        guard started else { return }
        lock.lock(); let hasAudio = pendingSeconds > 0; lock.unlock()
        guard hasAudio else { return }
        if let fmt = playFormat {
            playEngine.disconnectNodeOutput(player)
            playEngine.connect(player, to: playEngine.mainMixerNode, format: fmt)
        }
        startIfNeeded()
    }
}
