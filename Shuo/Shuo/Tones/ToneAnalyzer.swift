import Accelerate
import Foundation

/// The tone heard in one syllable: 1-4, or 0 when there was no usable pitch.
/// `margin` is how much closer the best tone shape fit than the runner-up (bigger = surer).
struct ToneEstimate: Equatable, Sendable {
    let tone: Int
    let margin: Float
}

/// Pitch-based tone estimation: YIN pitch tracking, splitting the voiced audio into the expected
/// number of syllables, normalizing to the speaker's own range and matching tone shapes.
enum ToneAnalyzer {
    static let confidentMargin: Float = 0.35

    /// Tone shapes on a 1...5 scale of the speaker's range (Chao numbers), 5 points across a syllable.
    private static let templates: [(tone: Int, shape: [Float])] = [
        (1, [4.3, 4.3, 4.3, 4.3, 4.3]),
        (2, [2.8, 2.9, 3.4, 4.0, 4.6]),
        (3, [2.4, 1.7, 1.2, 1.3, 2.2]),   // full dip
        (3, [2.2, 1.7, 1.3, 1.2, 1.2]),   // half third, the usual form mid-sentence
        (4, [4.8, 4.3, 3.4, 2.5, 1.7]),
    ]

    static func estimate(samples: [Float], sampleRate: Double, syllableCount: Int) -> [ToneEstimate] {
        guard syllableCount > 0 else { return [] }
        let (f0, db) = trackPitch(samples, sampleRate: Float(sampleRate))
        guard let maxDB = db.max() else { return [] }
        let voiced = zip(f0, db).map { $0 > 0 && $1 > maxDB - 35 }
        guard voiced.filter({ $0 }).count >= 5 else { return [] }

        // semitones, then the speaker's 5th..95th percentile range mapped to roughly 1...5
        let semitones = f0.map { $0 > 0 ? 12 * log2($0 / 100) : 0 }
        let voicedST = zip(semitones, voiced).filter { $0.1 }.map { $0.0 }.sorted()
        let lo = voicedST[Int(Float(voicedST.count - 1) * 0.05)]
        let hi = voicedST[Int(Float(voicedST.count - 1) * 0.95)]
        let span = max(hi - lo, 4)   // a monotone speaker is not stretched into fake tones
        let mid = (lo + hi) / 2
        let scale = semitones.map { 3 + ($0 - mid) / span * 4 }

        return segment(voiced: voiced, energy: db, count: syllableCount).map { range in
            var idx = range.filter { voiced[$0] }
            let trim = idx.count / 10   // skip onsets and offsets
            if idx.count - 2 * trim >= 3 { idx = Array(idx[trim..<(idx.count - trim)]) }
            var contour = idx.map { scale[$0] }
            guard contour.count >= 3 else { return ToneEstimate(tone: 0, margin: 0) }
            if contour.count >= 5 { contour = medianSmoothed(contour) }
            return classify(contour)
        }
    }

    // MARK: Pitch

