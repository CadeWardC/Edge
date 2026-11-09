import AVFoundation
import Foundation

/// Every sound in Vanguard is synthesized at launch (noise, sine sweeps and envelopes), so there are no audio files.
/// A small pool of players handles effects; a generated ambient loop plays as music.
final class Sound {
    static let shared = Sound()

    enum Effect: Int, CaseIterable {
        case rifle, laser, rocket, cannon, boomSmall, boomBig, heal, click, ready, alert, built, capture, claw, error
    }

    private let engine = AVAudioEngine()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    private var buffers: [Effect: AVAudioPCMBuffer] = [:]
    private var players: [AVAudioPlayerNode] = []
    private var next = 0
    private let music = AVAudioPlayerNode()
    private var lastPlay: [Effect: TimeInterval] = [:]
    private var started = false
    private let queue = DispatchQueue(label: "vanguard.sound")

    var effectsVolume: Float { Float(UserDefaults.standard.object(forKey: "sfxVolume") as? Double ?? 0.8) }
    var musicVolume: Float { Float(UserDefaults.standard.object(forKey: "musicVolume") as? Double ?? 0.45) }

    /// Builds the sounds in the background and starts the engine.
    func start() {
        guard !started else { return }
        started = true
        queue.async { [self] in
            try? AVAudioSession.sharedInstance().setCategory(.ambient, options: [.mixWithOthers])
            try? AVAudioSession.sharedInstance().setActive(true)
            for e in Effect.allCases { buffers[e] = synth(e) }
            for _ in 0..<10 {
                let p = AVAudioPlayerNode()
                engine.attach(p)
                engine.connect(p, to: engine.mainMixerNode, format: format)
                players.append(p)
            }
            engine.attach(music)
            engine.connect(music, to: engine.mainMixerNode, format: format)
            do { try engine.start() } catch { return }
            for p in players { p.play() }
            let loop = musicLoop()
            music.scheduleBuffer(loop, at: nil, options: .loops)
            music.volume = musicVolume
            music.play()
        }
    }

    func updateVolumes() {
        queue.async { [self] in music.volume = musicVolume }
    }

    /// Plays an effect. `gain` scales it (e.g. distance from the camera). Repeats of the same effect are throttled.
    func play(_ e: Effect, gain: Float = 1) {
        guard started else { return }
        let now = Date().timeIntervalSince1970
        let gap: TimeInterval
        switch e {
        case .rifle, .laser, .claw: gap = 0.06
        case .boomBig, .alert: gap = 0.25
        default: gap = 0.1
        }
        if let last = lastPlay[e], now - last < gap { return }
        lastPlay[e] = now
        let vol = effectsVolume * gain
        guard vol > 0.01 else { return }
        queue.async { [self] in
            guard engine.isRunning, let b = buffers[e], !players.isEmpty else { return }
            let p = players[next]
            next = (next + 1) % players.count
            p.volume = vol
            p.scheduleBuffer(b, at: nil, options: .interrupts)
            if !p.isPlaying { p.play() }
        }
    }

    // MARK: synthesis

    private let rate = 44_100.0

