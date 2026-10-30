import AVFoundation
import MediaPlayer
import UIKit

/// Plays a paper's summary, with Lock Screen controls, chapters and playback speed. Remembers where you stopped.
@MainActor
final class SummaryPlayer: ObservableObject {
    static let shared = SummaryPlayer()
    static let speeds: [Float] = [0.8, 1.0, 1.2, 1.4, 1.6, 1.8, 2.0]

    @Published private(set) var paperID: UUID?
    @Published private(set) var isPlaying = false
    @Published private(set) var position: Double = 0
    @Published private(set) var duration: Double = 0
    @Published var speed: Float = {
        let s = UserDefaults.standard.float(forKey: "playbackSpeed")
        return s > 0 ? s : 1.0
    }() {
        didSet {
            UserDefaults.standard.set(speed, forKey: "playbackSpeed")
            if isPlaying { player.rate = speed }
            updateNowPlaying()
        }
    }

    private let player = AVPlayer()
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var lastSaved: Double = 0
    private var title = ""

    private init() {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
                                                      queue: .main) { time in
            MainActor.assumeIsolated { SummaryPlayer.shared.tick(time.seconds) }
        }
        setUpRemoteCommands()
    }

    /// Loads a paper's audio (at its saved position) without starting it.
    func load(_ paper: Paper) {
        guard paper.id != paperID else { return }
        savePosition()
        let url = Library.audioURL(paper.id)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let item = AVPlayerItem(url: url)
        item.audioTimePitchAlgorithm = .timeDomain
        player.replaceCurrentItem(with: item)
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item,
                                                             queue: .main) { _ in
            MainActor.assumeIsolated { SummaryPlayer.shared.finished() }
        }
        paperID = paper.id
        title = paper.displayTitle
        duration = paper.duration ?? 0
        let start = paper.playbackPosition < max(duration - 2, 0) ? paper.playbackPosition : 0
        position = start
        player.seek(to: CMTime(seconds: start, preferredTimescale: 600))
        isPlaying = false
        updateNowPlaying()
    }

    func play(_ paper: Paper) {
        load(paper)
        play()
    }

    func play() {
        guard player.currentItem != nil else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        player.playImmediately(atRate: speed)
        isPlaying = true
        Library.shared.update(paperID ?? UUID()) { $0.lastPlayed = Date() }
        updateNowPlaying()
    }

    func pause() {
        player.pause()
        isPlaying = false
        savePosition()
        updateNowPlaying()
    }

    func toggle() {
        isPlaying ? pause() : play()
    }

    func seek(to seconds: Double) {
        let t = min(max(seconds, 0), max(duration - 0.1, 0))
        position = t
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        savePosition()
        updateNowPlaying()
    }

    func skip(_ seconds: Double) {
        seek(to: position + seconds)
    }

    /// Stops and forgets the paper (when it is deleted or its audio is made again).
    func unload(_ id: UUID) {
        guard paperID == id else { return }
        player.pause()
        player.replaceCurrentItem(with: nil)
        paperID = nil
        isPlaying = false
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    private func tick(_ seconds: Double) {
        guard seconds.isFinite, player.currentItem != nil else { return }
        position = seconds
        if abs(seconds - lastSaved) > 5 { savePosition() }
    }

    private func finished() {
        isPlaying = false
        position = 0
        player.seek(to: .zero)
        savePosition()
        updateNowPlaying()
    }

    private func savePosition() {
        guard let paperID else { return }
        lastSaved = position
        Library.shared.update(paperID) { $0.playbackPosition = self.position }
    }

    // MARK: Lock Screen

    private func setUpRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { _ in
            Task { @MainActor in SummaryPlayer.shared.play() }
            return .success
        }
        center.pauseCommand.addTarget { _ in
            Task { @MainActor in SummaryPlayer.shared.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { _ in
            Task { @MainActor in SummaryPlayer.shared.toggle() }
            return .success
        }
        center.skipForwardCommand.preferredIntervals = [15]
        center.skipForwardCommand.addTarget { _ in
            Task { @MainActor in SummaryPlayer.shared.skip(15) }
            return .success
        }
        center.skipBackwardCommand.preferredIntervals = [15]
        center.skipBackwardCommand.addTarget { _ in
            Task { @MainActor in SummaryPlayer.shared.skip(-15) }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let time = e.positionTime
            Task { @MainActor in SummaryPlayer.shared.seek(to: time) }
            return .success
        }
    }

    private func updateNowPlaying() {
        guard paperID != nil else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: "Papers summary",
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(speed) : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: Double(speed),
        ]
    }
}
