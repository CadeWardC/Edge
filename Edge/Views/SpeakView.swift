import SwiftUI

struct SpeakView: View {
    @EnvironmentObject private var voices: VoiceLibrary
    @EnvironmentObject private var clips: SpeechClips
    @EnvironmentObject private var models: ModelStore
    @EnvironmentObject private var player: Player
    @AppStorage("speakText") private var text = ""
    @AppStorage("speakVoice") private var voiceID = ""
    @AppStorage(AppSettings.Key.voiceModel) private var modelRaw = VoiceModel.fast.rawValue
    @AppStorage(AppSettings.Key.speed) private var speed = 1.0
    @FocusState private var editing: Bool

    private var voice: Voice? { voices.voice(UUID(uuidString: voiceID)) ?? voices.voices.first }
    private var model: VoiceModel { VoiceModel(rawValue: modelRaw) ?? .fast }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $text)
                        .frame(minHeight: 160)
                        .focused($editing)
                        .overlay(alignment: .topLeading) {
                            if text.isEmpty {
                                Text("Type anything for the voice to say…")
                                    .foregroundStyle(.tertiary)
                                    .padding(.top, 8).padding(.leading, 5)
                                    .allowsHitTesting(false)
                            }
                        }
                }

                Section {
                    if voices.voices.isEmpty {
                        Text("Add a voice in the Voices tab first.").foregroundStyle(.secondary)
                    } else {
                        Picker("Voice", selection: Binding(get: { voice?.id.uuidString ?? "" }, set: { voiceID = $0 })) {
                            ForEach(voices.voices) { v in Text(v.name).tag(v.id.uuidString) }
                        }
                    }
                    Picker("Model", selection: $modelRaw) {
                        ForEach(VoiceModel.allCases) { m in Text(m.title).tag(m.rawValue) }
                    }
                    .pickerStyle(.segmented)
                    HStack {
                        Image(systemName: "tortoise").font(.caption)
                        Slider(value: $speed, in: 0.7...1.4, step: 0.05)
                        Image(systemName: "hare").font(.caption)
                        Text(String(format: "%.2g×", speed)).font(.caption.monospacedDigit()).frame(width: 40)
                    }
                    if !models.isReady(model) {
                        Label("The \(model.title) model (\(model.modelName)) isn't downloaded. Get it in Settings.", systemImage: "arrow.down.circle")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                } footer: {
                    Text(model.detail)
                }

                Section {
                    if clips.isGenerating {
                        VStack(alignment: .leading, spacing: 6) {
                            ProgressView(value: clips.progress)
                            Text("Speaking… \(Int(clips.progress * 100))%").font(.caption).foregroundStyle(.secondary)
                        }
                        Button("Stop", role: .destructive) { clips.cancel() }
                    } else {
                        Button {
                            editing = false
                            if let voice { clips.generate(text: text, voice: voice, model: model, speed: speed) }
                        } label: {
                            Label("Speak", systemImage: "play.fill").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(voice == nil || !models.isReady(model) || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    if let error = clips.error {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                }

                if !clips.clips.isEmpty {
                    Section("Recent") {
                        ForEach(clips.clips) { clip in
                            ClipRow(clip: clip)
                        }
                        .onDelete { offsets in
                            for i in offsets { clips.delete(clips.clips[i]) }
                        }
                    }
                }
            }
            .navigationTitle("Speak")
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { editing = false }
                }
            }
        }
    }
}

private struct ClipRow: View {
    let clip: SpeechClip
    @EnvironmentObject private var player: Player
    @AppStorage("speakText") private var text = ""

    private var url: URL { SpeechClips.audioURL(clip.id) }

    var body: some View {
        HStack(spacing: 12) {
            Button {
                if player.isCurrent(url) { player.toggle() } else {
                    player.play(.init(url: url, title: String(clip.text.prefix(60)), subtitle: clip.voiceName))
                }
            } label: {
                Image(systemName: player.isCurrent(url) && player.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.title2)
            }
            .buttonStyle(.borderless)
            VStack(alignment: .leading, spacing: 2) {
                Text(clip.text).lineLimit(2).font(.subheadline)
                Text("\(clip.voiceName) · \(clip.model.title) · \(formatDuration(clip.duration))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Menu {
                ShareLink(item: url) { Label("Share audio", systemImage: "square.and.arrow.up") }
                Button { text = clip.text } label: { Label("Edit this text", systemImage: "pencil") }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }
}
