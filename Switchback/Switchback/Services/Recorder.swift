import AVFoundation
import CoreLocation
import UIKit
import UserNotifications

/// Records hikes with GPS (also while the phone is locked) and warns you when you leave the trail you follow.
@MainActor
final class Recorder: NSObject, ObservableObject {
    static let shared = Recorder()

    enum State: String, Codable { case idle, recording, paused }

    @Published private(set) var state: State = .idle
    @Published private(set) var segments: [[TrackPoint]] = []
    @Published private(set) var distance: Double = 0
    @Published private(set) var movingTime: TimeInterval = 0
    @Published private(set) var gain: Double = 0
    @Published private(set) var startDate: Date?
    @Published private(set) var pausedTotal: TimeInterval = 0
    @Published private(set) var pausedAt: Date?
    @Published private(set) var following: Trail?
    @Published private(set) var offTrail = false
    @Published private(set) var offset: Double?
    @Published private(set) var remaining: Double?
    /// How far along the followed trail you are, in metres.
    @Published private(set) var along: Double?
    @Published private(set) var lastLocation: CLLocation?
    @Published private(set) var authorization: CLAuthorizationStatus = .notDetermined

    let manager = CLLocationManager()
    private var backgroundSession: CLBackgroundActivitySession?
    private var altRef: Double?
    private var followCumulative: [Double] = []
    private var unsavedPoints = 0
    private var endAlerted = false
    private var announcedUnits = 0
    private let voice = Voice()
    static let voiceKey = "voiceUpdates"

