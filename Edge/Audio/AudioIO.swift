import Accelerate
import AVFoundation

/// Microphone capture (resampled to the model's input rate) and streaming playback.
/// Recording and playback use separate engines: the mic engine only lives while recording,
/// so the playback engine never runs with an active input.
final class AudioIO: @unchecked Sendable {
    static let maxRecordingSeconds: Double = 30
    /// Least audio queued before playback starts; more when the voice is generated slower than real time.
    static let prebufferSeconds: Double = 0.4

    private let lock = NSLock()

    // MARK: Recording state
    private var recordEngine: AVAudioEngine?
    private var recorded: [Float] = []
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private(set) var isRecording = false

    /// Voice activity of the current recording, read by the session to send when the learner pauses.
    struct VoiceActivity {
        var speechDetected = false
        var speechSeconds: Double = 0
        var silenceSeconds: Double = 0
        var level: Double = 0          // 0...1 for the mic meter
    }
    private var activity = VoiceActivity()
    private var noiseFloorDB: Double?
    private var speechSeconds: Double = 0
    private var lastSpeechSample = 0
    private var listenedSeconds: Double = 0
    /// The first moments only teach the detector the room's noise (and any tail of the tutor's voice).
    static let calibrationSeconds: Double = 0.3
    /// Speech needed before the pause timer is armed, so a click or cough does not start it.
    static let minSpeechSeconds: Double = 0.35

    // MARK: Playback state (touched on playQueue only, except where locked)
    private let playQueue = DispatchQueue(label: "edge.audio.playback")
    private let playEngine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    /// Slows the voice down without lowering it.
    private let timePitch = AVAudioUnitTimePitch()
    private var playbackRate: Double = 1
    private var playFormat: AVAudioFormat?
    private var streaming = false
    // generation speed of the current stream, to decide how much to buffer
    private var expectedSeconds: Double = 0
    private var firstChunkAt: Date?
    private var producedSeconds: Double = 0
    private var producedAfterFirst: Double = 0
    private var started = false
    private var waiting: [AVAudioPCMBuffer] = []   // queued before playback starts
    /// Bumped by stopPlayback() so completions of flushed buffers are ignored.
    private var generation = 0
    private var pendingSeconds: Double = 0          // scheduled and not yet played (locked)
    private var onDrained: (() -> Void)?            // locked

    init() {
        playEngine.attach(player)
        playEngine.attach(timePitch)
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

        lock.lock()
        recorded.removeAll(keepingCapacity: true)
        activity = VoiceActivity()
        noiseFloorDB = nil
        speechSeconds = 0
        listenedSeconds = 0
        lastSpeechSample = 0
        lock.unlock()

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
        let chunk = UnsafeBufferPointer(start: data, count: Int(out.frameLength))
        lock.lock()
        let room = max(0, maxSamples - recorded.count)
        recorded.append(contentsOf: chunk.prefix(room))
        updateActivity(chunk, sampleRate: targetFormat.sampleRate)
        lock.unlock()
    }

    /// Speech is anything 12 dB above an adaptive noise floor; the floor follows quieter audio
    /// at once and louder audio slowly, so a steady background hum is learned. Called under `lock`.
    private func updateActivity(_ x: UnsafeBufferPointer<Float>, sampleRate: Double) {
        guard !x.isEmpty else { return }
        var meanSquare: Float = 0
        vDSP_measqv(x.baseAddress!, 1, &meanSquare, vDSP_Length(x.count))
        let db = 10 * log10(Double(meanSquare) + 1e-12)
        let dt = Double(x.count) / sampleRate

        activity.level = min(1, max(0, (db + 60) / 45))
        listenedSeconds += dt
        let floor = noiseFloorDB ?? min(db, -45)
        if listenedSeconds <= Self.calibrationSeconds {
            noiseFloorDB = min(floor, db)
            return
        }
        if db > max(floor + 12, -55) {
            speechSeconds += dt
            activity.speechSeconds = speechSeconds
            activity.silenceSeconds = 0
            if speechSeconds >= Self.minSpeechSeconds { activity.speechDetected = true }
            lastSpeechSample = recorded.count
            noiseFloorDB = floor
        } else {
            activity.silenceSeconds += dt
            noiseFloorDB = db < floor ? db : floor + min(db - floor, 3 * dt)
        }
    }

    var voiceActivity: VoiceActivity {
        lock.lock(); defer { lock.unlock() }
        return activity
    }

    var recordedSeconds: Double {
        guard let targetFormat else { return 0 }
        lock.lock(); defer { lock.unlock() }
        return Double(recorded.count) / targetFormat.sampleRate
    }

