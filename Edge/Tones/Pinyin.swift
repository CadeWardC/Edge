import Foundation

/// Character and phrase readings from Resources/pinyin.tsv (built by scripts/build-pinyin-dict.py).
enum Pinyin {
    struct Syllable: Equatable, Sendable {
        let character: String
        /// Dictionary reading, numbered: "hao3", "ma5"
        let numbered: String
        /// Tone actually expected in this sentence, after tone sandhi (5 = neutral)
        var spokenTone: Int

        var dictionaryTone: Int { numbered.last?.wholeNumberValue ?? 5 }
        var marked: String { Pinyin.marked(numbered) }
        /// The reading with the sandhi tone, e.g. "ní" for 你 in 你好
        var spokenMarked: String { Pinyin.marked(String(numbered.dropLast()) + String(spokenTone)) }
    }

    private static let table: [String: String] = {
        guard let url = Bundle.main.url(forResource: "pinyin", withExtension: "tsv"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var t = [String: String](minimumCapacity: 70_000)
        for line in text.split(separator: "\n") {
            guard let tab = line.firstIndex(of: "\t") else { continue }
            t[String(line[..<tab])] = String(line[line.index(after: tab)...])
        }
        return t
    }()

    static func isHanzi(_ c: Character) -> Bool {
        guard let v = c.unicodeScalars.first?.value, c.unicodeScalars.count == 1 else { return false }
        return (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v)
    }

    /// The syllables of a sentence in order, with tone sandhi applied inside each clause.
    static func syllables(in text: String) -> [Syllable] {
        let chars = Array(text)
        var clauses: [[Syllable]] = [[]]
        var i = 0
        while i < chars.count {
            guard isHanzi(chars[i]) else {
                if !(clauses.last?.isEmpty ?? true) { clauses.append([]) }
                i += 1
                continue
            }
            // longest phrase first, so polyphones like 银行 / 行走 get the right reading
            var matched = false
            for len in stride(from: min(4, chars.count - i), through: 2, by: -1) {
                let piece = chars[i..<(i + len)]
                guard piece.allSatisfy(isHanzi), let reading = table[String(piece)] else { continue }
                let sylls = reading.split(separator: " ").map(String.init)
                guard sylls.count == len else { continue }
                for (c, s) in zip(piece, sylls) {
                    clauses[clauses.count - 1].append(Syllable(character: String(c), numbered: s, spokenTone: s.last?.wholeNumberValue ?? 5))
                }
                i += len
                matched = true
                break
            }
            if !matched {
                if let s = table[String(chars[i])] {
                    clauses[clauses.count - 1].append(Syllable(character: String(chars[i]), numbered: s, spokenTone: s.last?.wholeNumberValue ?? 5))
                }
                i += 1
            }
        }
        return clauses.flatMap(applySandhi)
    }

    private static let ordinalContext: Set<String> = ["第", "十", "零", "一", "二", "三", "四", "五", "六", "七", "八", "九", "百", "千", "万", "周", "期"]

    private static func applySandhi(_ input: [Syllable]) -> [Syllable] {
        var s = input
        for i in s.indices {
            let next = i + 1 < s.count ? s[i + 1].dictionaryTone : nil
            if s[i].character == "不", s[i].dictionaryTone == 4, next == 4 {
                s[i].spokenTone = 2                      // 不是 bú shì
            }
            if s[i].character == "一", s[i].dictionaryTone == 1, let next {
                let prev = i > 0 ? s[i - 1].character : ""
                if !ordinalContext.contains(prev) {
                    if next == 4 || next == 5 { s[i].spokenTone = 2 }   // 一个 yí ge, 一样 yí yàng
                    else { s[i].spokenTone = 4 }                       // 一起 yì qǐ
                }
            }
        }
        // third tone before third tone becomes second: 你好 ní hǎo, 我也很好 wó yé hén hǎo
        var i = 0
        while i < s.count {
            guard s[i].spokenTone == 3 else { i += 1; continue }
            var j = i
            while j + 1 < s.count && s[j + 1].spokenTone == 3 { j += 1 }
            for k in i..<j { s[k].spokenTone = 2 }
            i = j + 1
        }
        return s
    }

    /// Pinyin of a sentence for display, with dictionary tones: "你好吗？" -> "nǐ hǎo ma?"
    static func romanize(_ text: String) -> String {
        let punctuation: [Character: String] = ["，": ",", "。": ".", "？": "?", "！": "!", "：": ":", "；": ";",
                                                "、": ",", "“": "\"", "”": "\"", "（": "(", "）": ")"]
        var out = ""
        var run = ""
        func flush() {
            guard !run.isEmpty else { return }
            let words = syllables(in: run).map(\.marked).joined(separator: " ")
            if !words.isEmpty {
                if let last = out.last, !last.isWhitespace, !"(\"".contains(last) { out += " " }
                out += words
            }
            run = ""
        }
        for c in text {
            if isHanzi(c) {
                run.append(c)
            } else {
                flush()
                if let p = punctuation[c] { out += p } else { out.append(c) }
            }
        }
        flush()
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// "hao3" -> "hǎo", "lv4" -> "lǜ", "ma5" -> "ma"
    static func marked(_ numbered: String) -> String {
        guard let tone = numbered.last?.wholeNumberValue else { return numbered }
        let base = Array(String(numbered.dropLast()).replacingOccurrences(of: "v", with: "ü"))
        guard (1...4).contains(tone) else { return String(base) }
        let marks: [Character: [Character]] = [
            "a": ["ā", "á", "ǎ", "à"], "e": ["ē", "é", "ě", "è"], "i": ["ī", "í", "ǐ", "ì"],
            "o": ["ō", "ó", "ǒ", "ò"], "u": ["ū", "ú", "ǔ", "ù"], "ü": ["ǖ", "ǘ", "ǚ", "ǜ"],
        ]
        let target: Int?
        if let a = base.firstIndex(where: { $0 == "a" || $0 == "e" }) {
            target = a
        } else if let o = base.indices.first(where: { base[$0] == "o" && $0 + 1 < base.count && base[$0 + 1] == "u" }) {
            target = o
        } else {
            target = base.lastIndex(where: { "iouü".contains($0) })
        }
        guard let t = target, let m = marks[base[t]] else { return String(base) }
        var out = base
        out[t] = m[tone - 1]
        return String(out)
    }
}
