import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var models: ModelStore
    @EnvironmentObject private var voices: VoiceLibrary
    @AppStorage(AppSettings.Key.model) private var deepSeekModel = DeepSeekClient.knownModels[0]
    @AppStorage(AppSettings.Key.baseURL) private var baseURL = ""
    @AppStorage(AppSettings.Key.parts) private var parts = 3
    @AppStorage(AppSettings.Key.minutes) private var minutes = 4
    @AppStorage(AppSettings.Key.voiceModel) private var voiceModel = VoiceModel.fast.rawValue
    @AppStorage(AppSettings.Key.bestSteps) private var bestSteps = 8
    @AppStorage(AppSettings.Key.fastSteps) private var fastSteps = 2
    @AppStorage(AppSettings.Key.speed) private var speed = 1.0
    @AppStorage("deepseekModels") private var modelList = DeepSeekClient.knownModels.joined(separator: ",")

    @State private var key = Keychain.deepSeekKey ?? ""
    @State private var keySaved = Keychain.deepSeekKey != nil
    @State private var checking = false
    @State private var keyMessage: String?
    @State private var keyOK = false

    private var availableModels: [String] {
        let list = modelList.split(separator: ",").map(String.init).filter { !$0.isEmpty }
        return list.contains(deepSeekModel) ? list : list + [deepSeekModel]
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("API key (sk-…)", text: $key)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit(saveKey)
                    HStack {
                        Button(keySaved && key == (Keychain.deepSeekKey ?? "") ? "Check key" : "Save and check") { saveKey() }
                            .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty || checking)
                        if checking { Spacer(); ProgressView() }
                    }
                    if let keyMessage {
                        Label(keyMessage, systemImage: keyOK ? "checkmark.circle.fill" : "exclamationmark.triangle")
                            .font(.footnote).foregroundStyle(keyOK ? .green : .orange)
                    }
                    Picker("Model", selection: $deepSeekModel) {
                        ForEach(availableModels, id: \.self) { Text($0).tag($0) }
                    }
                    NavigationLink("Advanced") {
                        Form {
                            Section {
                                TextField(DeepSeekClient.defaultBaseURL, text: $baseURL)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .keyboardType(.URL)
                            } header: {
                                Text("API address")
                            } footer: {
                                Text("Leave empty for \(DeepSeekClient.defaultBaseURL). Any OpenAI-compatible endpoint works.")
                            }
                            if keySaved {
                                Section {
                                    Button("Remove the API key", role: .destructive) {
                                        Keychain.deepSeekKey = nil
                                        key = ""
                                        keySaved = false
                                        keyMessage = nil
                                    }
                                }
                            }
                        }
                        .navigationTitle("Advanced")
                    }
                } header: {
                    Text("DeepSeek")
                } footer: {
                    Text("Get a key at platform.deepseek.com. It is stored in the Keychain on this iPhone and only sent to DeepSeek. Checking the key also loads the models your account can use. deepseek-chat is fast; deepseek-reasoner thinks first and is slower.")
                }

                Section {
                    NavigationLink {
                        PromptEditor()
                    } label: {
                        HStack {
                            Text("Prompt")
                            Spacer()
                            Text(UserDefaults.standard.string(forKey: AppSettings.Key.prompt)?.isEmpty == false ? "Custom" : "Default")
                                .foregroundStyle(.secondary)
                        }
                    }
                    Stepper("Audio parts: \(parts)", value: $parts, in: 1...12)
                    Stepper("About \(minutes) min each", value: $minutes, in: 1...20)
                } header: {
                    Text("Paper audio")
                } footer: {
                    Text("Defaults for new papers; each paper can change them. A paper becomes \(parts) audio file\(parts == 1 ? "" : "s") of about \(minutes) minute\(minutes == 1 ? "" : "s").")
                }

                Section {
                    ForEach([VoiceModel.kokoro, .best, .fast]) { model in
                        ModelRow(model: model)
                    }
                } header: {
                    Text("Voice models")
                } footer: {
                    Text("All run on this iPhone. Kokoro has 27 ready-made English voices (Apache-2.0). Best (ZipVoice, Apache-2.0) and Fast (Kyutai's Pocket TTS, non-commercial use only) clone any voice from a short recording.")
                }

                Section {
                    Picker("Cloning model", selection: $voiceModel) {
                        ForEach(VoiceModel.cloning) { Text($0.title).tag($0.rawValue) }
                    }
                    Stepper("Best quality steps: \(bestSteps)", value: $bestSteps, in: 4...16, step: 2)
                    Stepper("Fast quality steps: \(fastSteps)", value: $fastSteps, in: 1...6)
                    HStack {
                        Text("Speaking speed")
                        Slider(value: $speed, in: 0.7...1.4, step: 0.05)
                        Text(String(format: "%.2g×", speed)).font(.caption.monospacedDigit()).frame(width: 40)
                    }
                } header: {
                    Text("Voice")
                } footer: {
                    Text("The cloning model is the default for your own voices; built-in voices always use Kokoro. More steps sound a little more natural but take longer. Best: 8 is a good balance (4 is quickest). Fast: 2 is the usual setting.")
                }

                Section("Storage") {
                    LabeledContent("Papers", value: "\(PaperLibrary.shared.papers.count)")
                    LabeledContent("Voices", value: "\(voices.voices.count)")
                    LabeledContent("Files", value: "Files › On My iPhone › Edge")
                }
            }
            .navigationTitle("Settings")
        }
    }

    private func saveKey() {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Keychain.deepSeekKey = trimmed
        keySaved = true
        checking = true
        keyMessage = nil
        Task {
            do {
                let list = try await DeepSeekClient(apiKey: trimmed).models()
                if !list.isEmpty {
                    modelList = list.joined(separator: ",")
                    if !list.contains(deepSeekModel) { deepSeekModel = list.first(where: { $0 == "deepseek-chat" }) ?? list[0] }
                }
                keyOK = true
                keyMessage = "Key works. \(list.count) model\(list.count == 1 ? "" : "s") available."
            } catch {
                keyOK = false
                keyMessage = error.localizedDescription
            }
            checking = false
        }
    }
}

