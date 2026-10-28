import Foundation

/// The tone check of one syllable of the learner's sentence.
struct ToneCheck: Equatable, Identifiable, Sendable {
    enum Verdict: Equatable, Sendable {
        case good
        case wrong(heard: Int)
        case unclear
        case notJudged   // neutral tone
    }

    let id: Int
    let syllable: Pinyin.Syllable
    let verdict: Verdict

    static func toneName(_ tone: Int) -> String {
        switch tone {
        case 1: return "1st tone"
        case 2: return "2nd tone"
        case 3: return "3rd tone"
        case 4: return "4th tone"
        default: return "neutral tone"
        }
    }
}

enum ToneChecker {
    /// Compares the tones heard in the recording with the tones the transcript calls for.
    static func check(samples: [Float], sampleRate: Double, transcript: String) -> [ToneCheck] {
        let syllables = Pinyin.syllables(in: transcript)
        guard !syllables.isEmpty else { return [] }
        let heard = ToneAnalyzer.estimate(samples: samples, sampleRate: sampleRate, syllableCount: syllables.count)

        return syllables.enumerated().map { i, syl in
            let verdict: ToneCheck.Verdict
            if syl.spokenTone == 5 {
                verdict = .notJudged
            } else if i >= heard.count || heard[i].tone == 0 {
                verdict = .unclear
            } else if heard[i].tone == syl.spokenTone {
                verdict = .good
            } else if heard[i].margin >= ToneAnalyzer.confidentMargin {
                verdict = .wrong(heard: heard[i].tone)
            } else {
                verdict = .unclear
            }
            return ToneCheck(id: i, syllable: syl, verdict: verdict)
        }
    }
}
