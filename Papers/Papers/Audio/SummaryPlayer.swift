import AVFoundation
import MediaPlayer
import UIKit

/// What the player can play: one of a paper's tracks, or an imported recording.
enum PlayableID: Hashable {
    case paper(UUID, TrackKind)
    case recording(UUID)
}

/// Plays a paper's tracks and imported recordings, with Lock Screen controls, chapters and playback speed.
/// Remembers where you stopped in each.
@MainActor
final class SummaryPlayer: ObservableObject {
    static let shared = SummaryPlayer()
    static let speeds: [Float] = [0.8, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0]

    @Published private(set) var item: PlayableID?
    @Published private(set) var isPlaying = false
    @Published private(set) var position: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var title = ""
    @Published private(set) var subtitle = ""
    @Published private(set) var chapters: [Chapter] = []
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

    private init() {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
                                                      queue: .main) { time in
            MainActor.assumeIsolated { SummaryPlayer.shared.tick(time.seconds) }
        }
        setUpRemoteCommands()
    }

    var currentChapterIndex: Int? {
        chapters.lastIndex { $0.start <= position + 0.25 }
    }

    // MARK: Loading

    /// Loads an item (at its saved position) without starting it.
    func load(_ id: PlayableID) {
        guard id != item else { return }
        guard let info = info(for: id), FileManager.default.fileExists(atPath: info.url.path) else { return }
        savePosition()
        let playerItem = AVPlayerItem(url: info.url)
        playerItem.audioTimePitchAlgorithm = .timeDomain
        player.replaceCurrentItem(with: playerItem)
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: playerItem,
                                                             queue: .main) { _ in
            MainActor.assumeIsolated { SummaryPlayer.shared.finished() }
        }
        item = id
        title = info.title
        subtitle = info.subtitle
        duration = info.duration
        chapters = info.chapters
        let start = info.position < max(duration - 2, 0) ? info.position : 0
        position = start
        lastSaved = start
        player.seek(to: CMTime(seconds: start, preferredTimescale: 600))
        isPlaying = false
        updateNowPlaying()
    }

    private struct Info {
        var url: URL
        var title: String
        var subtitle: String
        var duration: Double
        var chapters: [Chapter]
        var position: Double
    }

    private func info(for id: PlayableID) -> Info? {
        switch id {
        case .paper(let pid, let kind):
            guard let p = Library.shared.paper(pid), let track = p.tracks[kind] else { return nil }
            return Info(url: Library.audioURL(pid, kind), title: p.displayTitle, subtitle: kind.title,
                        duration: track.duration, chapters: track.chapters, position: track.position)
        case .recording(let rid):
            guard let r = RecordingLibrary.shared.recording(rid) else { return nil }
            return Info(url: RecordingLibrary.mediaURL(r), title: r.displayTitle, subtitle: "Recording",
                        duration: r.duration, chapters: [], position: r.position)
        }
    }

    // MARK: Controls

    func play(_ id: PlayableID) {
        load(id)
        play()
    }

    func play() {
        guard player.currentItem != nil else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        player.playImmediately(atRate: speed)
        isPlaying = true
        if case .paper(let pid, _) = item { Library.shared.update(pid) { $0.lastPlayed = Date() } }
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

    func nextChapter() {
        guard let i = currentChapterIndex, i + 1 < chapters.count else { return }
        seek(to: chapters[i + 1].start)
    }

    func previousChapter() {
        guard let i = currentChapterIndex else { seek(to: 0); return }
        // within the first seconds of a chapter, go to the one before
        let target = position - chapters[i].start < 3 && i > 0 ? i - 1 : i
        seek(to: chapters[target].start)
    }

    /// Stops and forgets a paper's tracks (when it is deleted or its audio is made again).
    func unload(paper id: UUID) {
        if case .paper(let pid, _) = item, pid == id { stop() }
    }

    func unload(recording id: UUID) {
        if case .recording(let rid) = item, rid == id { stop() }
    }

    private func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        item = nil
        isPlaying = false
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    private func tick(_ seconds: Double) {
        guard seconds.isFinite, player.currentItem != nil else { return }
        let chapterBefore = currentChapterIndex
        position = seconds
        if abs(seconds - lastSaved) > 5 { savePosition() }
        if currentChapterIndex != chapterBefore { updateNowPlaying() }
    }

    private func finished() {
        isPlaying = false
        position = 0
        player.seek(to: .zero)
        savePosition()
        updateNowPlaying()
    }

    private func savePosition() {
        lastSaved = position
        let p = position
        switch item {
        case .paper(let pid, let kind):
            Library.shared.update(pid) { $0.tracks[kind]?.position = p }
        case .recording(let rid):
            RecordingLibrary.shared.update(rid) { $0.position = p }
        case nil:
            break
        }
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
        guard item != nil else { return }
        var artist = subtitle
        if let i = currentChapterIndex { artist += " · " + chapters[i].title }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: artist,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(speed) : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: Double(speed),
        ]
    }
}
