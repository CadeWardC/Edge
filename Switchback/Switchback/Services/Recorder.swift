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
    @Published private(set) var lastLocation: CLLocation?
    @Published private(set) var authorization: CLAuthorizationStatus = .notDetermined

    let manager = CLLocationManager()
    private var backgroundSession: CLBackgroundActivitySession?
    private var altRef: Double?
    private var followCumulative: [Double] = []
    private var unsavedPoints = 0
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
        beginUpdates()
        saveDraft()
    }

    func pause() {
        guard state == .recording else { return }
        state = .paused
        pausedAt = Date()
        endUpdates()
        saveDraft()
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
        }
        if !offTrail && off > 60 {
            offTrail = true
            alertOffTrail(off, trail: trail)
        } else if offTrail && off < 35 {
            offTrail = false
        }
    }

    private func alertOffTrail(_ meters: Double, trail: Trail) {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        guard UIApplication.shared.applicationState != .active else { return }
        let content = UNMutableNotificationContent()
        content.title = "You've left the trail"
        content.body = "You're \(Fmt.shortDistance(meters)) from \(trail.name)."
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "off-trail", content: content, trigger: nil))
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
