import AVFoundation
import AVKit
import Combine
import UIKit

/// The view whose layer shows the frames, in the app and in the floating window.
final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
}

/// Shows the photos as a video the system can float over other apps.
///
/// Picture in Picture only takes video, so each page of photos is drawn into a frame and handed to a sample buffer
/// layer. The window's timeline is the slideshow: every page lasts `settings.seconds`, the skip buttons change page
/// and play/pause turns automatic changing on and off. Everything here runs on the main thread.
final class PipEngine: NSObject, ObservableObject {
    static let shared = PipEngine()

    let preview = PreviewView()

    @Published var settings: PipSettings {
        didSet {
            guard settings != oldValue else { return }
            settings.save()
            page = min(page, pageCount - 1)
            restartPage()
        }
    }
    @Published private(set) var page = 0
    @Published private(set) var photos: [Photo] = []
    @Published private(set) var firstAspect: CGFloat?
    /// The floating window is open.
    @Published private(set) var isActive = false
    @Published private(set) var isSupported = true
    @Published var message: String?

    var pageCount: Int { max(1, Int(ceil(Double(photos.count) / Double(settings.perPage)))) }
    var canvasAspect: CGFloat { settings.aspect(firstPhoto: firstAspect) }

    private var controller: AVPictureInPictureController?
    private let timebase: CMTimebase
    private let renderer = FrameRenderer()
    private let renderQueue = DispatchQueue(label: "com.cadewardc.pip.render", qos: .userInitiated)
    private var renderGeneration = 0
    private var frame: CVPixelBuffer?
    private var pageStarted = Date()
    private var timer: Timer?
    private var ticks = 0
    private var mixesWithOtherAudio = true
    private var retriedStart = false
    private var cancellables: Set<AnyCancellable> = []

    private override init() {
        settings = PipSettings.load()
        var created: CMTimebase?
        CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &created)
        timebase = created!
        super.init()

        preview.backgroundColor = .black
        preview.displayLayer.videoGravity = .resizeAspect
        preview.displayLayer.controlTimebase = timebase

        setUpController()

        PhotoLibrary.shared.$photos
            .sink { [weak self] photos in self?.photosChanged(photos) }
            .store(in: &cancellables)

        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    // MARK: Pages

    func step(_ delta: Int) {
        guard pageCount > 1 else { return }
        show(page: ((page + delta) % pageCount + pageCount) % pageCount)
    }

    func show(photoAt index: Int) {
        show(page: index / settings.perPage)
    }

    private func show(page newPage: Int) {
        page = min(max(newPage, 0), pageCount - 1)
        restartPage()
    }

    private func photosChanged(_ newPhotos: [Photo]) {
        photos = newPhotos
        firstAspect = newPhotos.first.flatMap { PhotoFiles.aspect($0) }
        page = min(page, pageCount - 1)
        restartPage()
    }

    /// Starts the current page's time again and redraws it.
    private func restartPage() {
        pageStarted = Date()
        let advancing = settings.autoAdvance && pageCount > 1
        CMTimebaseSetTime(timebase, time: CMTime(seconds: Double(page * settings.seconds), preferredTimescale: 600))
        // with a single page the window has no timeline, so the clock just runs
        CMTimebaseSetRate(timebase, rate: advancing || pageCount == 1 ? 1 : 0)
        controller?.canStartPictureInPictureAutomaticallyFromInline = settings.startOnLeave && !photos.isEmpty
        controller?.invalidatePlaybackState()
        render()
    }

    private func tick() {
        ticks += 1
        let layer = preview.displayLayer
        if layer.status == .failed {
            layer.flush()
            enqueueFrame()
        } else if ticks % 4 == 0 {
            enqueueFrame()   // the layer drops its picture when the window opens or closes
        }
        if settings.autoAdvance, pageCount > 1, Date().timeIntervalSince(pageStarted) >= Double(settings.seconds) {
            step(1)
        }
    }

    // MARK: Frames

    private func render() {
        renderGeneration += 1
        let generation = renderGeneration
        let start = page * settings.perPage
        let shown = Array(photos.dropFirst(start).prefix(settings.perPage))
        let canvas = settings.canvas(firstPhoto: firstAspect)
        let arrangement = settings.arrangement, fill = settings.fill
        renderQueue.async { [renderer] in
            let buffer = renderer.render(photos: shown, width: canvas.width, height: canvas.height, arrangement: arrangement, fill: fill)
            DispatchQueue.main.async { [weak self] in
                guard let self, generation == self.renderGeneration else { return }
                self.frame = buffer
                self.enqueueFrame()
            }
        }
    }

    private func enqueueFrame() {
        guard let frame else { return }
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: frame, formatDescriptionOut: &format)
        guard let format else { return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTimebaseGetTime(timebase), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: frame, formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample)
        guard let sample else { return }
        // show it now, whatever the clock says
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true), CFArrayGetCount(attachments) > 0 {
            let first = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                first, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        let layer = preview.displayLayer
        if layer.requiresFlushToResumeDecoding { layer.flush() }
        layer.enqueue(sample)
    }

    // MARK: Floating window

    private func setUpController() {
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            isSupported = false
            return
        }
        configureAudioSession()
        let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: preview.displayLayer, playbackDelegate: self)
        let controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = self
        self.controller = controller
    }

    /// Picture in Picture needs a playback audio session even though nothing is played. Mixing keeps music from other
    /// apps going; if the window will not open that way, `toggle` tries again without it.
    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .moviePlayback, options: mixesWithOtherAudio ? [.mixWithOthers] : [])
            try session.setActive(true)
        } catch {
            message = "Could not prepare Picture in Picture: \(error.localizedDescription)"
        }
    }

    func toggle() {
        guard let controller else { return }
        if controller.isPictureInPictureActive {
            controller.stopPictureInPicture()
            return
        }
        retriedStart = false
        start()
    }

    private func start() {
        guard let controller else { return }
        enqueueFrame()
        if controller.isPictureInPicturePossible {
            controller.startPictureInPicture()
        } else {
            retryWithoutMixing(otherwise: "Picture in Picture is not available right now. Check it is turned on in Settings › General › Picture in Picture.")
        }
    }

    private func retryWithoutMixing(otherwise text: String) {
        guard mixesWithOtherAudio, !retriedStart else {
            message = text
            return
        }
        retriedStart = true
        mixesWithOtherAudio = false
        configureAudioSession()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.start() }
    }
}

extension PipEngine: AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        isActive = true
        enqueueFrame()
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        isActive = false
        enqueueFrame()
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        isActive = false
        retryWithoutMixing(otherwise: "Picture in Picture could not start: \(error.localizedDescription)")
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        completionHandler(true)
    }
}

extension PipEngine: AVPictureInPictureSampleBufferPlaybackDelegate {
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {
        if pageCount > 1, settings.autoAdvance != playing {
            settings.autoAdvance = playing
        } else {
            pictureInPictureController.invalidatePlaybackState()
        }
    }

    func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        guard pageCount > 1 else { return CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity) }
        return CMTimeRange(start: .zero, duration: CMTime(seconds: Double(pageCount * settings.seconds), preferredTimescale: 600))
    }

    func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        pageCount > 1 && !settings.autoAdvance
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

    /// The skip buttons go to the previous or next photos.
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, skipByInterval skipInterval: CMTime,
                                    completion completionHandler: @escaping () -> Void) {
        step(skipInterval.seconds < 0 ? -1 : 1)
        completionHandler()
    }
}