    /// Stops and releases the microphone, returning the recording at the requested sample rate.
    /// With `trimSilence`, the silence after the last speech is cut down to a short tail.
    func stopRecording(trimSilence: Bool = false) -> [Float] {
        if let engine = recordEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        recordEngine = nil
        isRecording = false
        lock.lock(); defer { lock.unlock() }
        var samples = recorded
        recorded.removeAll()
        if trimSilence, activity.speechDetected, let rate = targetFormat?.sampleRate {
            let keep = min(samples.count, lastSpeechSample + Int(rate * 0.35))
            samples.removeSubrange(keep...)
        }
        return samples
    }

    // MARK: Playback

    /// Starts a stream of chunks. `expectedSeconds` is a guess of the whole stream's length (0 if unknown):
    /// playback starts once enough is buffered that generation stays ahead of it, or when the stream ends.
    func beginStream(expectedSeconds: Double = 0) {
        stopPlayback()
        playQueue.async {
            self.streaming = true
            self.started = false
            self.waiting.removeAll()
            self.expectedSeconds = expectedSeconds
            self.firstChunkAt = nil
            self.producedSeconds = 0
            self.producedAfterFirst = 0
        }
    }

    /// Playback speed, 0.5...1 (1 = as generated). The pitch stays the same.
    func setPlaybackRate(_ rate: Double) {
        playQueue.async {
            self.playbackRate = min(1, max(0.5, rate))
            self.timePitch.rate = Float(self.playbackRate)
        }
    }

    /// Queues a chunk of mono PCM.
    func enqueue(_ samples: [Float], sampleRate: Double) {
        guard !samples.isEmpty else { return }
        playQueue.async {
            guard let buffer = self.makeBuffer(samples, sampleRate: sampleRate) else { return }
            let seconds = Double(buffer.frameLength) / sampleRate
            if self.firstChunkAt == nil {
                self.firstChunkAt = Date()
            } else {
                self.producedAfterFirst += seconds
            }
            self.producedSeconds += seconds

            if self.started || !self.streaming {
                self.schedule(buffer)
                self.startIfNeeded()
            } else {
                self.waiting.append(buffer)
                if self.enoughBuffered() {
                    self.startWaiting()
                }
            }
        }
    }

    /// Whether playback can (re)start without running out before generation catches up.
    private func enoughBuffered() -> Bool {
        lock.lock(); let scheduled = pendingSeconds; lock.unlock()
        let buffered = scheduled + waiting.reduce(0) { $0 + Double($1.frameLength) / $1.format.sampleRate }
        guard buffered >= Self.prebufferSeconds, let first = firstChunkAt else { return false }

        let elapsed = Date().timeIntervalSince(first)
        guard elapsed >= 0.5 else { return buffered >= 3 }      // no speed measured yet
        let rate = producedAfterFirst / elapsed                 // audio seconds per second
        if rate >= 1.15 * playbackRate { return true }          // comfortably faster than it is played
        guard rate > 0.05 else { return buffered >= 3 }

        // remaining audio takes remaining/rate to generate, and (buffered+remaining)/playbackRate to play
        let remaining = expectedSeconds > 0 ? max(expectedSeconds - producedSeconds, 0) : 4
        let needed = playbackRate * (remaining / rate + 0.4) - remaining
        return buffered >= needed
    }

    /// Marks the end of the stream: whatever is still waiting starts playing, followed by a short
    /// silent tail so the last syllable is fully out of the speaker before playback counts as done.
    func endStream() {
        playQueue.async {
            if let fmt = self.playFormat, self.producedSeconds > 0,
               let tail = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(fmt.sampleRate * 0.25)) {
                tail.frameLength = tail.frameCapacity   // zero-filled
                if self.started { self.schedule(tail) } else { self.waiting.append(tail) }
            }
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
            guard remaining > 0.05 else {
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
                // the hardware still has its output latency worth of audio to play
                let latency = AVAudioSession.sharedInstance().outputLatency
                if run { DispatchQueue.main.asyncAfter(deadline: .now() + latency + 0.05, execute: completion) }
            }
            self.onDrained = once
            self.lock.unlock()
            DispatchQueue.main.asyncAfter(deadline: .now() + remaining / self.playbackRate + 1.5) { once() }
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
            connectGraph(fmt)
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
                let empty = self.pendingSeconds < 0.03
                let done = empty && self.waiting.isEmpty && !self.streaming ? self.onDrained : nil
                self.lock.unlock()
                if empty && self.streaming && self.started {
                    // ran dry while the voice is still being generated: pause and buffer again instead of stuttering
                    self.player.pause()
                    self.started = false
                }
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
            connectGraph(fmt)
        }
        startIfNeeded()
    }

    private func connectGraph(_ fmt: AVAudioFormat) {
        playEngine.disconnectNodeOutput(player)
        playEngine.disconnectNodeOutput(timePitch)
        playEngine.connect(player, to: timePitch, format: fmt)
        playEngine.connect(timePitch, to: playEngine.mainMixerNode, format: fmt)
    }
}
