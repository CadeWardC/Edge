import Foundation

enum LearnerLevel: String, CaseIterable, Identifiable {
    case beginner, intermediate, advanced
    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var replyGuidance: String {
        switch self {
        case .beginner:
            return "Use very simple HSK 1-2 words and short sentences (under 15 characters)."
        case .intermediate:
            return "Use everyday HSK 3-4 vocabulary and natural sentences."
        case .advanced:
            return "Speak naturally like a native speaker, including idioms when they fit."
        }
    }
}

enum Voice: String, CaseIterable, Identifiable {
    case female, male
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

/// Prompts for the chat model (Qwen3.5), formatted by its own chat template.
enum TutorPrompts {
    /// One turn of the conversation: what the learner said and the tutor's Chinese reply.
    struct Exchange {
        let learner: String
        let tutor: String
    }

    // Small models handle small, plain tasks much better than one answer with several labeled parts,
    // so each turn is two short requests: the reply, then its translation.

    typealias Message = TextRuntime.Message

    /// The conversational reply: plain chat, Chinese only.
    static func reply(history: [Exchange], learner: String, level: LearnerLevel, maxHistory: Int = 6) -> [Message] {
        let system = """
        You are 小林, a warm, patient Mandarin conversation partner for an English-speaking learner. \
        Answer what the learner says in natural Mandarin: one or two short sentences, ending with a question \
        that keeps the conversation going. Write only simplified Chinese characters and Chinese punctuation: \
        no pinyin, no English, no explanations. \(level.replyGuidance)
        """
        let example = Exchange(learner: "我昨天去商店买了三个苹果", tutor: "你喜欢吃苹果吗？你还买了什么？")
        var m = [Message(role: "system", content: system)]
        for ex in [example] + history.suffix(maxHistory) {
            m.append(Message(role: "user", content: ex.learner))
            m.append(Message(role: "assistant", content: ex.tutor))
        }
        m.append(Message(role: "user", content: learner))
        return m
    }

    /// English translation of a reply.
    static func translate(_ chinese: String) -> [Message] {
        [
            Message(role: "system", content: "Translate the Chinese text into natural English. Reply with the translation only."),
            Message(role: "user", content: chinese),
        ]
    }
}