    private func buffer(_ seconds: Double, _ sample: (Double, Int) -> Double) -> AVAudioPCMBuffer {
        let n = AVAudioFrameCount(seconds * rate)
        let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: n)!
        b.frameLength = n
        let d = b.floatChannelData![0]
        for i in 0..<Int(n) {
            d[i] = Float(max(-1, min(1, sample(Double(i) / rate, i))))
        }
        return b
    }

    private var seed: UInt64 = 0x1234_5678
    private func noise() -> Double {
        seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
        return Double(seed % 20_000) / 10_000 - 1
    }

    private func synth(_ e: Effect) -> AVAudioPCMBuffer {
        var lp = 0.0, lp2 = 0.0, phase = 0.0
        switch e {
        case .rifle:
            return buffer(0.09) { t, _ in
                let env = exp(-t * 55)
                lp += (self.noise() - lp) * 0.55
                return (lp * 0.8 + sin(t * 2 * .pi * 180) * 0.3) * env * 0.7
            }
        case .laser:
            return buffer(0.16) { t, _ in
                let f = 2200 - t * 9000
                phase += 2 * .pi * max(300, f) / self.rate
                return sin(phase) * exp(-t * 18) * 0.35
            }
        case .rocket:
            return buffer(0.35) { t, _ in
                lp += (self.noise() - lp) * 0.12
                let whoosh = lp * min(1, t * 20) * exp(-t * 7)
                return whoosh * 0.9 + sin(t * 2 * .pi * 90) * exp(-t * 25) * 0.4
            }
        case .cannon:
            return buffer(0.45) { t, _ in
                lp += (self.noise() - lp) * 0.08
                return (lp * 1.6 + sin(t * 2 * .pi * (70 - t * 40)) * 0.8) * exp(-t * 9) * 0.6
            }
        case .boomSmall:
            return buffer(0.6) { t, _ in
                lp += (self.noise() - lp) * 0.06
                return (lp * 2.2 + sin(t * 2 * .pi * 55) * exp(-t * 12) * 0.6) * exp(-t * 6) * 0.6
            }
        case .boomBig:
            return buffer(1.4) { t, _ in
                lp += (self.noise() - lp) * 0.035
                lp2 += (lp - lp2) * 0.2
                let rumble = sin(t * 2 * .pi * (45 - t * 10)) * exp(-t * 3)
                return (lp2 * 3.2 * exp(-t * 2.6) + rumble * 0.7) * 0.6
            }
        case .heal:
            return buffer(0.3) { t, _ in
                (sin(t * 2 * .pi * 880) + sin(t * 2 * .pi * 1320) * 0.6) * min(1, t * 40) * exp(-t * 10) * 0.18
            }
        case .click:
            return buffer(0.04) { t, _ in sin(t * 2 * .pi * 1800) * exp(-t * 120) * 0.3 }
        case .claw:
            return buffer(0.07) { t, _ in
                lp += (self.noise() - lp) * 0.8
                return lp * exp(-t * 60) * 0.25
            }
        case .ready:
            return buffer(0.3) { t, _ in
                let f = t < 0.12 ? 660.0 : 990.0
                let tt = t < 0.12 ? t : t - 0.12
                return sin(t * 2 * .pi * f) * min(1, tt * 60) * exp(-tt * 14) * 0.25
            }
        case .alert:
            return buffer(0.7) { t, _ in
                let f = Int(t / 0.175) % 2 == 0 ? 520.0 : 390.0
                let sq = sin(t * 2 * .pi * f) > 0 ? 1.0 : -1.0
                lp += (sq - lp) * 0.15
                return lp * 0.18 * min(1, (0.7 - t) * 10)
            }
        case .built:
            return buffer(0.55) { t, _ in
                let notes = [523.25, 659.25, 783.99, 1046.5]
                let k = min(3, Int(t / 0.11))
                let tt = t - Double(k) * 0.11
                return sin(t * 2 * .pi * notes[k]) * min(1, tt * 80) * exp(-tt * 6) * 0.2
            }
        case .capture:
            return buffer(0.6) { t, _ in
                (sin(t * 2 * .pi * 740) + sin(t * 2 * .pi * 1110) * 0.5 + sin(t * 2 * .pi * 1480) * 0.25) * exp(-t * 4) * 0.16
            }
        case .error:
            return buffer(0.18) { t, _ in
                let sq = sin(t * 2 * .pi * 160) > 0 ? 1.0 : -1.0
                lp += (sq - lp) * 0.2
                return lp * 0.15 * exp(-t * 8)
            }
        }
    }

    /// 24 s ambient loop: slow pad chords over a soft pulse.
    private func musicLoop() -> AVAudioPCMBuffer {
        let chords: [[Double]] = [[220.0, 261.63, 329.63], [174.61, 220.0, 261.63], [196.0, 246.94, 293.66], [164.81, 207.65, 246.94]]
        let bar = 6.0
        var lp = 0.0
        return buffer(bar * Double(chords.count)) { t, _ in
            let k = Int(t / bar) % chords.count
            let tb = t - Double(k) * bar
            let fade = min(1, tb / 1.2) * min(1, (bar - tb) / 1.2)
            var pad = 0.0
            for (i, f) in chords[k].enumerated() {
                let vib = 1 + 0.003 * sin(t * 2 * .pi * (0.3 + Double(i) * 0.11))
                pad += sin(t * 2 * .pi * f * vib) + 0.3 * sin(t * 2 * .pi * f * 2 * vib)
            }
            pad *= fade * 0.06
            // bass pulse on each beat
            let beat = tb.truncatingRemainder(dividingBy: 0.75)
            let bass = sin(t * 2 * .pi * chords[k][0] / 2) * exp(-beat * 5) * 0.12
            // soft hi-hat
            let hat = beat > 0.375 && beat < 0.42 ? self.noise() * exp(-(beat - 0.375) * 120) * 0.03 : 0
            lp += (pad + bass + hat - lp) * 0.5
            return lp
        }
    }
}
