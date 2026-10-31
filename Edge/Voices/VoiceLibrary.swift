import AVFoundation
import Foundation
import Speech

/// A voice to speak with: a clone made from a short sample of someone speaking, or one of Kokoro's built-in voices.
struct Voice: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    /// The exact words of the sample. ZipVoice (Best) needs it to clone well.
    var transcript: String
    /// Accent of the sample, for transcribing it ("en-US", "en-GB").
    var language: String
    var duration: Double
    var created = Date()
    /// Kokoro's speaker id when this is a built-in voice (no sample).
    var builtInID: Int?
    /// e.g. "American woman"
    var builtInDescription: String?

    var isBuiltIn: Bool { builtInID != nil }

    /// Kokoro v1.0's English voices (speaker ids 0-27), best rated first.
    static let builtIn: [Voice] = {
        let list: [(Int, String, String)] = [
            (3, "Heart", "American woman"), (2, "Bella", "American woman"), (6, "Nicole", "American woman, soft"),
            (16, "Michael", "American man"), (14, "Fenrir", "American man"), (18, "Puck", "American man"),
            (21, "Emma", "British woman"), (26, "George", "British man"), (25, "Fable", "British man"),
            (5, "Kore", "American woman"), (0, "Alloy", "American woman"), (1, "Aoede", "American woman"),
            (4, "Jessica", "American woman"), (7, "Nova", "American woman"), (8, "River", "American woman"),
            (9, "Sarah", "American woman"), (10, "Sky", "American woman"), (11, "Adam", "American man"),
            (12, "Echo", "American man"), (13, "Eric", "American man"), (15, "Liam", "American man"),
            (17, "Onyx", "American man"), (20, "Alice", "British woman"), (22, "Isabella", "British woman"),
            (23, "Lily", "British woman"), (24, "Daniel", "British man"), (27, "Lewis", "British man"),
        ]
        return list.map { sid, name, description in
            Voice(id: UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", sid))!, name: name, transcript: "",
                  language: description.hasPrefix("British") ? "en-GB" : "en-US", duration: 0,
                  created: Date(timeIntervalSince1970: 0), builtInID: sid, builtInDescription: description)
        }
    }()

    /// The built-in voice used until another is chosen.
    static var defaultVoice: Voice { builtIn[0] }
}

/// The saved voices, with their samples in Documents/Voices/<id>.wav (mono, 24 kHz).
@MainActor
final class VoiceLibrary: ObservableObject {
    static let shared = VoiceLibrary()
    static let languages: [(code: String, name: String)] = [
        ("en-US", "English (US)"), ("en-GB", "English (UK)"),
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

    /// A cloned or built-in voice by id.
    func voice(_ id: UUID?) -> Voice? {
        guard let id else { return nil }
        return voices.first { $0.id == id } ?? Voice.builtIn.first { $0.id == id }
    }

    /// The cloned voices first, then the built-in ones.
    var allVoices: [Voice] { voices + Voice.builtIn }

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
        if voice.isBuiltIn { return [] }
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
