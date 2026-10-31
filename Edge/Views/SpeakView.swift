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

    private var voice: Voice { voices.voice(UUID(uuidString: voiceID)) ?? Voice.defaultVoice }
    /// The cloning model picked for cloned voices.
    private var model: VoiceModel { VoiceModel.cloning.first { $0.rawValue == modelRaw } ?? .fast }
    /// The model that will actually speak.
    private var speakingModel: VoiceModel { voice.isBuiltIn ? .kokoro : model }

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
                    VoicePicker(selection: Binding(get: { voice.id }, set: { voiceID = $0.uuidString }))
                    if !voice.isBuiltIn {
                        Picker("Cloning model", selection: $modelRaw) {
                            ForEach(VoiceModel.cloning) { m in Text(m.title).tag(m.rawValue) }
                        }
                        .pickerStyle(.segmented)
                    }
                    HStack {
                        Image(systemName: "tortoise").font(.caption)
                        Slider(value: $speed, in: 0.7...1.4, step: 0.05)
                        Image(systemName: "hare").font(.caption)
                        Text(String(format: "%.2g×", speed)).font(.caption.monospacedDigit()).frame(width: 40)
                    }
                    if !models.isReady(speakingModel) {
                        Label("The \(speakingModel.modelName) model isn't downloaded. Get it in Settings.", systemImage: "arrow.down.circle")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                } footer: {
                    Text(speakingModel.detail)
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
                            clips.generate(text: text, voice: voice, model: model, speed: speed)
                        } label: {
                            Label("Speak", systemImage: "play.fill").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!models.isReady(speakingModel) || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
                Text("\(clip.voiceName) · \(clip.model == .kokoro ? "Built-in" : clip.model.title) · \(formatDuration(clip.duration))")
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
