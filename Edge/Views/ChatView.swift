import SwiftUI

struct ChatView: View {
    @EnvironmentObject private var tutor: TutorSession
    @State private var showSettings = false
    @State private var typing = false
    @State private var draft = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 14) {
                            if tutor.turns.isEmpty {
                                EmptyChatHint()
                                    .padding(.top, 60)
                            }
                            ForEach(tutor.turns) { turn in
                                TurnView(turn: turn).id(turn.id)
                            }
                        }
                        .padding()
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onChange(of: scrollKey) {
                        if let last = tutor.turns.last {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                }

                controls
            }
            .navigationTitle("中文 Practice")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        tutor.reset()
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .disabled(tutor.turns.isEmpty || tutor.state.isBusy || tutor.state == .listening)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
        }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            statusLine

            if typing {
                HStack {
                    TextField("用中文输入…", text: $draft)
                        .textFieldStyle(.roundedBorder)
                        .submitLabel(.send)
                        .onSubmit(sendDraft)
                    Button(action: sendDraft) { Image(systemName: "arrow.up.circle.fill").font(.title) }
                        .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || !canStart)
                    Button { typing = false } label: { Image(systemName: "mic.circle").font(.title) }
                }
                .padding(.horizontal)
            } else {
                HStack(alignment: .center) {
                    Button { typing = true } label: {
                        Image(systemName: "keyboard").font(.title3)
                    }
                    .frame(width: 60)
                    .disabled(!canStart)

                    Spacer()
                    MicButton(state: tutor.state, seconds: tutor.recordingSeconds) {
                        Task { await tutor.toggleRecording() }
                    }
                    Spacer()

                    Button { tutor.stop() } label: {
                        Image(systemName: "stop.circle").font(.title3)
                    }
                    .frame(width: 60)
                    .disabled(!(tutor.state.isBusy && tutor.state != .loading))
                }
                .padding(.horizontal)
            }
        }
        .padding(.vertical, 12)
        .background(.bar)
    }

    /// Changes whenever the bottom of the conversation grows, without comparing audio buffers.
    private var scrollKey: String {
        guard let last = tutor.turns.last else { return "" }
        return "\(tutor.turns.count)-\(last.text.count)-\(tutor.turns.compactMap(\.feedback).count)-\(tutor.turns.filter { !$0.tones.isEmpty }.count)"
    }

    private var canStart: Bool {
        tutor.state == .idle || tutor.state.isFailedState
    }

    private func sendDraft() {
        let text = draft
        draft = ""
        Task { await tutor.send(text: text) }
    }

    @ViewBuilder private var statusLine: some View {
        switch tutor.state {
        case .notLoaded, .loading:
            HStack(spacing: 8) { ProgressView(); Text("Loading LFM3-Audio…") }
                .font(.footnote).foregroundStyle(.secondary)
        case .idle:
            Text(tutor.turns.isEmpty ? "Tap the mic and say something in Mandarin" : "Tap the mic to answer")
                .font(.footnote).foregroundStyle(.secondary)
        case .listening:
            Text("Listening… tap again when you're done")
                .font(.footnote).foregroundStyle(.red)
        case .transcribing:
            Text("Transcribing…").font(.footnote).foregroundStyle(.secondary)
        case .thinking:
            Text("小林 is thinking…").font(.footnote).foregroundStyle(.secondary)
        case .speaking:
            Text("Speaking… tap the mic to interrupt").font(.footnote).foregroundStyle(.secondary)
        case .failed(let message):
            Text(message).font(.footnote).foregroundStyle(.red)
                .multilineTextAlignment(.center).padding(.horizontal)
        }
    }
}

