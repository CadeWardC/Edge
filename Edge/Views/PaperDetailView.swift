import SwiftUI

struct PaperDetailView: View {
    let id: UUID
    @EnvironmentObject private var library: PaperLibrary
    @EnvironmentObject private var worker: PaperWorker
    @EnvironmentObject private var voices: VoiceLibrary
    @EnvironmentObject private var models: ModelStore
    @EnvironmentObject private var player: Player
    @State private var editingPromptID: UUID?

    private var paper: Paper? { library.paper(id) }
    private var busy: Bool { worker.isBusy(id) }

    var body: some View {
        if let paper {
            List {
                Section {
                    Text(paper.title).font(.title3.weight(.semibold))
                    if worker.current == id {
                        VStack(alignment: .leading, spacing: 6) {
                            ProgressView(value: worker.fraction)
                            Text(worker.status).font(.caption).foregroundStyle(.secondary)
                            Text("You can leave the app; it keeps going in the background where iOS allows.")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Button("Stop", role: .destructive) { worker.cancel(id) }
                    } else if worker.queued.contains(id) {
                        Label("Waiting for another paper to finish", systemImage: "clock").foregroundStyle(.secondary)
                        Button("Cancel", role: .destructive) { worker.cancel(id) }
                    } else {
                        if let message = paper.message {
                            Label(message, systemImage: "exclamationmark.triangle")
                                .font(.footnote).foregroundStyle(.orange)
                        }
                        Button {
                            worker.start(id, .make)
                        } label: {
                            Label(paper.stage == .done ? "Make missing audio" : "Make the audios", systemImage: "waveform")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(paper.stage == .done && paper.parts.allSatisfy { $0.duration != nil })
                        if paper.hasScripts {
                            Button("Voice it again (new voice or model)") { worker.start(id, .revoice) }
                            Button("Write new scripts and voice them") { worker.start(id, .rewrite) }
                        }
                    }
                }

                Section {
                    ForEach(paper.prompts) { prompt in
                        HStack {
                            Button {
                                editingPromptID = prompt.id
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(prompt.name).foregroundStyle(.primary)
                                    Text(prompt.lengthLabel).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { prompt.enabled },
                                set: { on in
                                    library.update(id) { p in
                                        if let i = p.prompts.firstIndex(where: { $0.id == prompt.id }) { p.prompts[i].enabled = on }
                                    }
                                }))
                                .labelsHidden()
                        }
                    }
                } header: {
                    Text("Audios")
                } footer: {
                    Text("DeepSeek writes one script for each audio that is on. Tap one to edit its prompt and length; changes apply when the scripts are written again.")
                }
                .disabled(busy)

                Section {
                    VoicePicker(selection: Binding(
                        get: { voices.voice(paper.voiceID)?.id ?? Voice.defaultVoice.id },
                        set: { id in library.update(self.id) { $0.voiceID = id } }))
                    let voice = voices.voice(paper.voiceID) ?? Voice.defaultVoice
                    if voice.isBuiltIn {
                        if !models.isReady(.kokoro) {
                            Label("Download Kokoro in Settings to use the built-in voices.", systemImage: "arrow.down.circle")
                                .font(.footnote).foregroundStyle(.orange)
                        }
                    } else {
                        Picker("Cloning model", selection: binding(\.model)) {
                            ForEach(VoiceModel.cloning) { m in
                                Text(m.title + (models.isReady(m) ? "" : " (not downloaded)")).tag(m)
                            }
                        }
                    }
                } header: {
                    Text("Voice")
                } footer: {
                    Text("Changing the voice takes effect when the paper is voiced again.")
                }
                .disabled(busy)

                if !paper.parts.isEmpty {
                    Section("Listen") {
                        ForEach(paper.parts) { part in
                            PartRow(paperID: id, paperTitle: paper.title, part: part)
                        }
                    }
                    let urls = paper.parts.filter { $0.duration != nil }.map { PaperLibrary.audioURL(id, part: $0.id) }
                    if !urls.isEmpty && !busy {
                        Section {
                            ShareLink(items: urls) { Label("Share the audio", systemImage: "square.and.arrow.up") }
                        }
                    }
                }
            }
            .navigationTitle("Paper")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: Binding(get: { editingPromptID.map(IdentifiedUUID.init) }, set: { editingPromptID = $0?.id })) { item in
                if let prompt = library.paper(id)?.prompts.first(where: { $0.id == item.id }) {
                    AudioPromptEditor(prompt: prompt, resetTo: AudioPrompt.defaults.first { $0.id == prompt.id }) { edited in
                        library.update(id) { p in
                            if let i = p.prompts.firstIndex(where: { $0.id == edited.id }) { p.prompts[i] = edited }
                        }
                    }
                }
            }
            .onAppear { setUpAutoAdvance() }
        } else {
            Text("This paper was deleted.").foregroundStyle(.secondary)
        }
    }

