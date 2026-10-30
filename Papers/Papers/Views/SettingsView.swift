import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var models: ModelStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage("voice") private var voice = NarratorVoice.heart.rawValue
    @AppStorage("speechSpeed") private var speechSpeed = 1.0
    @AppStorage("chatRepo") private var chatRepo = ""
    @State private var confirmDelete = false
    @State private var showNotices = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Voice", selection: $voice) {
                        ForEach(NarratorVoice.allCases) { v in
                            Text(v.label).tag(v.rawValue)
                        }
                    }
                    VStack(alignment: .leading) {
                        Text("Reading pace: \(String(format: "%.2f", speechSpeed))×")
                        Slider(value: $speechSpeed, in: 0.8...1.2, step: 0.05)
                    }
                } header: {
                    Text("Narrator")
                } footer: {
                    Text("Used for new recordings. To hear an existing summary in another voice, open it and choose Record again. You can also change the playback speed in the player.")
                }

                Section {
                    LabeledContent("Summary model", value: models.chatModelURL?.lastPathComponent ?? "Not downloaded")
                    LabeledContent("Voice model", value: models.kokoroReady ? "Kokoro-82M v1.0" : "Not downloaded")
                    TextField(ModelStore.defaultChatRepo, text: $chatRepo)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.footnote.monospaced())
                    if models.chatModelURL != nil {
                        Button("Download this summary model instead") {
                            models.deleteChatModel()
                            Task { await models.download() }
                        }
                        .disabled(chatRepo.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    Button("Delete all models", role: .destructive) { confirmDelete = true }
                } header: {
                    Text("Models")
                } footer: {
                    Text("Any Hugging Face repo with a GGUF of a chat model works, for example a larger Qwen3.5. Larger models write better summaries but are slower and need more memory.")
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

    private static var notices: String {
        guard let url = Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return text
    }
}
