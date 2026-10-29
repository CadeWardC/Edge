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
    @AppStorage("autoSend") private var autoSend = true
    @AppStorage("pauseSeconds") private var pauseSeconds = 1.6
    @AppStorage("handsFree") private var handsFree = false
    @AppStorage("speechRate") private var speechRate = 1.0

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
                                Text(abs(speechRate - 1) < 0.001 ? "Normal" : String(format: "%.2g×", speechRate))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            Slider(value: $speechRate, in: 0.5...1.3, step: 0.05) {
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
                    modelRow("SenseVoice", "Hears you · 230 MB", ready: models.senseVoiceReady)
                    modelRow("Qwen3.5-2B", "Writes the replies, corrections and translations · 1.3 GB", ready: models.chatModelURL != nil)
                    modelRow("Kokoro", "Speaks the replies · 180 MB", ready: models.kokoroReady)
                    if !models.isReady {
                        switch models.phase {
                        case .idle, .failed:
                            Button("Download missing models") { Task { await models.download() } }
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
                    if let err = tutor.chatModelError {
                        Text(err).font(.footnote).foregroundStyle(.red)
                    }
                    if models.isReady {
                        Button("Delete downloaded models", role: .destructive) { confirmDelete = true }
                    }
                } header: {
                    Text("Models")
                } footer: {
                    Text("Everything runs on your iPhone. Last reply's audio is saved in Files › Edge › Diagnostics.")
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

private func modelRow(_ name: String, _ detail: String, ready: Bool) -> some View {
    HStack {
        VStack(alignment: .leading, spacing: 2) {
            Text(name)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        Image(systemName: ready ? "checkmark.circle.fill" : "arrow.down.circle")
            .foregroundStyle(ready ? .green : .secondary)
    }
}