    var voiceOn: Bool {
        get { UserDefaults.standard.bool(forKey: Self.voiceKey) }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue, forKey: Self.voiceKey)
        }
    }
    private let draftURL = Files.support.appendingPathComponent("recording-in-progress.json")

    override init() {
        super.init()
        manager.delegate = self
        manager.activityType = .fitness
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 4
        manager.pausesLocationUpdatesAutomatically = false
        authorization = manager.authorizationStatus
        restoreDraft()
    }

    var isAuthorized: Bool { authorization == .authorizedWhenInUse || authorization == .authorizedAlways }
    var isDenied: Bool { authorization == .denied || authorization == .restricted }
    var trackCoords: [[Coord]] { segments.map { $0.map(\.coord) } }
    var currentAltitude: Double? {
        guard let l = lastLocation, l.verticalAccuracy > 0 else { return nil }
        return l.altitude
    }

    func elapsed(at now: Date) -> TimeInterval {
        guard let s = startDate else { return 0 }
        let pausedNow = pausedAt.map { now.timeIntervalSince($0) } ?? 0
        return max(0, now.timeIntervalSince(s) - pausedTotal - pausedNow)
    }

    func requestPermission() {
        if authorization == .notDetermined { manager.requestWhenInUseAuthorization() }
    }

    /// One location fix for the map (no continuous tracking).
    func locateOnce() {
        requestPermission()
        if isAuthorized { manager.requestLocation() }
    }

    // MARK: Following a trail

    func follow(_ trail: Trail?) {
        following = trail
        followCumulative = trail.map { Geo.cumulative($0.path) } ?? []
        offTrail = false
        offset = nil
        remaining = nil
        along = nil
        endAlerted = false
        if let loc = lastLocation, state != .idle { updateFollow(loc) }
        if trail != nil { requestNotificationPermission() }
        saveDraft()
    }

    // MARK: Recording

    func start(following trail: Trail? = nil) {
        requestPermission()
        if let trail { follow(trail) }
        segments = [[]]
        distance = 0
        movingTime = 0
        gain = 0
        altRef = nil
        startDate = Date()
        pausedTotal = 0
        pausedAt = nil
        state = .recording
        announcedUnits = 0
        beginUpdates()
        saveDraft()
        pushLive(force: true)
    }

    func pause() {
        guard state == .recording else { return }
        state = .paused
        pausedAt = Date()
        endUpdates()
        saveDraft()
        pushLive(force: true)
    }

    func resume() {
        guard state == .paused else { return }
        if let p = pausedAt { pausedTotal += Date().timeIntervalSince(p) }
        pausedAt = nil
        segments.append([])
        altRef = nil
        state = .recording
        beginUpdates()
        saveDraft()
        pushLive(force: true)
    }

    /// Ends the hike and saves it to Activity. Returns nil if too little was recorded.
    @discardableResult
    func finish(name: String) -> Activity? {
        let end = pausedAt ?? Date()
        let elapsed = elapsed(at: end)
        let segs = segments.filter { !$0.isEmpty }
        let trail = following
        let started = startDate
        let stats = (distance: distance, moving: movingTime, gain: gain)
        reset()
        guard let started, segs.reduce(0, { $0 + $1.count }) >= 2 else { return nil }
        let activity = Activity(name: name, start: started, end: end, segments: segs, distance: stats.distance,
                                movingTime: stats.moving, elapsedTime: elapsed, gain: stats.gain,
                                trailId: trail?.id, trailName: trail?.name)
        Library.shared.add(activity)
        return activity
    }

    func discard() { reset() }

    private func reset() {
        endUpdates()
        state = .idle
        segments = []
        distance = 0
        movingTime = 0
        gain = 0
        startDate = nil
        pausedTotal = 0
        pausedAt = nil
        altRef = nil
        following = nil
        followCumulative = []
        offTrail = false
        offset = nil
        remaining = nil
        along = nil
        endAlerted = false
        LiveHike.shared.end()
        try? FileManager.default.removeItem(at: draftURL)
    }

    private func beginUpdates() {
        guard isAuthorized || authorization == .notDetermined else { return }
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        if backgroundSession == nil { backgroundSession = CLBackgroundActivitySession() }
        manager.startUpdatingLocation()
    }

    private func endUpdates() {
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        backgroundSession?.invalidate()
        backgroundSession = nil
    }

    fileprivate func handle(_ locations: [CLLocation]) {
        guard let latest = locations.last else { return }
        lastLocation = latest
        guard state == .recording else { return }
        for loc in locations { record(loc) }
        if following != nil { updateFollow(latest) }
        announceMilestone()
        pushLive()
    }

    fileprivate func authorizationChanged(_ status: CLAuthorizationStatus) {
        authorization = status
        guard isAuthorized else { return }
        if state == .recording { beginUpdates() } else if lastLocation == nil { manager.requestLocation() }
    }

    private func record(_ loc: CLLocation) {
        guard loc.horizontalAccuracy >= 0, loc.horizontalAccuracy <= 40 else { return }
        if let s = startDate, loc.timestamp < s.addingTimeInterval(-5) { return }   // an old cached fix
        let alt: Double? = (loc.verticalAccuracy > 0 && loc.verticalAccuracy < 25) ? loc.altitude : nil
        let point = TrackPoint(lat: loc.coordinate.latitude, lon: loc.coordinate.longitude, alt: alt, time: loc.timestamp)
        if segments.isEmpty { segments = [[]] }
        let last = segments.count - 1

        if let prev = segments[last].last {
            let d = Geo.distance(prev.coord, point.coord)
            if d < max(3, loc.horizontalAccuracy * 0.5) { return }   // GPS jitter while standing
            let dt = point.time.timeIntervalSince(prev.time)
            guard dt > 0 else { return }
            if d / dt > 12 { return }                                 // a jump no hiker makes
            distance += d
            if dt < 60, d / dt > 0.3 { movingTime += dt }
        }
        if let alt {
            if let ref = altRef {
                if alt - ref >= 4 {
                    gain += alt - ref
                    altRef = alt
                } else if ref - alt >= 4 {
                    altRef = alt
                }
            } else {
                altRef = alt
            }
        }
        segments[last].append(point)
        unsavedPoints += 1
        if unsavedPoints >= 20 { saveDraft() }
    }

    private func updateFollow(_ loc: CLLocation) {
        guard let trail = following else { return }
        let p = Coord(loc.coordinate)
        let off = Geo.distanceToPath(p, segments: trail.segments)
        offset = off
        if let located = Geo.locate(p, on: trail.path, cumulative: followCumulative) {
            remaining = max(0, trail.length - located.along)
            along = located.along
            // the end of the trail (for a loop, only once you've been round most of it)
            if !endAlerted, located.offset < 60, trail.length - located.along < 40, distance > trail.length * 0.5 {
                endAlerted = true
                alert(title: "You've reached the end", body: "\(trail.name) · \(Fmt.distance(distance)) hiked.", speak: "You've reached the end of the trail.")
            }
        }
        if !offTrail && off > 60 {
            offTrail = true
            alertOffTrail(off, trail: trail)
            pushLive(force: true)
        } else if offTrail && off < 35 {
            offTrail = false
            pushLive(force: true)
        }
    }

    private func alertOffTrail(_ meters: Double, trail: Trail) {
        alert(title: "You've left the trail", body: "You're \(Fmt.shortDistance(meters)) from \(trail.name).",
              speak: "You've left the trail.")
    }

    private func alert(title: String, body: String, speak: String) {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        if voiceOn { voice.say(speak) }
        guard UIApplication.shared.applicationState != .active else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: title, content: content, trigger: nil))
    }

    /// Every mile (or kilometre): distance, time, and what's left.
    private func announceMilestone() {
        guard voiceOn, state == .recording else { return }
        let unit = Units.current == .imperial ? Fmt.metersPerMile : 1000
        let units = Int(distance / unit)
        guard units > announcedUnits else { return }
        announcedUnits = units
        let name = Units.current == .imperial ? (units == 1 ? "mile" : "miles") : (units == 1 ? "kilometre" : "kilometres")
        var text = "\(units) \(name). \(spokenDuration(elapsed(at: Date())))."
        if let r = remaining, following != nil {
            text += " \(String(format: "%.1f", r / unit)) to go."
        }
        voice.say(text)
    }

    private func spokenDuration(_ s: TimeInterval) -> String {
        let mins = Int(s / 60), h = mins / 60, m = mins % 60
        if h == 0 { return "\(m) minutes" }
        return "\(h) hour\(h == 1 ? "" : "s") \(m) minutes"
    }

    private func pushLive(force: Bool = false) {
        guard state != .idle, let start = startDate else { return }
        let elapsed = elapsed(at: Date())
        let st = HikeAttributes.ContentState(distance: distance, gain: gain, remaining: following == nil ? nil : remaining,
                                             timerStart: Date().addingTimeInterval(-elapsed),
                                             pausedElapsed: state == .paused ? elapsed : nil,
                                             offTrail: offTrail, imperial: Units.current == .imperial)
        _ = start
        LiveHike.shared.update(trailName: following?.name, state: st, force: force)
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    // MARK: Draft (so a hike survives the app being closed)

    private struct Draft: Codable {
        var segments: [[TrackPoint]]
        var distance: Double
        var movingTime: TimeInterval
        var gain: Double
        var startDate: Date
        var pausedTotal: TimeInterval
        var pausedAt: Date?
        var following: Trail?
    }

    private func saveDraft() {
        unsavedPoints = 0
        guard state != .idle, let startDate else { return }
        Files.save(Draft(segments: segments, distance: distance, movingTime: movingTime, gain: gain,
                         startDate: startDate, pausedTotal: pausedTotal, pausedAt: pausedAt, following: following),
                   to: draftURL)
    }

    private func restoreDraft() {
        guard let d = Files.load(Draft.self, from: draftURL) else { return }
        segments = d.segments
        distance = d.distance
        movingTime = d.movingTime
        gain = d.gain
        startDate = d.startDate
        pausedTotal = d.pausedTotal
        // the app was closed: carry on as paused from the last point
        pausedAt = d.pausedAt ?? d.segments.last?.last?.time ?? Date()
        following = d.following
        followCumulative = d.following.map { Geo.cumulative($0.path) } ?? []
        state = .paused
    }

    /// Call when the app goes to the background, so nothing recorded is lost.
    func flush() { saveDraft() }
}

extension Recorder: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in self.handle(locations) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in self.authorizationChanged(status) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}

/// Speaks short updates, lowering music while it talks.
final class Voice: NSObject, AVSpeechSynthesizerDelegate {
    private let synth = AVSpeechSynthesizer()

    override init() {
        super.init()
        synth.delegate = self
    }

    func say(_ text: String) {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .voicePrompt, options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
        try? session.setActive(true)
        let u = AVSpeechUtterance(string: text)
        u.rate = AVSpeechUtteranceDefaultSpeechRate
        synth.speak(u)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        if !synthesizer.isSpeaking {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}
