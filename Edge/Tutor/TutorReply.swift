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
        if out.pinyin.isEmpty, !out.reply.isEmpty {
            out.pinyin = Pinyin.romanize(out.reply)
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

    /// What the Chinese voice should read: Chinese characters, Chinese punctuation and digits only.
    /// Empty when there is no Chinese at all, so an English or garbled reply is never spoken.
    var speakableReply: String {
        var s = reply
        for pattern in [#"\([^)]*\)"#, #"（[^）]*）"#] {
            s = s.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        let kept = s.filter { Pinyin.isHanzi($0) || "，。？！、；：0123456789".contains($0) }
        return kept.contains(where: Pinyin.isHanzi) ? kept : ""
    }

    /// The Chinese reply out of whatever the model wrote: drops reasoning before </think>, labels like
    /// "Reply:", and any English or pinyin lines, keeping the lines that are Chinese.
    static func cleanReply(_ raw: String) -> String {
        let text = raw.components(separatedBy: "</think>").last ?? raw
        var kept: [String] = []
        for line in text.components(separatedBy: .newlines) {
            var l = line.trimmingCharacters(in: .whitespaces)
            if let colon = l.firstIndex(where: { $0 == ":" || $0 == "：" }),
               l.distance(from: l.startIndex, to: colon) <= 12,
               !l[..<colon].contains(where: Pinyin.isHanzi) || l[..<colon].count <= 3 {
                l = String(l[l.index(after: colon)...]).trimmingCharacters(in: .whitespaces)   // "Reply: …", "小林：…"
            }
            let hanzi = l.filter(Pinyin.isHanzi).count
            if hanzi > 0 && Double(hanzi) >= Double(l.filter { !$0.isWhitespace }.count) * 0.5 {
                kept.append(l)
            } else if !kept.isEmpty {
                break   // the reply ended; what follows is commentary
            }
        }
        return kept.joined(separator: " ")
    }

    var isPerfect: Bool {
        feedback.lowercased().hasPrefix("perfect")
    }
}