    private func binding<T>(_ keyPath: WritableKeyPath<Paper, T>) -> Binding<T> {
        Binding(
            get: { library.paper(id)?[keyPath: keyPath] ?? Paper(title: "", prompts: [], voiceID: nil, model: .fast)[keyPath: keyPath] },
            set: { value in library.update(id) { $0[keyPath: keyPath] = value } }
        )
    }

    /// When a part ends, play the next one.
    private func setUpAutoAdvance() {
        player.onFinish = { item in
            let lib = PaperLibrary.shared
            for p in lib.papers {
                guard let part = p.parts.first(where: { PaperLibrary.audioURL(p.id, part: $0.id) == item.url }) else { continue }
                if let next = p.parts.first(where: { $0.id == part.id + 1 }), next.duration != nil {
                    Player.shared.play(.init(url: PaperLibrary.audioURL(p.id, part: next.id), title: p.title,
                                             subtitle: next.title))
                }
                return
            }
        }
    }
}

private struct PartRow: View {
    let paperID: UUID
    let paperTitle: String
    let part: Paper.Part
    @EnvironmentObject private var player: Player
    @State private var showScript = false

    private var url: URL { PaperLibrary.audioURL(paperID, part: part.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                if part.duration != nil {
                    Button {
                        if player.isCurrent(url) {
                            player.toggle()
                        } else {
                            player.play(.init(url: url, title: paperTitle, subtitle: part.title))
                        }
                    } label: {
                        Image(systemName: player.isCurrent(url) && player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.title)
                    }
                    .buttonStyle(.borderless)
                } else {
                    Image(systemName: "circle.dashed").font(.title).foregroundStyle(.tertiary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(part.title).font(.subheadline.weight(.semibold))
                    Text(part.duration.map(formatDuration) ?? (part.script.isEmpty ? "Not written yet" : "Not voiced yet"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if !part.script.isEmpty {
                    Button { showScript.toggle() } label: {
                        Image(systemName: showScript ? "text.badge.minus" : "text.alignleft")
                    }
                    .buttonStyle(.borderless)
                }
            }
            if showScript {
                Text(part.script)
                    .font(.callout)
                    .textSelection(.enabled)
                    .padding(.top, 4)
            }
        }
        .padding(.vertical, 4)
    }
}

struct IdentifiedUUID: Identifiable {
    let id: UUID
}

/// Edits one audio's name, length and prompt.
struct AudioPromptEditor: View {
    @State var prompt: AudioPrompt
    /// The built-in version of this prompt, offered as a reset.
    var resetTo: AudioPrompt?
    var onSave: (AudioPrompt) -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Name", text: $prompt.name).focused($focused)
                }
                Section {
                    Stepper("At least \(prompt.minMinutes) min", value: $prompt.minMinutes, in: 1...30)
                        .onChange(of: prompt.minMinutes) { if prompt.maxMinutes < prompt.minMinutes { prompt.maxMinutes = prompt.minMinutes } }
                    Stepper("At most \(prompt.maxMinutes) min", value: $prompt.maxMinutes, in: 1...30)
                        .onChange(of: prompt.maxMinutes) { if prompt.minMinutes > prompt.maxMinutes { prompt.minMinutes = prompt.maxMinutes } }
                } header: {
                    Text("Length")
                } footer: {
                    Text("About 150 spoken words a minute.")
                }
                Section {
                    TextEditor(text: $prompt.prompt)
                        .frame(minHeight: 240)
                        .focused($focused)
                } header: {
                    Text("Prompt for DeepSeek")
                } footer: {
                    Text("What this audio should be. The app adds the paper, the length, and rules for writing to be read aloud.")
                }
                if let resetTo {
                    Section {
                        Button("Restore the original prompt") {
                            prompt.name = resetTo.name
                            prompt.prompt = resetTo.prompt
                            prompt.minMinutes = resetTo.minMinutes
                            prompt.maxMinutes = resetTo.maxMinutes
                        }
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(prompt.name.isEmpty ? "Audio" : prompt.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var p = prompt
                        p.name = p.name.trimmingCharacters(in: .whitespaces).isEmpty ? "Audio" : p.name
                        onSave(p)
                        dismiss()
                    }
                    .disabled(prompt.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