private struct ModelRow: View {
    let model: VoiceModel
    @EnvironmentObject private var models: ModelStore
    @State private var confirmDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(model.title) · \(model.modelName)").font(.headline)
                    Text(model.detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                switch models.state(model) {
                case .ready:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .installing:
                    ProgressView()
                default:
                    EmptyView()
                }
            }
            switch models.state(model) {
            case .missing:
                Button("Download (\(ByteCountFormatter.string(fromByteCount: model.approximateBytes, countStyle: .file)))") {
                    models.download(model)
                }
            case .downloading(let fraction):
                ProgressView(value: fraction) {
                    Text("\(Int(fraction * 100))% · keeps going in the background").font(.caption)
                }
                Button("Cancel", role: .cancel) { models.cancel(model) }.font(.caption)
            case .installing:
                Text("Unpacking…").font(.caption).foregroundStyle(.secondary)
            case .ready:
                Button("Delete", role: .destructive) { confirmDelete = true }.font(.caption)
            case .failed(let message):
                Text(message).font(.caption).foregroundStyle(.red)
                Button("Try again") { models.download(model) }
            }
        }
        .padding(.vertical, 2)
        .confirmationDialog("Delete the \(model.modelName) model?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { models.delete(model) }
        }
    }
}

private struct PromptEditor: View {
    @AppStorage(AppSettings.Key.prompt) private var stored = ""
    @State private var text = ""

    var body: some View {
        Form {
            Section {
                TextEditor(text: $text)
                    .frame(minHeight: 320)
            } footer: {
                Text("How DeepSeek should write the audio scripts: style, depth, audience, what to focus on. The app adds the paper, the number of parts and their length. Each paper can also have its own prompt.")
            }
            Section {
                Button("Restore the default prompt") { text = AppSettings.defaultPrompt }
            }
        }
        .navigationTitle("Prompt")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { text = stored.isEmpty ? AppSettings.defaultPrompt : stored }
        .onDisappear {
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            stored = (t.isEmpty || t == AppSettings.defaultPrompt) ? "" : t
        }
    }
}
