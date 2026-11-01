import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

struct VoicesView: View {
    @EnvironmentObject private var voices: VoiceLibrary
    @EnvironmentObject private var models: ModelStore
    @State private var adding = false

    var body: some View {
        NavigationStack {
            List {
                if voices.voices.isEmpty {
                    Section("Your voices") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Clone a voice").font(.headline)
                            Text("Import a voice recording or record one: 5 to 15 seconds of one person speaking clearly, with no music or background noise.")
                                .font(.subheadline).foregroundStyle(.secondary)
                            Button("Add a voice") { adding = true }
                                .buttonStyle(.borderedProminent)
                                .padding(.top, 4)
                        }
                        .padding(.vertical, 6)
                    }
                } else {
                    Section("Your voices") {
                        ForEach(voices.voices) { voice in
                            NavigationLink {
                                VoiceDetailView(voiceID: voice.id)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(voice.name).font(.headline)
                                    Text(voice.transcript.isEmpty ? "No transcript (Fast only)" : voice.transcript)
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        }
                        .onDelete { offsets in
                            for i in offsets { voices.delete(voices.voices[i]) }
                        }
                    }
                }
                Section {
                    ForEach(Voice.builtIn) { voice in
                        BuiltInVoiceRow(voice: voice)
                    }
                } header: {
                    Text("Built-in voices")
                } footer: {
                    Text(models.isReady(.kokoro)
                         ? "Kokoro's English voices. Tap play to hear one."
                         : "Download Kokoro in Settings › Voice models to use these.")
                }
            }
            .navigationTitle("Voices")
            .toolbar {
                Button { adding = true } label: { Image(systemName: "plus") }
            }
            .sheet(isPresented: $adding) { AddVoiceView() }
        }
    }
}

struct AddVoiceView: View {
    /// A recording shared to Edge (e.g. from Voice Memos), used right away.
    var initialURL: URL?
    /// Voice Memos (.m4a), other recordings, and videos.
    static let audioTypes: [UTType] = [
        UTType("com.apple.m4a-audio"), .mpeg4Audio, .audio, .wav, .mp3, .aiff,
        UTType("com.apple.coreaudio-format"), .movie, .mpeg4Movie, .quickTimeMovie,
    ].compactMap { $0 }
    @EnvironmentObject private var voices: VoiceLibrary
    @Environment(\.dismiss) private var dismiss
    @StateObject private var recorder = SampleRecorder()
    @State private var name = ""
    @State private var language = Locale.current.region?.identifier == "GB" ? "en-GB" : "en-US"
    @State private var importing = false
    @State private var working = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name (e.g. Me, Grandpa)", text: $name)
                    Picker("Language", selection: $language) {
                        ForEach(VoiceLibrary.languages, id: \.code) { Text($0.name).tag($0.code) }
                    }
                }
                Section {
                    Button {
                        importing = true
                    } label: {
                        Label("Import a recording (.m4a, Voice Memos…)", systemImage: "square.and.arrow.down")
                    }
                    .disabled(working || recorder.isRecording)
                    if recorder.isRecording {
                        VStack(alignment: .leading, spacing: 8) {
                            ProgressView(value: recorder.level)
                            Text("Recording \(formatDuration(recorder.seconds)) — read a few natural sentences")
                                .font(.caption).foregroundStyle(.secondary)
                            Button("Stop and use it") {
                                if let url = recorder.stop() { add(url) }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    } else {
                        Button {
                            Task {
                                do { try await recorder.start() } catch { self.error = error.localizedDescription }
                            }
                        } label: {
                            Label("Record now", systemImage: "mic.fill")
                        }
                        .disabled(working)
                    }
                } footer: {
                    Text("Use 5 to 15 seconds of one person speaking clearly, without music or noise. Longer recordings are trimmed. Any .m4a, .wav, .mp3 or video file works. From Voice Memos you can also tap Share › Edge.")
                }
                if working {
                    Section {
                        HStack { ProgressView(); Text("Preparing the voice and writing down what's said…") }
                    }
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red).font(.footnote) }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Add a voice")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        recorder.stop()
                        dismiss()
                    }
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: Self.audioTypes) { result in
                switch result {
                case .success(let url):
                    if name.isEmpty { name = url.deletingPathExtension().lastPathComponent }
                    add(url)
                case .failure(let e):
                    error = e.localizedDescription
                }
            }
        }
        .interactiveDismissDisabled(working || recorder.isRecording)
        .onAppear {
            if let initialURL, !working {
                name = initialURL.deletingPathExtension().lastPathComponent
                add(initialURL)
            }
        }
    }

    private func add(_ url: URL) {
        working = true
        error = nil
        Task {
            do {
                _ = try await voices.add(from: url, name: name, language: language)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            working = false
        }
    }
}

struct VoiceDetailView: View {
    let voiceID: UUID
    @EnvironmentObject private var voices: VoiceLibrary
    @EnvironmentObject private var models: ModelStore
    @EnvironmentObject private var player: Player
    @AppStorage(AppSettings.Key.defaultVoice) private var defaultVoice = ""
    @State private var name = ""
    @State private var transcript = ""
    @State private var language = "en-US"
    @State private var transcribing = false
    @State private var error: String?
    @State private var testText = "Hi! This is my cloned voice. How does it sound?"
    @State private var testing: VoiceModel?
    @State private var testTask: Task<Void, Never>?

    private var voice: Voice? { voices.voice(voiceID) }

