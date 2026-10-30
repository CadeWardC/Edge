import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var models: ModelStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage("voice") private var voice = NarratorVoice.heart.rawValue
    @AppStorage("speechSpeed") private var speechSpeed = 1.0
    @AppStorage("chatRepo") private var chatRepo = ""
    @AppStorage("hostVoice") private var hostVoice = ""
    @State private var confirmDelete = false
    @State private var showNotices = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Main voice", selection: $voice) {
                        ForEach(NarratorVoice.allCases) { v in
                            Text(v.label).tag(v.rawValue)
                        }
                    }
                    Picker("Second voice", selection: $hostVoice) {
                        Text("Automatic (contrasting)").tag("")
                        ForEach(NarratorVoice.allCases.filter { $0.rawValue != voice }) { v in
                            Text(v.label).tag(v.rawValue)
                        }
                    }
                    VStack(alignment: .leading) {
                        Text("Reading pace: \(String(format: "%.2f", speechSpeed))×")
                        Slider(value: $speechSpeed, in: 0.85...1.2, step: 0.05)
                    }
                } header: {
                    Text("Voices")
                } footer: {
                    Text("The main voice explains; the second voice asks the questions that lead into each part, so the audio sounds like a conversation. Used for new recordings: open a paper and choose Record again to hear it with new voices. Playback speed is in the player.")
                }

                Section {
                    Picker("Summary model", selection: modelChoice) {
                        Text("Standard · Qwen3.5-2B (1.3 GB)").tag(ModelStore.defaultChatRepo)
                        Text("Best · Qwen3.5-4B (2.7 GB, slower)").tag(ModelStore.largerChatRepo)
                        if !isPreset { Text(effectiveRepo).tag(effectiveRepo) }
                    }
                    LabeledContent("Free memory for Papers", value: ByteCountFormatter.string(fromByteCount: ModelStore.availableMemory, countStyle: .memory))
                    if wantsLarger && !largerFits {
                        Text("On this iPhone the larger model doesn't fit in the memory iOS gives one app, so it runs on the CPU and reads its weights from storage as it goes. It fits that way, but writing takes about two to three times as long.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("Downloaded", value: models.chatModelURL?.lastPathComponent ?? "Not downloaded")
                    if models.chatModelURL != nil && !downloadedMatchesChoice {
                        Button("Download the chosen model") {
                            models.deleteChatModel()
                            Task { await models.download() }
                        }
                    }
                    DisclosureGroup("Another model") {
                        TextField(ModelStore.defaultChatRepo, text: $chatRepo)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.footnote.monospaced())
                        Text("Any Hugging Face repo with a GGUF of a chat model llama.cpp can run.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Summary model")
                } footer: {
                    Text("The model that reads papers and transcripts and writes the summaries. The 4B model understands papers noticeably better and makes fewer mistakes; the 2B model is faster.")
                }

                Section {
                    LabeledContent("Voice", value: models.kokoroReady ? "Kokoro-82M v1.0" : "Not downloaded")
                    LabeledContent("Speech recognition", value: models.speechReady ? "Parakeet TDT 0.6B v3" : "Not downloaded")
                    if models.speechReady {
                        Button("Delete speech recognition (670 MB)", role: .destructive) { models.deleteSpeechModel() }
                    }
                    Button("Delete all models", role: .destructive) { confirmDelete = true }
                } header: {
                    Text("Downloads")
                }

                Section {
                    Button("Third-party notices") { showNotices = true }
                } footer: {
                    Text("Everything runs on this iPhone. Nothing leaves it except the one-time model download.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
            .confirmationDialog("Delete the downloaded models? Your papers and summaries stay.",
                                isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete models", role: .destructive) { models.deleteModels() }
            }
            .sheet(isPresented: $showNotices) {
                NavigationStack {
                    ScrollView {
                        Text(Self.notices)
                            .font(.footnote.monospaced())
                            .padding()
                    }
                    .navigationTitle("Notices")
                    .toolbar { Button("Done") { showNotices = false } }
                }
            }
        }
    }

    private var effectiveRepo: String {
        let r = chatRepo.trimmingCharacters(in: .whitespaces)
        return r.isEmpty ? ModelStore.defaultChatRepo : r
    }

    private var isPreset: Bool {
        [ModelStore.defaultChatRepo, ModelStore.largerChatRepo].contains(effectiveRepo)
    }

    private var modelChoice: Binding<String> {
        Binding(get: { effectiveRepo }, set: { chatRepo = $0 == ModelStore.defaultChatRepo ? "" : $0 })
    }

    private var wantsLarger: Bool { effectiveRepo == ModelStore.largerChatRepo }

    private var largerFits: Bool { ModelStore.fits(modelBytes: ModelStore.largerChatBytes) }

    /// The downloaded GGUF comes from the chosen repo (judged by its name, e.g. "Qwen3.5-4B").
    private var downloadedMatchesChoice: Bool {
        guard let file = models.chatModelURL?.lastPathComponent.lowercased() else { return true }
        let name = effectiveRepo.split(separator: "/").last.map { $0.lowercased().replacingOccurrences(of: "-gguf", with: "") } ?? ""
        return name.isEmpty || file.contains(name)
    }

    private static var notices: String {
        guard let url = Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return text
    }
}
