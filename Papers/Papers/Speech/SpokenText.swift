import Foundation

/// Rewrites written English into words a voice can read: numbers, symbols, units and abbreviations.
enum SpokenText {
    static let digitWords = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine"]

    static func normalize(_ text: String) -> String {
        var s = text
        // typography
        for (from, to) in [("’", "'"), ("‘", "'"), ("“", "\""), ("”", "\""), ("…", "."), ("\u{00A0}", " "),
                           ("ﬁ", "fi"), ("ﬂ", "fl"), ("−", "-")] {
            s = s.replacingOccurrences(of: from, with: to)
        }
        // abbreviations
        for (pattern, spoken) in [
            ("\\be\\.g\\.,?", "for example,"), ("\\bi\\.e\\.,?", "that is,"), ("\\bet al\\.", "and colleagues"),
            ("\\bvs\\.?(?=\\s)", "versus"), ("\\bFigs?\\.", "figure"), ("\\bapprox\\.", "approximately"),
            ("\\betc\\.", "et cetera"), ("\\bDr\\.", "Doctor"), ("\\bNo\\.(?=\\s*\\d)", "number"),
            ("\\bca\\.(?=\\s*\\d)", "about"), ("\\bEq\\.", "equation"), ("\\bSec\\.", "section"),
        ] {
            s = replace(s, pattern) { _ in spoken }
        }
        // money, before numbers are spelled out
        s = replace(s, "\\$\\s?(\\d[\\d,]*(?:\\.\\d+)?)(\\s?(?:thousand|million|billion|trillion))?") { m in
            "\(m[1])\(m[2]) dollars"
        }
        // thousands separators
        var previous = ""
        while previous != s {
            previous = s
            s = replace(s, "(\\d),(\\d{3})(?!\\d)") { m in m[1] + m[2] }
        }
        // number ranges: "10-20", "2019–2021"
        s = replace(s, "(\\d)\\s?[–-]\\s?(\\d)") { m in "\(m[1]) to \(m[2])" }
        // "3x faster", "2 × 3"
        s = replace(s, "(\\d)\\s?[x×](?=\\s|$)") { m in "\(m[1]) times" }
        // symbols
        for (from, to) in [("%", " percent"), ("±", " plus or minus "), ("≈", " about "), ("~", " about "),
                           ("×", " times "), ("&", " and "), ("≤", " at most "), ("≥", " at least "),
                           ("<", " less than "), (">", " more than "), ("=", " equals "), ("+", " plus "),
                           ("°C", " degrees Celsius"), ("°F", " degrees Fahrenheit"), ("°", " degrees"),
                           ("/", " "), ("@", " at "), ("#", " number ")] {
            s = s.replacingOccurrences(of: from, with: to)
        }
        for (letter, name) in greek {
            s = s.replacingOccurrences(of: letter, with: " \(name) ")
        }
        // ordinals: 1st, 22nd, 3rd, 4th
        s = replace(s, "\\b(\\d+)(st|nd|rd|th)\\b") { m in ordinal(cardinal(Int(m[1]) ?? 0)) }
        // decimals: 3.14 -> three point one four
        s = replace(s, "(\\d+)\\.(\\d+)") { m in
            cardinal(Int(m[1]) ?? 0) + " point " + m[2].compactMap { $0.wholeNumberValue.map { digitWords[$0] } }.joined(separator: " ")
        }
        // a negative number
        s = replace(s, "(^|[\\s(])-(\\d)") { m in "\(m[1])minus \(m[2])" }
        // digits stuck to letters: "Cas9", "CO2", "COVID-19" stay readable as "Cas 9"
        s = replace(s, "([A-Za-z])(\\d)") { m in "\(m[1]) \(m[2])" }
        s = replace(s, "(\\d)([A-Za-z])") { m in "\(m[1]) \(m[2])" }
        // years and other numbers
        s = replace(s, "\\d+") { m in
            let digits = m[0]
            if digits.count > 1, digits.hasPrefix("0") || digits.count > 12 {
                return digits.compactMap { $0.wholeNumberValue.map { digitWords[$0] } }.joined(separator: " ")
            }
            let n = Int(digits) ?? 0
            if digits.count == 4, (1100...2099).contains(n) { return year(n) }
            return cardinal(n)
        }
        // collapse spaces
        s = replace(s, "[ \\t]{2,}") { _ in " " }
        return s
    }

