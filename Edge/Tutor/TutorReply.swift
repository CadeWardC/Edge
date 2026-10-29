import Foundation

/// The labeled fields of a tutor answer, parsed leniently while it streams in.
struct TutorReply: Equatable {
    var feedback = ""
    var corrected = ""
    var reply = ""
    var pinyin = ""
    var english = ""

    private enum Field: String, CaseIterable {
        case feedback, correct, reply, pinyin, english
    }

    // "Feedback:", "**Reply**：", "- Pinyin:" ... at the start of a line
    private static let label = try! NSRegularExpression(
        pattern: #"^[\s\-\*#>]*(feedback|correct(?:ed|ion)?|reply|pinyin|english)\s*\**\s*[:：]\s*\**\s*"#,
        options: [.caseInsensitive]
    )

    static func parse(_ raw: String) -> TutorReply {
        var out = TutorReply()
        var current: Field?
        var sawLabel = false

        let text = raw.components(separatedBy: "</think>").last ?? raw
        for line in text.components(separatedBy: .newlines) {
            let ns = line as NSString
            if let m = label.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
                let key = ns.substring(with: m.range(at: 1)).lowercased()
                current = key.hasPrefix("correct") ? .correct : Field(rawValue: key)
                sawLabel = true
                out.append(ns.substring(from: m.range.upperBound), to: current)
            } else if current != nil {
                out.append(line, to: current)
            }
        }
        // a model that ignored the format: treat everything as the reply
        if !sawLabel {
            out.reply = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return out
    }

    private mutating func append(_ s: String, to field: Field?) {
        let piece = s.trimmingCharacters(in: .whitespaces)
        guard let field, !piece.isEmpty else { return }
        func join(_ a: String) -> String { a.isEmpty ? piece : a + " " + piece }
        switch field {
        case .feedback: feedback = join(feedback)
        case .correct:  corrected = join(corrected)
        case .reply:    reply = join(reply)
        case .pinyin:   pinyin = join(pinyin)
        case .english:  english = join(english)
        }
    }

    /// The reply with anything the Chinese voice should not read: parentheses, pinyin, stray Latin text.
    var speakableReply: String {
        var s = reply
        for pattern in [#"\([^)]*\)"#, #"（[^）]*）"#, #"[A-Za-zāáǎàēéěèīíǐìōóǒòūúǔùǖǘǚǜü]+"#] {
            s = s.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isPerfect: Bool {
        feedback.lowercased().hasPrefix("perfect")
    }
}
