import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var talk: Conversation
    @EnvironmentObject private var models: ModelStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage("showPinyin") private var showPinyin = true
    @AppStorage("showEnglish") private var showEnglish = true
    @AppStorage("checkTones") private var checkTones = true
    @AppStorage("useNeuralEngine") private var useNeuralEngine = false
    @AppStorage("showTimings") private var showTimings = true

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Provider", selection: $talk.providerRaw) {
                        ForEach(Provider.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                    ProviderSettings(provider: talk.provider)
                        .id(talk.providerRaw)
                } header: {
                    Text("Chat model")
                } footer: {
                    Text("Your partner's replies come from \(talk.provider.title). \(talk.provider.keyHint) Keys are kept in the Keychain on this iPhone.")
                }

                BalanceSection(provider: talk.provider)
                    .id("balance-" + talk.providerRaw)

                Section {
                    Picker("Level", selection: $talk.levelRaw) {
                        ForEach(Level.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    NavigationLink("Partner prompt") { PromptEditor() }
                    Toggle("Show pinyin", isOn: $showPinyin)
                    Toggle("Show English", isOn: $showEnglish)
                    Toggle("Check my tones", isOn: $checkTones)
                } header: {
                    Text("Conversation")
                } footer: {
                    Text("The tone check measures the pitch of each syllable you say and compares it with the dictionary tone (with tone sandhi). It is a rough guide: it only marks a tone wrong when it is fairly sure.")
                }

                Section {
                    if models.isReady(.voice) {
                        Picker("Voice", selection: $talk.kokoroVoice) {
                            ForEach(0..<10, id: \.self) { i in Text("Female \(i + 1)").tag(3 + i) }
                            ForEach(0..<10, id: \.self) { i in Text("Male \(i + 1)").tag(58 + i) }
                        }
                        Button("Hear this voice") { preview() }
                    } else {
                        Text("Using the iPhone's Chinese voice. Download the Mandarin voice below for a more natural one.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Speed")
                        Slider(value: $talk.speechRate, in: 0.6...1.3, step: 0.05)
                        Text(String(format: "%.2g×", talk.speechRate)).font(.caption.monospacedDigit()).frame(width: 40)
                    }
                } header: {
                    Text("Partner's voice")
                }

                Section {
                    HStack {
                        Text("Wait after I stop")
                        Slider(value: $talk.pauseSeconds, in: 0.6...3.0, step: 0.1)
                        Text(String(format: "%.1f s", talk.pauseSeconds)).font(.caption.monospacedDigit()).frame(width: 44)
                    }
                } header: {
                    Text("Listening")
                } footer: {
                    Text("Your turn is sent once you have been quiet this long. Hands-free mode (∞) opens the mic again after every reply and pauses itself if nothing is said for 20 seconds.")
                }

                Section {
                    Toggle("Voice on the Neural Engine", isOn: $useNeuralEngine)
                        .onChange(of: useNeuralEngine) { SpeechEngines.shared.reloadVoice() }
                    Toggle("Show timings", isOn: $showTimings)
                } header: {
                    Text("Speed")
                } footer: {
                    Text("Both models are loaded and warmed up when Shuō opens, and replies are spoken sentence by sentence while the rest is still arriving. Recognition and the voice run on the iPhone's performance cores; the Neural Engine switch runs the voice through Core ML instead (it falls back to the CPU if that doesn't work). Timings under each message show how quick it was, so you can compare.")
                }

                Section {
                    ForEach(SpeechModel.allCases) { ModelRow(model: $0) }
                } header: {
                    Text("Speech models (on this iPhone)")
                } footer: {
                    Text("SenseVoice (Alibaba FunAudioLLM) and Kokoro v1.1-zh (Apache-2.0) run on the phone through sherpa-onnx.")
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
        }
    }

    private func preview() {
        let text = "你好，我是小林。今天天气很好，我们聊聊天吧！"
        let voice = talk.kokoroVoice
        let speed = Float(talk.speechRate)
        Task {
            let box = SampleBox()
            _ = try? await SpeechEngines.shared.synthesize(text, speakerID: voice, speed: speed) { chunk, _ in
                box.append(chunk)
                return true
            }
            var turn = Turn(role: .partner, text: text, pinyin: "")
            turn.audio = box.value
            turn.audioRate = Double(SpeechEngines.ttsSampleRate)
            talk.replay(turn)
        }
    }
}

private struct ProviderSettings: View {
    let provider: Provider
    @State private var key = ""
    @State private var models: [String] = []
    @State private var model = ""
    @State private var baseURL = ""
    @State private var checking = false
    @State private var message: String?
    @State private var ok = false