private struct EmptyChatHint: View {
    var body: some View {
        VStack(spacing: 12) {
            Text("说中文吧！").font(.largeTitle.bold())
            Text("Say anything in Mandarin, like “你好，我叫…” or “我今天很累”. 小林 will answer in Mandarin and tell you in English how to say it better.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 24)
    }
}

private struct MicButton: View {
    let state: TutorSession.State
    let seconds: Double
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(fill)
                    .frame(width: 76, height: 76)
                    .shadow(color: fill.opacity(0.4), radius: state == .listening ? 12 : 4)
                if state == .transcribing || state == .thinking || state == .loading || state == .notLoaded {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .overlay(alignment: .bottom) {
                if state == .listening {
                    Text(String(format: "%.0fs", seconds))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .offset(y: 18)
                }
            }
        }
        .disabled(!enabled)
        .animation(.easeInOut(duration: 0.2), value: state)
    }

    private var enabled: Bool {
        switch state {
        case .idle, .listening, .speaking, .failed: return true
        default: return false
        }
    }

    private var icon: String {
        switch state {
        case .listening: return "stop.fill"
        case .speaking: return "waveform"
        default: return "mic.fill"
        }
    }

    private var fill: Color {
        switch state {
        case .listening: return .red
        case .speaking: return .indigo
        default: return enabled ? .accentColor : .gray
        }
    }
}

private struct TurnView: View {
    let turn: Turn
    @EnvironmentObject private var tutor: TutorSession
    @AppStorage("showPinyin") private var showPinyin = true
    @AppStorage("showEnglish") private var showEnglish = false
    @State private var revealEnglish = false

    var body: some View {
        switch turn.role {
        case .learner: learner
        case .tutor: tutorBubble
        }
    }

    private var learner: some View {
        VStack(alignment: .trailing, spacing: 8) {
            Text(turn.text.isEmpty ? "…" : turn.text)
                .font(.title3)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 18))
                .foregroundStyle(.white)

            if !turn.tones.isEmpty {
                ToneStrip(checks: turn.tones)
            }

            if let fb = turn.feedback, !fb.feedback.isEmpty {
                FeedbackCard(reply: fb, original: turn.text)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 40)
    }

    private var tutorBubble: some View {
        VStack(alignment: .leading, spacing: 6) {
            if turn.reply.reply.isEmpty {
                if turn.isStreaming {
                    ProgressView().padding(.vertical, 6)
                } else {
                    Text(turn.text).font(.body)
                }
            } else {
                Text(turn.reply.reply)
                    .font(.title3)
                    .textSelection(.enabled)
                if showPinyin, !turn.reply.pinyin.isEmpty {
                    Text(turn.reply.pinyin)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if !turn.reply.english.isEmpty {
                    if showEnglish || revealEnglish {
                        Text(turn.reply.english)
                            .font(.subheadline)
                            .italic()
                            .foregroundStyle(.secondary)
                    } else {
                        Button("Show English") { revealEnglish = true }
                            .font(.caption)
                    }
                }
                if !turn.audio.isEmpty && !turn.isStreaming {
                    Button {
                        tutor.replay(turn)
                    } label: {
                        Label("Play again", systemImage: "speaker.wave.2.fill")
                    }
                    .font(.caption)
                    .padding(.top, 2)
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.trailing, 40)
    }
}

private struct FeedbackCard: View {
    let reply: TutorReply
    let original: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(reply.isPerfect ? "Nice!" : "Correction",
                  systemImage: reply.isPerfect ? "checkmark.seal.fill" : "pencil.circle.fill")
                .font(.caption.bold())
                .foregroundStyle(reply.isPerfect ? .green : .orange)
            Text(reply.feedback)
                .font(.subheadline)
            if !reply.isPerfect, !reply.corrected.isEmpty, normalized(reply.corrected) != normalized(original) {
                Text(reply.corrected)
                    .font(.body.weight(.medium))
                    .textSelection(.enabled)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((reply.isPerfect ? Color.green : Color.orange).opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }

    private func normalized(_ s: String) -> String {
        s.filter { !$0.isPunctuation && !$0.isWhitespace }
    }
}
