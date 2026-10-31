import AVFoundation
import Foundation
import Speech

/// A cloned voice: a short sample of someone speaking, and what they say in it.
struct Voice: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    /// The exact words of the sample. ZipVoice (Best) needs it to clone well.
    var transcript: String
    /// Language of the sample, for transcribing it ("en-US", "zh-CN", ...).
    var language: String
    var duration: Double
    var created = Date()
}

/// The saved voices, with their samples in Documents/Voices/<id>.wav (mono, 24 kHz).
@MainActor
final class VoiceLibrary: ObservableObject {
    static let shared = VoiceLibrary()
    static let languages: [(code: String, name: String)] = [
        ("en-US", "English (US)"), ("en-GB", "English (UK)"), ("zh-CN", "Chinese (Mandarin)"),
    ]

    @Published private(set) var voices: [Voice] = []

    private var cache: [UUID: [Float]] = [:]

    nonisolated static var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Voices", isDirectory: true)
    }
    nonisolated static func sampleURL(_ id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).wav") }
    private static var indexURL: URL { directory.appendingPathComponent("voices.json") }

    private init() {
        if let data = try? Data(contentsOf: Self.indexURL),
           let saved = try? JSONDecoder().decode([Voice].self, from: data) {
            voices = saved.filter { FileManager.default.fileExists(atPath: Self.sampleURL($0.id).path) }
        }
    }

    func voice(_ id: UUID?) -> Voice? {
        guard let id else { return nil }
        return voices.first { $0.id == id }
    }

    /// Adds a voice from an audio file (imported or recorded): trims and saves the sample, then transcribes it.
    func add(from url: URL, name: String, language: String) async throws -> Voice {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let samples = try await Task.detached(priority: .userInitiated) {
            AudioClip.prepareSample(try AudioClip.load(url))
        }.value
        guard Double(samples.count) / Double(VoiceEngine.sampleRate) >= 2 else {
            throw AppError("The sample is too short. Use at least 3 seconds of clear speech (5 to 15 is best).")
        }
        var voice = Voice(name: name.isEmpty ? "Voice \(voices.count + 1)" : name, transcript: "",
                          language: language, duration: Double(samples.count) / Double(VoiceEngine.sampleRate))
        try AudioClip.writeWAV(samples, sampleRate: Double(VoiceEngine.sampleRate), to: Self.sampleURL(voice.id))
        voice.transcript = (try? await Transcriber.transcribe(Self.sampleURL(voice.id), language: language)) ?? ""
        voices.insert(voice, at: 0)
        cache[voice.id] = samples
        save()
        return voice
    }

    func update(_ voice: Voice) {
        guard let i = voices.firstIndex(where: { $0.id == voice.id }) else { return }
        voices[i] = voice
        save()
    }

    func delete(_ voice: Voice) {
        voices.removeAll { $0.id == voice.id }
        cache[voice.id] = nil
        try? FileManager.default.removeItem(at: Self.sampleURL(voice.id))
        save()
    }

    /// Transcribes the sample again (e.g. after changing its language).
    func retranscribe(_ voice: Voice) async throws -> String {
        let text = try await Transcriber.transcribe(Self.sampleURL(voice.id), language: voice.language)
        var v = voice
        v.transcript = text
        update(v)
        return text
    }

    func samples(for voice: Voice) throws -> [Float] {
        if let s = cache[voice.id] { return s }
        let s = try AudioClip.load(Self.sampleURL(voice.id))
        cache[voice.id] = s
        return s
    }

    private func save() {
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(voices) {
            try? data.write(to: Self.indexURL, options: .atomic)
        }
    }
}

/// Writes down what is said in a voice sample, with Apple's speech recognizer (on device when the phone supports it).
enum Transcriber {
    static func transcribe(_ url: URL, language: String) async throws -> String {
        let status = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
        }
        guard status == .authorized else {
            throw AppError("Speech recognition is off for Edge. Type the transcript, or allow it in Settings › Privacy.")
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language)), recognizer.isAvailable else {
            throw AppError("Speech recognition isn't available for this language right now. Type the transcript instead.")
        }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        request.addsPunctuation = true
        return try await withCheckedThrowingContinuation { cont in
            var done = false
            recognizer.recognitionTask(with: request) { result, error in
                guard !done else { return }
                if let error {
                    done = true
                    cont.resume(throwing: error)
                } else if let result, result.isFinal {
                    done = true
                    cont.resume(returning: result.bestTranscription.formattedString)
                }
            }
        }
    }
}

/// Records a voice sample from the microphone into a temporary .m4a.
@MainActor
final class SampleRecorder: NSObject, ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var seconds: Double = 0
    @Published private(set) var level: Float = 0

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("voice-sample.m4a")

    func start() async throws {
        let granted = await AVAudioApplication.requestRecordPermission()
        guard granted else { throw AppError("Microphone access is off. Allow it in Settings › Privacy › Microphone.") }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        try session.setActive(true)
        try? FileManager.default.removeItem(at: url)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.max.rawValue,
        ]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.isMeteringEnabled = true
        guard recorder.record() else { throw AppError("Recording could not start.") }
        self.recorder = recorder
        isRecording = true
        seconds = 0
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            Task { @MainActor in self.tick() }
        }
    }

    /// Stops and returns the recording.
    @discardableResult
    func stop() -> URL? {
        timer?.invalidate()
        timer = nil
        recorder?.stop()
        recorder = nil
        isRecording = false
        level = 0
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func tick() {
        guard let recorder else { return }
        recorder.updateMeters()
        seconds = recorder.currentTime
        level = max(0, min(1, (recorder.averagePower(forChannel: 0) + 50) / 50))
        if seconds >= 30 { stop() }
    }
}
