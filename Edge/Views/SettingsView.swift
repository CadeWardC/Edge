import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var models: ModelStore
    @EnvironmentObject private var tutor: TutorSession
    @Environment(\.dismiss) private var dismiss

    @AppStorage("voice") private var voice = Voice.female.rawValue
    @AppStorage("level") private var level = LearnerLevel.beginner.rawValue
    @AppStorage("speakReplies") private var speakReplies = true
    @AppStorage("showPinyin") private var showPinyin = true
    @AppStorage("showEnglish") private var showEnglish = true
    @AppStorage("checkTones") private var checkTones = true
    @AppStorage("hfRepo") private var hfRepo = ""
    @AppStorage("autoSend") private var autoSend = true
    @AppStorage("pauseSeconds") private var pauseSeconds = 1.6
    @AppStorage("handsFree") private var handsFree = false
    @AppStorage("speechOnCPU") private var speechOnCPU = false
    @AppStorage("speechRate") private var speechRate = 1.0
    @AppStorage("asrEngine") private var asrEngine = "sensevoice"
    @AppStorage("replyEngine") private var replyEngine = "qwen"
    @AppStorage("ttsEngine") private var ttsEngine = "kokoro"
    @State private var reloading = false

    @State private var confirmDelete = false

    private var lfmChosen: Bool { asrEngine == "lfm" || replyEngine == "lfm" || ttsEngine == "lfm" }

    /// A download button, or the progress of the download that is running (one download fetches everything missing).
    @ViewBuilder private func downloadRow(_ title: String) -> some View {
        switch models.phase {
        case .idle, .failed:
            Button(title) { Task { await models.download() } }
            if case .failed(let msg) = models.phase {
                Text(msg).font(.footnote).foregroundStyle(.red)
            }
        case .resolving:
            ProgressView("Looking up files…")
        case .downloading:
            ProgressView(value: models.progress) {
                Text("\(Int(models.progress * 100))% · keeps going in the background").font(.caption)
            }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Replies by", selection: $replyEngine) {
                        Text("Qwen3.5").tag("qwen")
                        Text("LFM3-Audio").tag("lfm")
                    }
                    if replyEngine == "qwen" && models.chatModelURL == nil {
                        switch models.phase {
                        case .idle, .failed:
                            Button("Download Qwen3.5 (about 1.3 GB)") { Task { await models.download() } }
                            if case .failed(let msg) = models.phase {
                                Text(msg).font(.footnote).foregroundStyle(.red)
                            }
                        case .resolving:
                            ProgressView("Looking up files…")
                        case .downloading:
                            ProgressView(value: models.progress) {
                                Text("\(Int(models.progress * 100))% · keeps going in the background").font(.caption)
                            }
                        }
                    }
                    if replyEngine == "qwen", let err = tutor.chatModelError {
                        Text(err).font(.footnote).foregroundStyle(.red)
                    }
                } header: {
                    Text("Replies")
                } footer: {
                    Text(replyEngine == "qwen"
                         ? (models.chatModelURL != nil
                            ? "Qwen3.5 writes the replies, corrections and translations."
                            : "Until Qwen3.5 is downloaded, LFM3-Audio writes the replies.")
                         : "LFM3-Audio writes the replies.")
                }
                Section {
                    Picker("Speak with", selection: $ttsEngine) {
                        Text("Kokoro").tag("kokoro")
                        Text("LFM3-Audio").tag("lfm")
                    }
                    if ttsEngine == "kokoro" && !models.kokoroReady {
                        downloadRow("Download Kokoro (180 MB)")
                    }
                } header: {
                    Text("Speaking")
                } footer: {
                    Text(ttsEngine == "kokoro"
                         ? (models.kokoroReady
                            ? "Kokoro is a small, clear Mandarin voice. With SenseVoice, Qwen3.5 and Kokoro, LFM3-Audio isn't loaded at all, which saves about 2 GB of memory."
                            : "Until Kokoro is downloaded, LFM3-Audio speaks the replies.")
                         : "LFM3-Audio speaks the replies with its own voice.")
                }
                Section("Tutor") {
                    Picker("Level", selection: $level) {
                        ForEach(LearnerLevel.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    Picker("Voice", selection: $voice) {
                        ForEach(Voice.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    Toggle("Speak replies aloud", isOn: $speakReplies)
                    if speakReplies {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Speech speed")
                                Spacer()
                                Text(speechRate >= 0.999 ? "Normal" : String(format: "%.2g×", speechRate))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            Slider(value: $speechRate, in: 0.5...1.0, step: 0.05) {
                                Text("Speech speed")
                            } minimumValueLabel: {
                                Image(systemName: "tortoise").font(.caption)
                            } maximumValueLabel: {
                                Image(systemName: "hare").font(.caption)
                            }
                        }
                    }
                }
                Section {
                    Toggle("Send when I stop talking", isOn: $autoSend)
                    if autoSend {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Wait after I stop talking")
                                Spacer()
                                Text(String(format: "%.1f s", pauseSeconds))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            Slider(value: $pauseSeconds, in: 0.5...4.0, step: 0.1) {
                                Text("Wait after I stop talking")
                            } minimumValueLabel: {
                                Image(systemName: "hare").font(.caption)
                            } maximumValueLabel: {
                                Image(systemName: "tortoise").font(.caption)
                            }
                        }
                        Toggle("Hands-free conversation", isOn: $handsFree)
                    }
                } header: {
                    Text("Voice")
                } footer: {
                    Text(autoSend
                         ? "Tap the mic once and speak; once you have started talking, your turn is sent when you have been quiet this long. Raise it if it cuts you off while you think. Hands-free opens the mic again after each reply and waits for you to speak. Tap ✕ to stop."
                         : "Tap the mic to start, and again to send.")
                }
                Section {
                    Picker("Hear me with", selection: $asrEngine) {
                        Text("SenseVoice").tag("sensevoice")
                        Text("LFM3-Audio").tag("lfm")
                    }
                    if asrEngine == "sensevoice" && !models.senseVoiceReady {
                        switch models.phase {
                        case .idle, .failed:
                            Button("Download SenseVoice (230 MB)") { Task { await models.download() } }
                            if case .failed(let msg) = models.phase {
                                Text(msg).font(.footnote).foregroundStyle(.red)
                            }
                        case .resolving:
                            ProgressView("Looking up files…")
                        case .downloading:
                            ProgressView(value: models.progress) {
                                Text("\(Int(models.progress * 100))% · keeps going in the background").font(.caption)
                            }
                        }
                    }
                } header: {
                    Text("Speech recognition")
                } footer: {
                    Text(asrEngine == "sensevoice"
                         ? (models.senseVoiceReady
                            ? "SenseVoice is a small model made for Mandarin; it usually hears learners better."
                            : "Until SenseVoice is downloaded, LFM3-Audio hears you.")
                         : "LFM3-Audio hears you as well as replying.")
                }
                Section {
                    Toggle("Show pinyin", isOn: $showPinyin)
                    Toggle("Show English translation", isOn: $showEnglish)
                    Toggle("Check my tones", isOn: $checkTones)
                } header: {
                    Text("Display")
                } footer: {
                    Text("The tone check measures the pitch of each syllable you say. It is a rough guide: it only marks a tone wrong when it is fairly sure.")
                }
                if lfmChosen || models.lfmReady {
                    Section {
                        if lfmChosen && !models.lfmReady {
                            downloadRow("Download LFM3-Audio (about 2.5 GB)")
                        }
                        TextField(ModelStore.defaultRepo, text: $hfRepo)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        LabeledContent("Model", value: models.modelURL?.lastPathComponent ?? "—")
                        LabeledContent("mmproj", value: models.mmprojURL?.lastPathComponent ?? "—")
                        if !lfmChosen && models.lfmReady && models.lightReady {
                            Button("Delete LFM3-Audio (frees about 2.5 GB)", role: .destructive) { models.deleteLFM() }
                        }
                        if models.backboneIsLowPrecision && lfmChosen {
                            VStack(alignment: .leading, spacing: 6) {
                                Label("This 4-bit model garbles the voice", systemImage: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                Text("Speech needs the more precise Q8_0 model (about 1.9 GB more). Your current files keep working until it is in place, then the 4-bit one is deleted.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                switch models.phase {
                                case .idle, .failed:
                                    Button("Download Q8_0 model") { Task { await models.download() } }
                                        .buttonStyle(.borderedProminent)
                                    if case .failed(let msg) = models.phase {
                                        Text(msg).font(.footnote).foregroundStyle(.red)
                                    }
                                case .resolving:
                                    ProgressView("Looking up files…")
                                case .downloading:
                                    ProgressView(value: models.progress) {
                                        Text("\(Int(models.progress * 100))% · keeps going in the background")
                                            .font(.caption)
                                    }
                                }
                            }
                        }
                    } header: {
                        Text("LFM3-Audio")
                    } footer: {
                        Text(lfmChosen
                             ? "Hugging Face repo with the LFM3-Audio GGUFs. The app uses the Q8_0 backbone and its mmproj; 4-bit backbones garble speech."
                             : "LFM3-Audio isn't picked for anything above; it is only loaded while one of the other models is missing.")
                    }
                }
                if tutor.loadedModel != nil {
                    Section {
                        // never locked: switching stops whatever the tutor is doing and reloads
                        Toggle("Run LFM3-Audio's audio on CPU", isOn: $speechOnCPU)
                            .disabled(reloading)
                            .onChange(of: speechOnCPU) {
                                reloading = true
                                Task {
                                    await tutor.reloadLFM()
                                    reloading = false
                                }
                            }
                        if reloading {
                            HStack { ProgressView(); Text("Reloading the model…").foregroundStyle(.secondary) }
                        } else {
                            LabeledContent("Audio runs on", value: speechOnCPU ? "CPU" : "GPU")
                        }
                    } header: {
                        Text("Troubleshooting")
                    } footer: {
                        Text("Runs LFM3-Audio's audio encoder and voice on the CPU instead of the GPU. Slower; use it to check whether garbled speech comes from the GPU. Last reply's audio is saved in Files › Edge › Diagnostics.")
                    }
                }
                if models.isReady {
                    Section {
                        Button("Delete downloaded models", role: .destructive) { confirmDelete = true }
                    }
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                Button("Done") { dismiss() }
            }
            .confirmationDialog("Delete all the model files? You'll need to download them again.", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    Task {
                        await tutor.unload()
                        models.deleteModels()
                        dismiss()
                    }
                }
            }
        }
    }
}