    var body: some View {
        Form {
            if let voice {
                Section("Name") {
                    TextField("Name", text: $name)
                        .onSubmit { save() }
                    Toggle("Default voice for new papers", isOn: Binding(
                        get: { defaultVoice == voice.id.uuidString },
                        set: { defaultVoice = $0 ? voice.id.uuidString : "" }))
                }
                Section {
                    Button {
                        let url = VoiceLibrary.sampleURL(voice.id)
                        if player.isCurrent(url) { player.toggle() } else {
                            player.play(.init(url: url, title: voice.name, subtitle: "Voice sample"))
                        }
                    } label: {
                        Label("Play the sample (\(formatDuration(voice.duration)))", systemImage: "play.circle")
                    }
                    Picker("Language", selection: $language) {
                        ForEach(VoiceLibrary.languages, id: \.code) { Text($0.name).tag($0.code) }
                    }
                    TextField("What is said in the sample", text: $transcript, axis: .vertical)
                        .lineLimit(3...8)
                    Button {
                        transcribing = true
                        error = nil
                        save()
                        Task {
                            do { transcript = try await voices.retranscribe(voices.voice(voiceID) ?? voice) } catch { self.error = error.localizedDescription }
                            transcribing = false
                        }
                    } label: {
                        if transcribing { HStack { ProgressView(); Text("Listening…") } } else { Text("Write it down again automatically") }
                    }
                    .disabled(transcribing)
                } header: {
                    Text("Sample")
                } footer: {
                    Text("The Best model needs the exact words of the sample; fix any mistakes here. The Fast model only uses the sound.")
                }
                Section("Try it") {
                    TextField("Text", text: $testText, axis: .vertical).lineLimit(1...4)
                    ForEach(VoiceModel.cloning) { model in
                        Button {
                            test(model, voice)
                        } label: {
                            HStack {
                                Text("Say it with \(model.title)")
                                Spacer()
                                if testing == model { ProgressView() }
                            }
                        }
                        .disabled(testing != nil || !models.isReady(model) || (model == .best && transcript.isEmpty))
                    }
                    if !VoiceModel.cloning.allSatisfy(models.isReady) {
                        Text("Download the voice models in Settings to try them.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red).font(.footnote) }
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(voice?.name ?? "Voice")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            name = voice?.name ?? ""
            transcript = voice?.transcript ?? ""
            language = voice?.language ?? "en-US"
        }
        .onDisappear {
            save()
            testTask?.cancel()
        }
    }

    private func save() {
        guard var v = voices.voice(voiceID) else { return }
        v.name = name.trimmingCharacters(in: .whitespaces).isEmpty ? v.name : name
        v.transcript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        v.language = language
        voices.update(v)
    }

    private func test(_ model: VoiceModel, _ voice: Voice) {
        save()
        guard let current = voices.voice(voiceID) else { return }
        testing = model
        error = nil
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("voice-test-\(model.rawValue).m4a")
        testTask = Task {
            do {
                let options = SpeechRenderer.Options(voice: current, model: model, steps: AppSettings.steps(model))
                Player.shared.stop(ifPlaying: url)
                _ = try await SpeechRenderer.render(testText, options: options, to: url) { _ in }
                Player.shared.play(.init(url: url, title: current.name, subtitle: "\(model.title) test"))
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
            }
            testing = nil
        }
    }
}

/// Picks a voice: the cloned ones, then Kokoro's built-in voices.
struct VoicePicker: View {
    @Binding var selection: UUID
    @EnvironmentObject private var voices: VoiceLibrary

    var body: some View {
        Picker("Voice", selection: $selection) {
            if !voices.voices.isEmpty {
                Section("Your voices") {
                    ForEach(voices.voices) { v in Text(v.name).tag(v.id) }
                }
            }
            Section("Built-in") {
                ForEach(Voice.builtIn) { v in Text("\(v.name) · \(v.builtInDescription ?? "")").tag(v.id) }
            }
        }
    }
}

/// One of Kokoro's voices, with a play button that says a short greeting in it.
private struct BuiltInVoiceRow: View {
    let voice: Voice
    @EnvironmentObject private var models: ModelStore
    @EnvironmentObject private var player: Player
    @AppStorage(AppSettings.Key.defaultVoice) private var defaultVoice = ""
    @State private var working = false
    @State private var error: String?

    private var url: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("builtin-\(voice.builtInID ?? 0).m4a")
    }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: play) {
                if working {
                    ProgressView().frame(width: 28, height: 28)
                } else {
                    Image(systemName: player.isCurrent(url) && player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.title2)
                }
            }
            .buttonStyle(.borderless)
            .disabled(!models.isReady(.kokoro) || working)
            VStack(alignment: .leading, spacing: 1) {
                Text(voice.name).font(.headline)
                Text(error ?? voice.builtInDescription ?? "").font(.caption)
                    .foregroundStyle(error == nil ? Color.secondary : Color.red)
            }
            Spacer()
            if defaultVoice == voice.id.uuidString || (defaultVoice.isEmpty && voice.id == Voice.defaultVoice.id) {
                Text("Default").font(.caption).foregroundStyle(.secondary)
            }
        }
        .contextMenu {
            Button("Use for new papers") { defaultVoice = voice.id.uuidString }
        }
    }

    private func play() {
        if player.isCurrent(url) {
            player.toggle()
            return
        }
        if FileManager.default.fileExists(atPath: url.path) {
            player.play(.init(url: url, title: voice.name, subtitle: "Built-in voice"))
            return
        }
        working = true
        error = nil
        Task {
            do {
                let options = SpeechRenderer.Options(voice: voice, model: .kokoro, steps: 1)
                let text = "Hi, I'm \(voice.name). I can read your papers out loud, or say anything you type."
                _ = try await SpeechRenderer.render(text, options: options, to: url) { _ in }
                player.play(.init(url: url, title: voice.name, subtitle: "Built-in voice"))
            } catch {
                try? FileManager.default.removeItem(at: url)
                self.error = error.localizedDescription
            }
            working = false
        }
    }
}
