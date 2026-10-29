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
    @State private var reloading = false

    @State private var confirmDelete = false

    var body: some View {
        NavigationStack {
            Form {
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
                    Toggle("Show pinyin", isOn: $showPinyin)
                    Toggle("Show English translation", isOn: $showEnglish)
                    Toggle("Check my tones", isOn: $checkTones)
                } header: {
                    Text("Display")
                } footer: {
                    Text("The tone check measures the pitch of each syllable you say. It is a rough guide: it only marks a tone wrong when it is fairly sure.")
                }
                Section {
                    TextField(ModelStore.defaultRepo, text: $hfRepo)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    LabeledContent("Model", value: models.modelURL?.lastPathComponent ?? "—")
                    LabeledContent("mmproj", value: models.mmprojURL?.lastPathComponent ?? "—")
                    if models.backboneIsLowPrecision {
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
                    if models.isReady {
                        Button("Delete downloaded model", role: .destructive) { confirmDelete = true }
                    }
                } header: {
                    Text("Model")
                } footer: {
                    Text("Hugging Face repo with the LFM3-Audio GGUFs. The app uses the Q8_0 backbone and its mmproj; 4-bit backbones garble speech.")
                }
                Section {
                    // never locked: switching stops whatever the tutor is doing and reloads
                    Toggle("Generate speech on CPU", isOn: $speechOnCPU)
                        .disabled(reloading || !models.isReady)
                        .onChange(of: speechOnCPU) {
                            guard let model = models.modelURL, let mmproj = models.mmprojURL else { return }
                            reloading = true
                            Task {
                                await tutor.reload(model: model, mmproj: mmproj)
                                reloading = false
                            }
                        }
                    if reloading {
                        HStack { ProgressView(); Text("Reloading the model…").foregroundStyle(.secondary) }
                    } else if models.isReady {
                        LabeledContent("Speech runs on", value: speechOnCPU ? "CPU" : "GPU")
                    }
                } header: {
                    Text("Troubleshooting")
                } footer: {
                    Text("Runs the audio encoder and voice on the CPU instead of the GPU. Slower; use it to check whether garbled speech comes from the GPU. Last reply's audio is saved in Files › Edge › Diagnostics.")
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                Button("Done") { dismiss() }
            }
            .confirmationDialog("Delete the model files? You'll need to download them again.", isPresented: $confirmDelete, titleVisibility: .visible) {
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
