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
        // pinyin comes from the dictionary: free, and right where the model would guess
        if out.pinyin.isEmpty, !out.reply.isEmpty {
            out.pinyin = Pinyin.romanize(out.reply)
        }
        return out
    }

    /// True once the Reply line is complete (another line has begun after it), so speech can start
    /// while the rest of the answer is still being written.
    static func replyLineFinished(_ raw: String) -> Bool {
        let lines = raw.components(separatedBy: .newlines)
        guard let i = lines.firstIndex(where: { line in
            let ns = line as NSString
            guard let m = label.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return false }
            return ns.substring(with: m.range(at: 1)).lowercased() == "reply"
                && !ns.substring(from: m.range.upperBound).trimmingCharacters(in: .whitespaces).isEmpty
        }) else { return false }
        return i < lines.count - 1
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