    var body: some View {
        Group {
            SecureField("\(provider.title) API key", text: $key)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit(check)
            HStack {
                Button("Save and check") { check() }
                    .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty || checking)
                if checking { Spacer(); ProgressView() }
            }
            if let message {
                Label(message, systemImage: ok ? "checkmark.circle.fill" : "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(ok ? .green : .orange)
            }
            Picker("Model", selection: $model) {
                ForEach(models.contains(model) ? models : models + [model], id: \.self) { Text($0).tag($0) }
            }
            .onChange(of: model) { UserDefaults.standard.set(model, forKey: "model-\(provider.rawValue)") }
            TextField(provider.defaultBaseURL, text: $baseURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .font(.footnote)
                .onChange(of: baseURL) { UserDefaults.standard.set(baseURL, forKey: "baseURL-\(provider.rawValue)") }
        }
        .onAppear {
            key = provider.apiKey ?? ""
            model = provider.model
            baseURL = UserDefaults.standard.string(forKey: "baseURL-\(provider.rawValue)") ?? ""
            let saved = UserDefaults.standard.stringArray(forKey: "models-\(provider.rawValue)") ?? []
            models = saved.isEmpty ? provider.knownModels : saved
        }
    }

    private func check() {
        provider.apiKey = key
        checking = true
        message = nil
        Task {
            do {
                let list = try await ChatClient(provider: provider).models()
                if !list.isEmpty {
                    models = list
                    UserDefaults.standard.set(list, forKey: "models-\(provider.rawValue)")
                    if !list.contains(model) { model = list.first { provider.knownModels.contains($0) } ?? list[0] }
                }
                ok = true
                message = "Key works. \(list.count) models available."
            } catch {
                ok = false
                message = error.localizedDescription
            }
            checking = false
        }
    }
}

/// What is left on the provider account, and the tokens Shuō has used.
private struct BalanceSection: View {
    let provider: Provider
    @State private var lines: [(String, String)] = []
    @State private var loading = false
    @State private var error: String?
    @State private var month = UsageStore.Totals()
    @State private var all = UsageStore.Totals()

    var body: some View {
        Section {
            if lines.isEmpty && error == nil && !loading {
                Button("Check balance") { refresh() }
                    .disabled(provider.apiKey == nil)
            }
            if loading { HStack { ProgressView(); Text("Checking…").foregroundStyle(.secondary) } }
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                LabeledContent(line.0, value: line.1)
            }
            if let error { Text(error).font(.footnote).foregroundStyle(.orange) }
            if !lines.isEmpty || error != nil {
                Button("Refresh") { refresh() }.disabled(loading)
            }
            LabeledContent("This month in Shuō", value: summary(month))
            LabeledContent("All time in Shuō", value: summary(all))
            Link("Full usage on \(provider.title)'s website", destination: provider.usageURL)
        } header: {
            Text("\(provider.title) balance & usage")
        } footer: {
            Text("The balance comes from your \(provider.title) account. Token counts are what \(provider.title) reported for Shuō's requests on this iPhone; the website shows the cost per model.")
        }
        .onAppear {
            month = UsageStore.totals(provider, period: UsageStore.thisMonth)
            all = UsageStore.totals(provider, period: "all")
            if provider.apiKey != nil { refresh() }
        }
    }

    private func summary(_ t: UsageStore.Totals) -> String {
        guard t.requests > 0 else { return "none yet" }
        let f = { (n: Int) in n >= 10_000 ? String(format: "%.1fk", Double(n) / 1000) : "\(n)" }
        return "\(t.requests) replies · \(f(t.input)) in / \(f(t.output)) out tokens"
    }

    private func refresh() {
        loading = true
        error = nil
        Task {
            do {
                lines = try await ChatClient(provider: provider).balance()
            } catch {
                self.error = error.localizedDescription
            }
            month = UsageStore.totals(provider, period: UsageStore.thisMonth)
            all = UsageStore.totals(provider, period: "all")
            loading = false
        }
    }
}

private struct PromptEditor: View {
    @AppStorage("systemPrompt") private var stored = ""
    @State private var text = ""

    var body: some View {
        Form {
            Section {
                TextEditor(text: $text).frame(minHeight: 280)
            } footer: {
                Text("Who your partner is and how they talk. The app adds your level and asks for the reply with an English translation.")
            }
            Section {
                Button("Restore the default") { text = Conversation.defaultPrompt }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Partner prompt")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { text = stored.isEmpty ? Conversation.defaultPrompt : stored }
        .onDisappear {
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            stored = (t.isEmpty || t == Conversation.defaultPrompt) ? "" : t
        }
    }
}

private struct ModelRow: View {
    let model: SpeechModel
    @EnvironmentObject private var models: ModelStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(model.title) · \(model.modelName)").font(.headline)
                    Text(model.detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if models.isReady(model) { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
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
                HStack { ProgressView(); Text("Unpacking…").font(.caption).foregroundStyle(.secondary) }
            case .ready:
                Button("Delete", role: .destructive) { models.delete(model) }.font(.caption)
            case .failed(let message):
                Text(message).font(.caption).foregroundStyle(.red)
                Button("Try again") { models.download(model) }
            }
        }
        .padding(.vertical, 2)
    }
}
