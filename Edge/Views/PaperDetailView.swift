import SwiftUI

struct PaperDetailView: View {
    let id: UUID
    @EnvironmentObject private var library: PaperLibrary
    @EnvironmentObject private var worker: PaperWorker
    @EnvironmentObject private var voices: VoiceLibrary
    @EnvironmentObject private var models: ModelStore
    @EnvironmentObject private var player: Player
    @State private var editingPrompt = false

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
                            Label(paper.stage == .done ? "Make missing audio" : "Make audio", systemImage: "waveform")
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
                    Stepper("Audio parts: \(paper.partsCount)", value: binding(\.partsCount), in: 1...12)
                    Stepper("About \(paper.minutesPerPart) min each", value: binding(\.minutesPerPart), in: 1...20)
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
                    Button {
                        editingPrompt = true
                    } label: {
                        HStack {
                            Text("Prompt")
                            Spacer()
                            Text(paper.customPrompt == nil ? "From Settings" : "Custom").foregroundStyle(.secondary)
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    .foregroundStyle(.primary)
                } header: {
                    Text("Series")
                } footer: {
                    Text("Changing the parts, length or prompt takes effect when the scripts are written again. Changing the voice takes effect when it is voiced again.")
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
            .sheet(isPresented: $editingPrompt) {
                PaperPromptEditor(paperID: id)
            }
            .onAppear { setUpAutoAdvance() }
        } else {
            Text("This paper was deleted.").foregroundStyle(.secondary)
        }
    }

    private func binding<T>(_ keyPath: WritableKeyPath<Paper, T>) -> Binding<T> {
        Binding(
            get: { library.paper(id)?[keyPath: keyPath] ?? Paper(title: "", partsCount: 1, minutesPerPart: 1, model: .fast)[keyPath: keyPath] },
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
                                             subtitle: "Part \(next.id): \(next.title)"))
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
                            player.play(.init(url: url, title: paperTitle, subtitle: "Part \(part.id): \(part.title)"))
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
                    Text("Part \(part.id): \(part.title)").font(.subheadline.weight(.semibold))
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

/// Edits the prompt used for one paper (or switches it back to the one in Settings).
private struct PaperPromptEditor: View {
    let paperID: UUID
    @EnvironmentObject private var library: PaperLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var custom = false

    var body: some View {
        NavigationStack {
            Form {
                Toggle("Custom prompt for this paper", isOn: $custom)
                Section {
                    TextEditor(text: $text)
                        .frame(minHeight: 260)
                        .disabled(!custom)
                        .foregroundStyle(custom ? .primary : .secondary)
                } footer: {
                    Text("Tells DeepSeek how to write the audio scripts: style, depth, audience, what to focus on. The app adds the paper, the number of parts and their length.")
                }
            }
            .navigationTitle("Prompt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        library.update(paperID) { $0.customPrompt = custom && !value.isEmpty ? value : nil }
                        dismiss()
                    }
                }
            }
            .onAppear {
                let p = library.paper(paperID)
                custom = p?.customPrompt != nil
                text = p?.customPrompt ?? AppSettings.prompt
            }
        }
    }
}
