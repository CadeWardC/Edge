import ActivityKit
import Foundation

/// Keeps the lock-screen / Dynamic Island Live Activity in step with the recording.
@MainActor
final class LiveHike {
    static let shared = LiveHike()

    private var activity: Activity<HikeAttributes>?
    private var lastUpdate = Date.distantPast
    private var lastState: HikeAttributes.ContentState?

    func update(trailName: String?, state: HikeAttributes.ContentState, force: Bool = false) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        if activity == nil {
            activity = try? Activity.request(attributes: HikeAttributes(trailName: trailName),
                                             content: ActivityContent(state: state, staleDate: nil), pushType: nil)
            lastUpdate = Date()
            lastState = state
            return
        }
        // the system limits how often these can change, so only every 15 s unless something important changed
        let important = force || state.offTrail != lastState?.offTrail || (state.pausedElapsed == nil) != (lastState?.pausedElapsed == nil)
        guard important || Date().timeIntervalSince(lastUpdate) >= 15, let activity else { return }
        lastUpdate = Date()
        lastState = state
        Task { await activity.update(ActivityContent(state: state, staleDate: nil)) }
    }

    func end() {
        guard let activity else { return }
        self.activity = nil
        lastState = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }
}