    /// Splits text into sentences at . ! ? followed by a space and a capital letter or a new line, and at line breaks.
    static func sentences(_ text: String) -> [String] {
        var out: [String] = []
        for paragraph in text.components(separatedBy: .newlines) {
            let p = paragraph.trimmingCharacters(in: .whitespaces)
            guard !p.isEmpty else { continue }
            var current = ""
            let chars = Array(p)
            for (i, ch) in chars.enumerated() {
                current.append(ch)
                guard ".!?".contains(ch) else { continue }
                let rest = chars[(i + 1)...].drop(while: { $0 == " " || $0 == "\"" || $0 == ")" })
                let atBoundary = i + 1 < chars.count && chars[i + 1] == " "
                if rest.isEmpty || (atBoundary && (rest.first?.isUppercase ?? false)) {
                    out.append(current.trimmingCharacters(in: .whitespaces))
                    current = ""
                }
            }
            let tail = current.trimmingCharacters(in: .whitespaces)
            if !tail.isEmpty { out.append(tail) }
        }
        return out
    }

    // MARK: Numbers

    private static let ones = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
                               "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen",
                               "eighteen", "nineteen"]
    private static let tens = ["", "ten", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]

    static func cardinal(_ number: Int) -> String {
        guard number != 0 else { return "zero" }
        func under1000(_ value: Int) -> [String] {
            var n = value
            var r: [String] = []
            if n >= 100 {
                r += [ones[n / 100], "hundred"]
                n %= 100
            }
            if n >= 20 {
                r.append(tens[n / 10] + (n % 10 > 0 ? "-" + ones[n % 10] : ""))
            } else if n > 0 {
                r.append(ones[n])
            }
            return r
        }
        var n = number
        var words: [String] = []
        for (value, name) in [(1_000_000_000_000, "trillion"), (1_000_000_000, "billion"), (1_000_000, "million"), (1000, "thousand")] where n >= value {
            words += under1000(n / value) + [name]
            n %= value
        }
        words += under1000(n)
        return words.joined(separator: " ")
    }

    /// 1999 -> nineteen ninety-nine, 2005 -> two thousand five, 2023 -> twenty twenty-three, 1900 -> nineteen hundred.
    static func year(_ y: Int) -> String {
        if (2000...2009).contains(y) { return cardinal(y) }
        let high = y / 100, low = y % 100
        if low == 0 { return cardinal(high) + " hundred" }
        if low < 10 { return cardinal(high) + " oh " + ones[low] }
        return cardinal(high) + " " + cardinal(low)
    }

    static func ordinal(_ words: String) -> String {
        var parts = words.components(separatedBy: " ")
        guard let last = parts.popLast() else { return words }
        var pieces = last.components(separatedBy: "-")
        let word = pieces.removeLast()
        let irregular = ["one": "first", "two": "second", "three": "third", "five": "fifth", "eight": "eighth",
                         "nine": "ninth", "twelve": "twelfth"]
        let ord: String
        if let irr = irregular[word] {
            ord = irr
        } else if word.hasSuffix("y") {
            ord = String(word.dropLast()) + "ieth"
        } else {
            ord = word + "th"
        }
        pieces.append(ord)
        parts.append(pieces.joined(separator: "-"))
        return parts.joined(separator: " ")
    }

    private static let greek: [(String, String)] = [
        ("α", "alpha"), ("β", "beta"), ("γ", "gamma"), ("δ", "delta"), ("Δ", "delta"), ("ε", "epsilon"),
        ("θ", "theta"), ("λ", "lambda"), ("μ", "micro"), ("µ", "micro"), ("π", "pi"), ("ρ", "rho"),
        ("σ", "sigma"), ("Σ", "sigma"), ("τ", "tau"), ("φ", "phi"), ("χ", "chi"), ("ψ", "psi"), ("ω", "omega"),
        ("Ω", "ohm"),
    ]

    // MARK: Regex

    /// Replaces every match of `pattern`; `transform` gets the match and its groups (missing groups are "").
    static func replace(_ text: String, _ pattern: String, _ transform: ([String]) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        var result = ""
        var last = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            let groups = (0..<match.numberOfRanges).map { i -> String in
                let r = match.range(at: i)
                return r.location == NSNotFound ? "" : ns.substring(with: r)
            }
            result += transform(groups)
            last = match.range.location + match.range.length
        }
        result += ns.substring(from: last)
        return result
    }
}
