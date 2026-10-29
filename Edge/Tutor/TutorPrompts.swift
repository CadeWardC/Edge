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

/// Prompts for LFM3-Audio-2B, rendered by hand in the model's ChatML format.
enum TutorPrompts {
    static let bos = "<|startoftext|>"
    static let mediaMarker = "<__media__>"

    /// One turn of the conversation: what the learner said and the tutor's Chinese reply.
    struct Exchange {
        let learner: String
        let tutor: String
    }

    /// Speech recognition of the learner's Mandarin (model-card system prompt).
    static func asr() -> String {
        bos
            + "<|im_start|>system\nPerform ASR in Chinese.<|im_end|>\n"
            + "<|im_start|>user\n\(mediaMarker)<|im_end|>\n"
            + "<|im_start|>assistant\n"
    }

    /// Reading the reply aloud: the "tts" chat template of LFM3-Audio.
    static func tts(_ text: String, voice: Voice) -> String {
        bos
            + "<|im_start|>system\nPerform TTS in Chinese using a \(voice.rawValue) voice.<|im_end|>\n"
            + "<|im_start|>user\n\(text)<|im_end|>\n"
            + "<|im_start|>assistant\n<|audio_start|>"
    }

    // Small models handle small, plain tasks much better than one answer with several labeled parts,
    // so each turn is three short requests: the reply, the correction, and the translation. Each is a list of
    // messages, formatted either by hand for LFM3-Audio (`lfm`) or by the chat model's own template.

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

    /// Prefilled start of the correction, so the answer cannot wander off before it.
    static let feedbackPrefill = "Correct:"

    /// Correction of the learner's sentence on its own, with no conversation around it.
    static func feedback(learner: String) -> [Message] {
        let system = """
        You are a Mandarin teacher for an English-speaking learner. The learner's sentence comes from speech \
        recognition, so ignore punctuation. Check it for grammar, word-choice and measure-word mistakes. \
        Answer with exactly two lines:
        Correct: the sentence rewritten as natural Mandarin (unchanged if it was already correct)
        Feedback: in English, one or two short sentences explaining each fix, or "Perfect!" and a short \
        compliment if it was already correct
        """
        return [
            Message(role: "system", content: system),
            Message(role: "user", content: "我昨天去商店买了三个苹果们"),
            Message(role: "assistant", content: "Correct: 我昨天去商店买了三个苹果。\nFeedback: Drop 们 after 苹果: 们 only goes on people (like 朋友们), never after a number and measure word."),
            Message(role: "user", content: "我很喜欢喝咖啡"),
            Message(role: "assistant", content: "Correct: 我很喜欢喝咖啡。\nFeedback: Perfect! Very natural."),
            Message(role: "user", content: learner),
        ]
    }

    /// English translation of a reply.
    static func translate(_ chinese: String) -> [Message] {
        [
            Message(role: "system", content: "Translate the Chinese text into natural English. Reply with the translation only."),
            Message(role: "user", content: chinese),
        ]
    }

    /// LFM3-Audio's chat format, written by hand (its template is not one llama.cpp can apply itself):
    /// past assistant turns and the new one start with an empty think block.
    static func lfm(_ messages: [Message], prefill: String = "") -> String {
        var p = bos
        for msg in messages {
            let think = msg.role == "assistant" ? "<think></think>" : ""
            p += "<|im_start|>\(msg.role)\n\(think)\(msg.content)<|im_end|>\n"
        }
        return p + "<|im_start|>assistant\n<think></think>" + prefill
    }
}
