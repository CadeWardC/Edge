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
            }
            .navigationTitle("Settings")
            .toolbar {
                Button("Done") { dismiss() }
            }
            .confirmationDialog("Delete the model files? You'll need to download them again.", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    tutor.unload()
                    models.deleteModels()
                    dismiss()
                }
            }
        }
    }
}
