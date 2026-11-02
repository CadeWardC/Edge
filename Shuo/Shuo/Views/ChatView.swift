import SwiftUI

struct ChatView: View {
    @EnvironmentObject private var talk: Conversation
    @EnvironmentObject private var models: ModelStore
    @AppStorage("showPinyin") private var showPinyin = true
    @AppStorage("showEnglish") private var showEnglish = true
    @AppStorage("checkTones") private var checkTones = true
    @AppStorage("showTimings") private var showTimings = true
    @State private var typing = false
    @State private var draft = ""
    @State private var showSettings = false
    @FocusState private var fieldFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 14) {
                            if talk.turns.isEmpty { welcome }
                            ForEach(talk.turns) { turn in
                                TurnView(turn: turn, showPinyin: showPinyin, showEnglish: showEnglish, checkTones: checkTones,
                                         showTimings: showTimings)
                                    .id(turn.id)
                            }
                        }
                        .padding()
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onChange(of: talk.turns) {
                        if let last = talk.turns.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                    }
                }
                controls
            }
            .navigationTitle("Shuō 说")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { talk.clear() } label: { Image(systemName: "square.and.pencil") }
                        .disabled(talk.turns.isEmpty)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("你好！").font(.system(size: 40, weight: .bold))
            Text("Tap the mic and speak Mandarin. Your partner answers out loud, and each of your syllables gets a tone check.")
                .foregroundStyle(.secondary)
            if Provider(rawValue: talk.providerRaw)?.apiKey == nil {
                Label("Add a DeepSeek or Kimi API key in Settings first.", systemImage: "key")
                    .font(.footnote).foregroundStyle(.orange)
            }
            if !models.isReady(.recognition) || !models.isReady(.voice) {
                Label("For the best recognition and voice, download the speech models in Settings.", systemImage: "arrow.down.circle")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 20)
    }

    private var controls: some View {
        VStack(spacing: 10) {
            status
            if typing {
                HStack {
                    TextField("Type in Chinese (or English)", text: $draft)
                        .textFieldStyle(.roundedBorder)
                        .focused($fieldFocused)
                        .submitLabel(.send)
                        .onSubmit(sendDraft)
                    Button(action: sendDraft) { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                        .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || talk.state.isBusy)
                }
            }
            HStack {
                Button {
                    typing.toggle()
                    fieldFocused = typing
                } label: {
                    Image(systemName: typing ? "keyboard.chevron.compact.down" : "keyboard").font(.title2)
                }
                .frame(width: 60)
                Spacer()
                MicButton(state: talk.state, level: talk.level) { talk.micTapped() }
                Spacer()
                Button {
                    talk.toggleHandsFree()
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: "infinity").font(.title2.weight(talk.handsFree ? .bold : .regular))
                        Text("Hands-free").font(.caption2)
                    }
                    .foregroundStyle(talk.handsFree ? Color.accentColor : Color.secondary)
                }
                .frame(width: 60)
            }
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .background(.bar)
    }

    @ViewBuilder private var status: some View {
        Group {
            switch talk.state {
            case .idle:
                Text(talk.notice ?? (talk.handsFree ? "Hands-free is on" : "Tap the mic and speak"))
            case .listening:
                Text(talk.heardSpeech ? "Listening… pause when you're done" : "Listening… start speaking")
            case .transcribing:
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Understanding…") }
            case .thinking:
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("\(talk.provider.title) is replying…") }
            case .speaking:
                Text("Speaking… tap the mic to answer")
            case .failed(let message):
                Text(message).foregroundStyle(.red)
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(minHeight: 18)
    }

    private func sendDraft() {
        talk.send(text: draft)
        draft = ""
    }
}

