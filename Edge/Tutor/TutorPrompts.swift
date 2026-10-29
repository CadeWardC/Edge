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

    struct Exchange {
        let learner: String
        let tutorRaw: String
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

    static func system(level: LearnerLevel) -> String {
        """
        You are 小林 (Xiǎo Lín), a warm, patient Mandarin Chinese conversation partner for an English-speaking learner. \
        The learner speaks Mandarin to you; their words come from speech recognition, so ignore missing punctuation. \
        Keep the conversation going about everyday life.

        Reply to every learner message with exactly these four labeled lines, in this order, and nothing else:
        Reply: Your conversational answer in Mandarin, simplified Chinese characters only (no pinyin, no English), one or two sentences, ending with a question.
        English: The English translation of your Reply.
        Feedback: In English, point out any grammar, word-choice or measure-word mistakes in what the learner said and briefly explain the fix. If a word looks misheard, mention which word they may have mispronounced. If everything was correct and natural, write "Perfect!" plus a short compliment.
        Correct: The learner's sentence rewritten as natural Mandarin in simplified Chinese characters (repeat it unchanged if it was already correct).

        Learner level: \(level.title). \(level.replyGuidance)
        """
    }

    /// One worked example so the 2B model keeps the format from the first turn.
    static let example = Exchange(
        learner: "我昨天去商店买了三个苹果们",
        tutorRaw: """
        Reply: 你喜欢吃苹果吗？你还买了什么？
        English: Do you like eating apples? What else did you buy?
        Feedback: Nice sentence! Just drop 们 after 苹果: 们 only goes on people (like 朋友们), never after a number + measure word.
        Correct: 我昨天去商店买了三个苹果。
        """
    )

    /// The full chat prompt: system, example, history, and the new learner message. Each turn's prompt
    /// extends the previous one (with its reply verbatim), so the engine only evaluates what is new.
    static func chat(history: [Exchange], learner: String, level: LearnerLevel) -> String {
        var p = bos + "<|im_start|>system\n\(system(level: level))<|im_end|>\n"
        for ex in [example] + history {
            p += "<|im_start|>user\n\(ex.learner)<|im_end|>\n"
            // past assistant turns carry an empty think block, as the chat template renders them
            p += "<|im_start|>assistant\n<think></think>\(ex.tutorRaw)<|im_end|>\n"
        }
        p += "<|im_start|>user\n\(learner)<|im_end|>\n"
        p += "<|im_start|>assistant\n<think></think>"
        return p
    }
}