    /// Per 10 ms frame: f0 in Hz (0 = unvoiced) and energy in dB.
    private static func trackPitch(_ x: [Float], sampleRate sr: Float) -> (f0: [Float], db: [Float]) {
        let hop = Int(sr * 0.010), win = Int(sr * 0.032)
        let tauMin = Int(sr / 450), tauMax = Int(sr / 70)
        guard x.count > win + tauMax + hop else { return ([], []) }
        let n = 1 + (x.count - win - tauMax) / hop

        var f0 = [Float](repeating: 0, count: n)
        var db = [Float](repeating: 0, count: n)
        var d = [Float](repeating: 0, count: tauMax + 1)
        var cmnd = [Float](repeating: 1, count: tauMax + 1)
        let len = vDSP_Length(win)

        x.withUnsafeBufferPointer { buf in
            for i in 0..<n {
                let s = buf.baseAddress! + i * hop
                var e0: Float = 0
                vDSP_dotpr(s, 1, s, 1, &e0, len)
                db[i] = 10 * log10(e0 / Float(win) + 1e-12)

                // cumulative mean normalized difference function
                var running: Float = 0
                for tau in 1...tauMax {
                    var cross: Float = 0, et: Float = 0
                    vDSP_dotpr(s, 1, s + tau, 1, &cross, len)
                    vDSP_dotpr(s + tau, 1, s + tau, 1, &et, len)
                    d[tau] = e0 + et - 2 * cross
                    running += d[tau]
                    cmnd[tau] = running > 0 ? d[tau] * Float(tau) / running : 1
                }

                var tau = 0
                var t = tauMin
                while t < tauMax {
                    if cmnd[t] < 0.15 {
                        while t + 1 < tauMax && cmnd[t + 1] < cmnd[t] { t += 1 }
                        tau = t
                        break
                    }
                    t += 1
                }
                guard tau > 0 else { continue }
                let a = cmnd[tau - 1], b = cmnd[tau], c = cmnd[tau + 1]
                let den = a - 2 * b + c
                let shift = abs(den) > 1e-12 ? 0.5 * (a - c) / den : 0
                f0[i] = sr / (Float(tau) + shift)
            }
        }
        return (f0, db)
    }

    // MARK: Syllables

    /// Voiced runs, merged across the shortest gaps or split at energy dips until there are `count`.
    private static func segment(voiced: [Bool], energy: [Float], count: Int) -> [Range<Int>] {
        var runs: [Range<Int>] = []
        var start: Int?
        for (i, v) in (voiced + [false]).enumerated() {
            if v, start == nil {
                start = i
            } else if !v, let s = start {
                if i - s >= 4 { runs.append(s..<i) }
                start = nil
            }
        }
        guard !runs.isEmpty else { return [] }

        while runs.count > count {
            var k = 0
            for j in 0..<(runs.count - 1) where runs[j + 1].lowerBound - runs[j].upperBound < runs[k + 1].lowerBound - runs[k].upperBound {
                k = j
            }
            runs[k] = runs[k].lowerBound..<runs[k + 1].upperBound
            runs.remove(at: k + 1)
        }
        while runs.count < count {
            let k = runs.indices.max { runs[$0].count < runs[$1].count }!
            let r = runs[k]
            guard r.count >= 10 else { break }
            let lo = r.lowerBound + r.count / 5, hi = r.upperBound - r.count / 5
            let smooth = movingAverage(Array(energy[r]), width: 5)
            var cut = lo
            for i in lo..<hi where smooth[i - r.lowerBound] < smooth[cut - r.lowerBound] { cut = i }
            runs.replaceSubrange(k...k, with: [r.lowerBound..<cut, cut..<r.upperBound])
        }
        return runs
    }

    private static func movingAverage(_ v: [Float], width: Int) -> [Float] {
        let h = width / 2
        return v.indices.map { i in
            var sum: Float = 0
            for j in (i - h)...(i + h) where v.indices.contains(j) { sum += v[j] }
            return sum / Float(width)
        }
    }

    private static func medianSmoothed(_ v: [Float]) -> [Float] {
        v.indices.map { i in
            let w = v[max(0, i - 2)..<min(v.count, i + 3)].sorted()
            return w[w.count / 2]
        }
    }

    // MARK: Tone shapes

    private static func classify(_ contour: [Float]) -> ToneEstimate {
        let pts: [Float] = (0..<5).map { k in
            let pos = Float(k) / 4 * Float(contour.count - 1)
            let i = min(Int(pos), contour.count - 2)
            let f = pos - Float(i)
            return contour[i] * (1 - f) + contour[i + 1] * f
        }
        var best: [Int: Float] = [:]
        for (tone, shape) in templates {
            let mse = zip(pts, shape).map { ($0 - $1) * ($0 - $1) }.reduce(0, +) / 5
            best[tone] = min(best[tone] ?? .infinity, mse.squareRoot())
        }
        let ranked = best.sorted { $0.value < $1.value }
        return ToneEstimate(tone: ranked[0].key, margin: ranked[1].value - ranked[0].value)
    }
}
