import Foundation
import UIKit

/// Text spoken in a cloned voice from the Speak tab, kept in Documents/Speech/<id>.m4a.
struct SpeechClip: Identifiable, Codable, Equatable {
    var id = UUID()
    var text: String
    var voiceName: String
    var model: VoiceModel
    var duration: Double
    var created = Date()
}

@MainActor
final class SpeechClips: ObservableObject {
    static let shared = SpeechClips()

    @Published private(set) var clips: [SpeechClip] = []
    @Published private(set) var isGenerating = false
    @Published private(set) var progress: Double = 0
    @Published var error: String?

    private var task: Task<Void, Never>?

    nonisolated static var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Speech", isDirectory: true)
    }
    nonisolated static func audioURL(_ id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).m4a") }
    private static var indexURL: URL { directory.appendingPathComponent("clips.json") }

    private init() {
        if let data = try? Data(contentsOf: Self.indexURL),
           let saved = try? JSONDecoder().decode([SpeechClip].self, from: data) {
            clips = saved.filter { FileManager.default.fileExists(atPath: Self.audioURL($0.id).path) }
        }
    }

    func generate(text: String, voice: Voice, model: VoiceModel, speed: Double) {
        guard !isGenerating else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isGenerating = true
        progress = 0
        error = nil
        UIApplication.shared.isIdleTimerDisabled = true
        BackgroundKeepAlive.shared.begin(title: "Speaking", subtitle: voice.name)
        task = Task {
            var clip = SpeechClip(text: trimmed, voiceName: voice.name, model: model, duration: 0)
            let url = Self.audioURL(clip.id)
            var ok = false
            do {
                let options = SpeechRenderer.Options(voice: voice, model: model, speed: speed, steps: AppSettings.steps(model))
                clip.duration = try await SpeechRenderer.render(trimmed, options: options, to: url) { value in
                    Task { @MainActor in
                        SpeechClips.shared.progress = value
                        BackgroundKeepAlive.shared.update(fraction: value, title: "Speaking", subtitle: voice.name)
                    }
                }
                clips.insert(clip, at: 0)
                save()
                ok = true
                Player.shared.play(.init(url: url, title: String(trimmed.prefix(60)), subtitle: voice.name))
            } catch is CancellationError {
                try? FileManager.default.removeItem(at: url)
            } catch {
                try? FileManager.default.removeItem(at: url)
                self.error = error.localizedDescription
            }
            BackgroundKeepAlive.shared.end(success: ok)
            UIApplication.shared.isIdleTimerDisabled = false
            isGenerating = false
            task = nil
        }
    }

    func cancel() {
        task?.cancel()
    }

    func delete(_ clip: SpeechClip) {
        Player.shared.stop(ifPlaying: Self.audioURL(clip.id))
        clips.removeAll { $0.id == clip.id }
        try? FileManager.default.removeItem(at: Self.audioURL(clip.id))
        save()
    }

    private func save() {
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(clips) {
            try? data.write(to: Self.indexURL, options: .atomic)
        }
    }
}
