import Foundation

/// Turns English text into Kokoro's phonemes (misaki's US lexicon, the one sherpa-onnx ships as lexicon-us-en.txt).
///
/// sherpa-onnx 2.x has no espeak-ng any more and silently skips words that are not in the lexicon, which would
/// drop most of a paper's jargon. So the app phonemizes the text itself and hands Kokoro the phonemes:
/// lexicon words as they are, then inflections (-s, -ed, -ing, ...), then compounds of known words and
/// common prefixes and suffixes ("nano" + "particles"), acronyms letter by letter, and finally spelling rules.
final class EnglishPhonemizer: @unchecked Sendable {
    /// Kokoro reads at most about 510 tokens at once; longer sentences are split at commas or spaces.
    static let maxPhonemesPerChunk = 360

    private let lexicon: [String: String]

    init(lexiconURL: URL) throws {
        let text = try String(contentsOf: lexiconURL, encoding: .utf8)
        var lex: [String: String] = [:]
        lex.reserveCapacity(180_000)
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let space = line.firstIndex(of: " ") else { continue }
            let key = String(line[..<space])
            let phones = String(line[line.index(after: space)...].filter { $0 != " " })
            if !phones.isEmpty { lex[key] = phones }
        }
        lexicon = lex
    }

    // MARK: Sentences

    /// The phonemes of `text`, one chunk per sentence (long sentences are split).
    func phonemize(_ text: String) -> [String] {
        let normalized = SpokenText.normalize(text)
        var chunks: [String] = []
        for sentence in SpokenText.sentences(normalized) {
            let phonemes = phonemizeSentence(sentence)
            guard phonemes.contains(where: { $0.isLetter }) else { continue }
            chunks += Self.split(phonemes)
        }
        return chunks
    }

    private func phonemizeSentence(_ sentence: String) -> String {
        var out = ""
        var word = ""
        func flushWord() {
            guard !word.isEmpty else { return }
            let trimmed = word.trimmingCharacters(in: CharacterSet(charactersIn: "'-"))
            if !trimmed.isEmpty {
                let p = phonemes(forWord: trimmed)
                if !p.isEmpty {
                    if !out.isEmpty && !out.hasSuffix(" ") { out += " " }
                    out += p
                }
            }
            word = ""
        }
        for ch in sentence {
            if ch.isLetter || ch.isNumber || ch == "'" || ch == "-" {
                word.append(ch)
            } else {
                flushWord()
                switch ch {
                case ",", ";", ":", ".", "!", "?":
                    if !out.isEmpty { out = out.trimmingCharacters(in: .whitespaces) + String(ch) + " " }
                case "(", ")", "[", "]", "—", "–":
                    if !out.isEmpty && !out.trimmingCharacters(in: .whitespaces).hasSuffix(",") {
                        out = out.trimmingCharacters(in: .whitespaces) + ", "
                    }
                default:
                    if !out.isEmpty && !out.hasSuffix(" ") { out += " " }
                }
            }
        }
        flushWord()
        var result = out.trimmingCharacters(in: .whitespaces)
        while result.hasPrefix(",") { result = String(result.dropFirst()).trimmingCharacters(in: .whitespaces) }
        if let last = result.last, !".!?".contains(last) {
            if last == "," || last == ";" || last == ":" { result.removeLast() }
            result += "."
        }
        return result
    }

    /// Splits a long phoneme sentence at commas, then at spaces, so each piece fits in Kokoro's window.
    private static func split(_ phonemes: String) -> [String] {
        guard phonemes.unicodeScalars.count > maxPhonemesPerChunk else { return [phonemes] }
        var pieces: [String] = []
        var current = ""
        let clauses = phonemes.components(separatedBy: ", ")
        for (i, clause) in clauses.enumerated() {
            let part = clause + (i < clauses.count - 1 ? "," : "")
            if current.unicodeScalars.count + part.unicodeScalars.count + 1 > maxPhonemesPerChunk, !current.isEmpty {
                pieces.append(current)
                current = ""
            }
            current += (current.isEmpty ? "" : " ") + part
        }
        if !current.isEmpty { pieces.append(current) }
        // a single clause can still be too long: cut it at spaces
        return pieces.flatMap { piece -> [String] in
            guard piece.unicodeScalars.count > maxPhonemesPerChunk else { return [piece] }
            var out: [String] = []
            var line = ""
            for w in piece.split(separator: " ") {
                if line.unicodeScalars.count + w.unicodeScalars.count + 1 > maxPhonemesPerChunk, !line.isEmpty {
                    out.append(line)
                    line = ""
                }
                line += (line.isEmpty ? "" : " ") + String(w)
            }
            if !line.isEmpty { out.append(line) }
            return out
        }
    }

    // MARK: Words

    func phonemes(forWord token: String) -> String {
        let w = token.lowercased()
        let uppercase = token.filter(\.isUppercase).count
        // all-caps words that are also common words ("WHO", "US", "IT") are acronyms
        if uppercase >= 2, uppercase == token.filter(\.isLetter).count, Self.commonWords.contains(w) {
            return spell(token)
        }
        if let p = known(w) { return p }
        if w.contains("-") {
            let parts = token.split(separator: "-").map { phonemes(forWord: String($0)) }.filter { !$0.isEmpty }
            return Self.joinCompound(parts)
        }
        // "LLMs", "GPUs"
        if token.hasSuffix("s"), uppercase >= 2, token.dropLast().allSatisfy({ $0.isUppercase || $0.isNumber }) {
            return suffixS(spell(String(token.dropLast())))
        }
        // "PubMed", "mRNA", "GitHub": read each part
        if uppercase >= 2, token.contains(where: \.isLowercase) {
            let parts = Self.camelParts(token)
            if parts.count >= 2 { return Self.joinCompound(parts.map(phonemes(forWord:)).filter { !$0.isEmpty }) }
        }
        if uppercase >= 2 || (w.count <= 3 && !w.contains(where: { "aeiouy".contains($0) })) {
            return spell(token)
        }
        if w.contains(where: \.isNumber) {
            // digits are spelled out by SpokenText; anything left is read digit by digit
            return Self.joinCompound(w.map { ch -> String in
                if let d = ch.wholeNumberValue { return lookup(SpokenText.digitWords[d]) ?? "" }
                return known(String(ch)) ?? ""
            }.filter { !$0.isEmpty })
        }
        return compound(w) ?? rules(w)
    }

    private func known(_ w: String) -> String? {
        if let p = Self.userWords[w] ?? lexicon[w] { return p }
        return morph(w)
    }

    private func lookup(_ w: String) -> String? {
        Self.userWords[w] ?? lexicon[w]
    }

    /// Regular inflections of lexicon words.
    private func morph(_ w: String) -> String? {
        func stem(_ n: Int) -> String { String(w.dropLast(n)) }
        let count = w.count
        if w.hasSuffix("'s"), let p = lookup(stem(2)) { return suffixS(p) }
        if w.hasSuffix("s'"), count > 3 { return known(stem(1)) }
        if w.hasSuffix("ies"), count > 4, let p = lookup(stem(3) + "y") { return suffixS(p) }
        if w.hasSuffix("es"), count > 3, let p = lookup(stem(2)), "sxzh".contains(w.dropLast(2).last ?? " ") {
            return p + "ɪz"
        }
        if w.hasSuffix("s"), !w.hasSuffix("ss"), count > 2, let p = lookup(stem(1)) { return suffixS(p) }
        if w.hasSuffix("ied"), count > 4, let p = lookup(stem(3) + "y") { return p + "d" }
        if w.hasSuffix("ed"), count > 3 {
            if let p = lookup(stem(2)) ?? lookup(stem(1)) { return suffixED(p) }
            if count > 4, Array(w)[count - 3] == Array(w)[count - 4], let p = lookup(stem(3)) { return suffixED(p) }
        }
        if w.hasSuffix("ing"), count > 4 {
            if let p = lookup(stem(3)) ?? lookup(stem(3) + "e") { return p + "ɪŋ" }
            if count > 5, Array(w)[count - 4] == Array(w)[count - 5], let p = lookup(stem(4)) { return p + "ɪŋ" }
        }
        if w.hasSuffix("ly"), count > 3, let p = lookup(stem(2)) { return p + "li" }
        if w.hasSuffix("ers"), count > 4, let p = lookup(stem(3)) { return p + "əɹz" }
        if w.hasSuffix("er"), count > 3, let p = lookup(stem(2)) { return p + "əɹ" }
        return nil
    }

    /// Fewest pieces: known words of three or more letters, a prefix at the start and a suffix at the end.
    private func compound(_ w: String) -> String? {
        let chars = Array(w)
        let n = chars.count
        guard n >= 5 else { return nil }
        var best: [(cost: Int, parts: [String])?] = Array(repeating: nil, count: n + 1)
        best[0] = (0, [])
        for i in 0..<n {
            guard let here = best[i], here.cost < 3 else { continue }
            for j in (i + 1)...n {
                let piece = String(chars[i..<j])
                var found: String? = j - i >= 3 ? known(piece) : nil
                if found == nil, i == 0, j < n { found = Self.prefixes[piece] }
                if found == nil, j == n, i > 0 { found = Self.suffixes[piece] }
                guard let p = found else { continue }
                if best[j] == nil || here.cost + 1 < best[j]!.cost {
                    best[j] = (here.cost + 1, here.parts + [p])
                }
            }
        }
        guard let done = best[n], done.parts.count >= 2 else { return nil }
        return Self.joinCompound(done.parts)
    }

    /// Splits "PubMed" into "Pub" "Med", "mRNA" into "m" "RNA" and "XMLHttp" into "XML" "Http".
    private static func camelParts(_ token: String) -> [String] {
        let chars = Array(token)
        var parts: [String] = []
        var current = ""
        for (i, ch) in chars.enumerated() {
            if i > 0, ch.isUppercase {
                let prev = chars[i - 1]
                let nextIsLower = i + 1 < chars.count && chars[i + 1].isLowercase
                if prev.isLowercase || (prev.isUppercase && nextIsLower) {
                    parts.append(current)
                    current = ""
                }
            }
            current.append(ch)
        }
        parts.append(current)
        return parts.filter { !$0.isEmpty }
    }

    /// Keeps the first primary stress and turns the others into secondary ones.
    private static func joinCompound(_ parts: [String]) -> String {
        var out = ""
        var hasPrimary = false
        for part in parts {
            if hasPrimary {
                out += part.replacingOccurrences(of: "ˈ", with: "ˌ")
            } else {
                out += part
                hasPrimary = part.contains("ˈ")
            }
        }
        return out
    }

    private func spell(_ token: String) -> String {
        var parts = token.lowercased().compactMap { ch -> String? in
            if let d = ch.wholeNumberValue { return lexicon[SpokenText.digitWords[d]] }
            return Self.letters[ch]
        }.map { $0.replacingOccurrences(of: "ˈ", with: "ˌ") }
        guard !parts.isEmpty else { return "" }
        let last = parts.removeLast()
        let stressed = last.contains("ˌ") ? last.replacingOccurrences(of: "ˌ", with: "ˈ") : "ˈ" + last
        return parts.joined() + stressed
    }

    private func suffixS(_ p: String) -> String {
        let last = p.unicodeScalars.reversed().first { $0 != "ˈ" && $0 != "ˌ" }.map { Character($0) }
        if let last, "szʃʒʧʤ".contains(last) { return p + "ɪz" }
        if let last, "ptkfθ".contains(last) { return p + "s" }
        return p + "z"
    }

    private func suffixED(_ p: String) -> String {
        guard let last = p.last else { return p + "d" }
        if "td".contains(last) { return p + "ɪd" }
        if "pkfθsʃʧ".contains(last) { return p + "t" }
        return p + "d"
    }

    /// Last resort: rough English spelling rules, stressed on the first vowel.
    private func rules(_ w: String) -> String {
        let chars = Array(w)
        var out = ""
        var i = 0
        while i < chars.count {
            let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
            if chars[i] == "c", let next, "eiy".contains(next) { out += "s"; i += 1; continue }
            if chars[i] == "g", i > 0, let next, "eiy".contains(next) { out += "ʤ"; i += 1; continue }
            if chars[i] == "e", i == chars.count - 1, i > 1 { i += 1; continue }   // silent final e
            var matched = false
            for (graph, phone) in Self.spellingRules where graph.count <= chars.count - i {
                if String(chars[i..<(i + graph.count)]) == graph {
                    out += phone
                    i += graph.count
                    matched = true
                    break
                }
            }
            if !matched { i += 1 }
        }
        if let first = out.firstIndex(where: { Self.vowelPhones.contains($0) }) {
            out.insert("ˈ", at: first)
        }
        return out
    }

    // MARK: Tables

    private static let commonWords: Set<String> = [
        "us", "who", "it", "am", "or", "as", "at", "an", "in", "on", "to", "no", "so", "do", "go", "me", "we",
        "he", "be", "by", "my", "up", "if", "of", "is", "all", "can", "may", "and", "not", "the", "aids", "cat", "pet",
    ]

    /// Words the lexicon lacks that papers use a lot.
    private static let userWords: [String: String] = [
        "a": "ə", "the": "ðə",
        "arxiv": "ˈɑɹkˌIv", "covid": "kˈOvɪd", "github": "ɡˈɪthˌʌb", "pytorch": "pˈItˌɔɹʧ", "et": "ˈɛt",
        "biorxiv": "bˌIOˈɑɹkˌIv", "medrxiv": "mˌɛdˈɑɹkˌIv", "softmax": "sˈɔftmˌæks", "dataset": "dˈAɾəsˌɛt",
    ]

    private static let letters: [Character: String] = [
        "a": "ˈA", "b": "bˈi", "c": "sˈi", "d": "dˈi", "e": "ˈi", "f": "ˈɛf", "g": "ʤˈi", "h": "ˈAʧ",
        "i": "ˈI", "j": "ʤˈA", "k": "kˈA", "l": "ˈɛl", "m": "ˈɛm", "n": "ˈɛn", "o": "ˈO", "p": "pˈi",
        "q": "kjˈu", "r": "ˈɑɹ", "s": "ˈɛs", "t": "tˈi", "u": "jˈu", "v": "vˈi", "w": "dˈʌbᵊljˌu",
        "x": "ˈɛks", "y": "wˈI", "z": "zˈi",
    ]

    private static let prefixes: [String: String] = [
        "pre": "pɹˌi", "re": "ɹˌi", "un": "ˌʌn", "non": "nˌɑn", "multi": "mˌʌlti", "co": "kˌO", "sub": "sˌʌb",
        "anti": "ˌænti", "inter": "ˌɪntəɹ", "hyper": "hˌIpəɹ", "micro": "mˌIkɹO", "nano": "nˌænO", "bio": "bˌIO",
        "auto": "ˌɔɾO", "meta": "mˌɛɾə", "neuro": "nˌʊɹO", "over": "ˌOvəɹ", "under": "ˌʌndəɹ", "self": "sˌɛlf",
        "semi": "sˌɛmi", "de": "dˌi", "dis": "dˌɪs", "mis": "mˌɪs", "post": "pˌOst", "trans": "tɹˌænz",
        "electro": "ɪlˌɛktɹO", "photo": "fˌOɾO", "thermo": "θˌɜɹmO", "cyto": "sˌIɾO", "immuno": "ˌɪmjənO",
    ]

    private static let suffixes: [String: String] = [
        "izer": "ˌIzəɹ", "izers": "ˌIzəɹz", "ize": "ˌIz", "ized": "ˌIzd", "izes": "ˌIzɪz", "izing": "ˌIzɪŋ",
        "ization": "ɪzˈAʃən", "able": "əbᵊl", "ability": "əbˈɪlɪɾi", "ness": "nəs", "ment": "mənt",
        "ments": "mənts", "less": "ləs", "ful": "fəl", "ity": "ɪɾi", "al": "ᵊl", "ally": "ᵊli", "ic": "ɪk",
        "ics": "ɪks", "ism": "ˌɪzəm", "ist": "ɪst", "ists": "ɪsts", "wise": "wˌIz", "like": "lˌIk",
        "based": "bˌAst", "omics": "ˈOmɪks", "ome": "ˌOm", "s": "z", "es": "ɪz", "ed": "d", "ing": "ɪŋ",
        "er": "əɹ", "ers": "əɹz", "ly": "li",
    ]

    /// Longest graphemes first.
    private static let spellingRules: [(String, String)] = [
        ("tion", "ʃən"), ("sion", "ʒən"), ("ture", "ʧəɹ"), ("ph", "f"), ("th", "θ"), ("sh", "ʃ"), ("ch", "k"),
        ("ck", "k"), ("ng", "ŋ"), ("qu", "kw"), ("ee", "i"), ("ea", "i"), ("oo", "u"), ("ou", "W"), ("ow", "O"),
        ("ai", "A"), ("ay", "A"), ("oa", "O"), ("oi", "Y"), ("oy", "Y"), ("au", "ɔ"), ("aw", "ɔ"), ("ie", "i"),
        ("ei", "A"), ("ey", "i"), ("er", "əɹ"), ("ar", "ɑɹ"), ("or", "ɔɹ"), ("ir", "ɜɹ"), ("ur", "ɜɹ"),
        ("a", "æ"), ("e", "ɛ"), ("i", "ɪ"), ("o", "ɑ"), ("u", "ʌ"), ("y", "i"), ("b", "b"), ("c", "k"),
        ("d", "d"), ("f", "f"), ("g", "ɡ"), ("h", "h"), ("j", "ʤ"), ("k", "k"), ("l", "l"), ("m", "m"),
        ("n", "n"), ("p", "p"), ("q", "k"), ("r", "ɹ"), ("s", "s"), ("t", "t"), ("v", "v"), ("w", "w"),
        ("x", "ks"), ("z", "z"),
    ]

    private static let vowelPhones: Set<Character> = ["æ", "ɛ", "ɪ", "ɑ", "ʌ", "i", "u", "W", "O", "A", "Y", "ɔ", "ə", "ɜ"]
}
