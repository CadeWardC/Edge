import Foundation

/// The tutor's Chinese reply, its pinyin and its English translation.
struct TutorReply: Equatable {
    var reply = ""
    var pinyin = ""
    var english = ""

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
}
