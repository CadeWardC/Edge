import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var models: ModelStore
    @EnvironmentObject private var tutor: TutorSession
    @Environment(\.dismiss) private var dismiss

    @AppStorage("voice") private var voice = Voice.female.rawValue
    @AppStorage("level") private var level = LearnerLevel.beginner.rawValue
    @AppStorage("speakReplies") private var speakReplies = true
    @AppStorage("showPinyin") private var showPinyin = true
    @AppStorage("showEnglish") private var showEnglish = false
    @AppStorage("checkTones") private var checkTones = true
    @AppStorage("hfRepo") private var hfRepo = ""
    @AppStorage("autoSend") private var autoSend = true
    @AppStorage("pauseSeconds") private var pauseSeconds = 1.6
    @AppStorage("handsFree") private var handsFree = false
    @AppStorage("speechOnCPU") private var speechOnCPU = false
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
                         ? "Tap the mic once and speak; your turn is sent once you have been quiet this long. Raise it if it cuts you off while you think. Hands-free opens the mic again after each reply. Tap ✕ to stop."
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
                    if models.isReady {
                        Button("Delete downloaded model", role: .destructive) { confirmDelete = true }
                    }
                } header: {
                    Text("Model")
                } footer: {
                    Text("Hugging Face repo with the LFM3-Audio GGUFs. The app prefers a Q4_K_M backbone and the mmproj file.")
                }
                Section {
                    Toggle("Generate speech on CPU", isOn: $speechOnCPU)
                        .disabled(reloading || tutor.state.isBusy || !models.isReady)
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
