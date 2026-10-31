import AVFoundation
import MediaPlayer

/// Plays generated audio (paper parts and spoken clips) with Lock Screen controls and playback speed.
@MainActor
final class Player: ObservableObject {
    static let shared = Player()
    static let speeds: [Float] = [0.8, 1.0, 1.2, 1.5, 1.75, 2.0]

    struct Item: Equatable {
        var url: URL
        var title: String
        var subtitle: String
    }

    @Published private(set) var item: Item?
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

    /// Called when an item plays to the end (the paper view uses it to go on to the next part).
    var onFinish: ((Item) -> Void)?

    private let player = AVPlayer()
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?

    private init() {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
                                                      queue: .main) { time in
            MainActor.assumeIsolated { Player.shared.tick(time.seconds) }
        }
        setUpRemoteCommands()
    }

    func isCurrent(_ url: URL) -> Bool { item?.url == url }

    func play(_ item: Item) {
        if item.url != self.item?.url {
            let playerItem = AVPlayerItem(url: item.url)
            playerItem.audioTimePitchAlgorithm = .timeDomain
            player.replaceCurrentItem(with: playerItem)
            if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
            endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: playerItem,
                                                                 queue: .main) { _ in
                MainActor.assumeIsolated { Player.shared.finished() }
            }
            self.item = item
            position = 0
            duration = AudioClip.duration(of: item.url)
        }
        play()
    }

    func play() {
        guard player.currentItem != nil else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        player.playImmediately(atRate: speed)
        isPlaying = true
        updateNowPlaying()
    }

    func pause() {
        player.pause()
        isPlaying = false
        updateNowPlaying()
    }

    func toggle() { isPlaying ? pause() : play() }

    func seek(to seconds: Double) {
        let t = min(max(seconds, 0), max(duration - 0.1, 0))
        position = t
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        updateNowPlaying()
    }

    func skip(_ seconds: Double) { seek(to: position + seconds) }

    /// Stops playing a file that is about to be replaced or deleted.
    func stop(ifPlaying url: URL) {
        guard item?.url == url else { return }
        stop()
    }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        item = nil
        isPlaying = false
        position = 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    private func tick(_ seconds: Double) {
        guard seconds.isFinite, player.currentItem != nil else { return }
        position = seconds
        if duration <= 0, let d = player.currentItem?.duration.seconds, d.isFinite { duration = d }
    }

    private func finished() {
        isPlaying = false
        position = 0
        player.seek(to: .zero)
        updateNowPlaying()
        if let item { onFinish?(item) }
    }

    private func setUpRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { _ in
            Task { @MainActor in Player.shared.play() }
            return .success
        }
        center.pauseCommand.addTarget { _ in
            Task { @MainActor in Player.shared.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { _ in
            Task { @MainActor in Player.shared.toggle() }
            return .success
        }
        center.skipForwardCommand.preferredIntervals = [15]
        center.skipForwardCommand.addTarget { _ in
            Task { @MainActor in Player.shared.skip(15) }
            return .success
        }
        center.skipBackwardCommand.preferredIntervals = [15]
        center.skipBackwardCommand.addTarget { _ in
            Task { @MainActor in Player.shared.skip(-15) }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let time = e.positionTime
            Task { @MainActor in Player.shared.seek(to: time) }
            return .success
        }
    }

    private func updateNowPlaying() {
        guard let item else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: item.title,
            MPMediaItemPropertyArtist: item.subtitle,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(speed) : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: Double(speed),
        ]
    }
}