private struct MicButton: View {
    let state: Conversation.State
    let level: Double
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .stroke(Color.accentColor.opacity(0.3), lineWidth: 6)
                    .scaleEffect(1 + (state == .listening ? level * 0.35 : 0))
                    .animation(.easeOut(duration: 0.1), value: level)
                Circle()
                    .fill(state == .listening ? Color.red : Color.accentColor)
                Image(systemName: icon)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 78, height: 78)
        }
        .disabled(state.isBusy)
        .opacity(state.isBusy ? 0.5 : 1)
    }

    private var icon: String {
        switch state {
        case .listening: return "arrow.up"
        case .speaking: return "mic.fill"
        default: return "mic.fill"
        }
    }
}

private struct TurnView: View {
    let turn: Turn
    let showPinyin: Bool
    let showEnglish: Bool
    let checkTones: Bool
    let showTimings: Bool
    @EnvironmentObject private var talk: Conversation

    var body: some View {
        VStack(alignment: turn.role == .learner ? .trailing : .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                if turn.role == .learner { Spacer(minLength: 40) }
                VStack(alignment: .leading, spacing: 4) {
                    Text(turn.text).font(.title3)
                    if showPinyin && !turn.pinyin.isEmpty {
                        Text(turn.pinyin).font(.callout).opacity(0.85)
                    }
                    if showEnglish && !turn.english.isEmpty {
                        Text(turn.english).font(.footnote).opacity(0.75)
                    }
                }
                .textSelection(.enabled)
                .padding(12)
                .background(turn.role == .learner ? Color.accentColor : Color(.secondarySystemBackground),
                            in: RoundedRectangle(cornerRadius: 18))
                .foregroundStyle(turn.role == .learner ? Color.white : Color.primary)
                if turn.role == .partner { Spacer(minLength: 40) }
            }
            .overlay(alignment: turn.role == .learner ? .bottomLeading : .bottomTrailing) {
                if !turn.audio.isEmpty || turn.role == .partner {
                    Button { talk.replay(turn) } label: {
                        Image(systemName: "speaker.wave.2.fill").font(.caption)
                            .padding(6)
                            .background(.thinMaterial, in: Circle())
                    }
                    .offset(x: turn.role == .learner ? 4 : -4)
                }
            }
            if showTimings, let timing = turn.timing {
                Text(timing)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 6)
            }
            if turn.role == .partner && (turn.suggesting || !turn.suggestions.isEmpty) {
                SuggestionsCard(turn: turn, showPinyin: showPinyin, showEnglish: showEnglish)
                    .padding(.trailing, 40)
            }
            if turn.role == .learner && checkTones && !turn.tones.isEmpty {
                ToneStrip(checks: turn.tones)
                    .padding(.leading, 40)
            }
        }
    }
}

/// "You could say…": short answers to the partner's reply, to hear and repeat (or send).
private struct SuggestionsCard: View {
    let turn: Turn
    let showPinyin: Bool
    let showEnglish: Bool
    @EnvironmentObject private var talk: Conversation

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("You could say", systemImage: "lightbulb")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            if turn.suggesting && turn.suggestions.isEmpty {
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Thinking of answers…").font(.caption) }
                    .foregroundStyle(.secondary)
            }
            ForEach(turn.suggestions) { s in
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.chinese).font(.body)
                        if showPinyin { Text(s.pinyin).font(.caption).foregroundStyle(.secondary) }
                        if showEnglish && !s.english.isEmpty { Text(s.english).font(.caption2).foregroundStyle(.tertiary) }
                    }
                    .textSelection(.enabled)
                    Spacer(minLength: 4)
                    Button { talk.sayAloud(s.chinese) } label: {
                        Image(systemName: "speaker.wave.2.fill")
                    }
                    .buttonStyle(.borderless)
                    Button { talk.send(text: s.chinese) } label: {
                        Image(systemName: "arrow.up.circle.fill").font(.title3)
                    }
                    .buttonStyle(.borderless)
                    .disabled(talk.state.isBusy)
                }
                .padding(.vertical, 2)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.secondary.opacity(0.2)))
    }
}
