import BackgroundTasks
import UIKit

/// Keeps a paper's audio being made after the user leaves the app.
///
/// On iOS 26 and later this is a continued processing task: the system shows its progress (on the Lock Screen and
/// in the Dynamic Island) and lets the work run to the end, unless the phone needs the resources or the user stops
/// it there. Before iOS 26 the app only gets the usual short grace period.
@MainActor
final class BackgroundKeepAlive {
    static let shared = BackgroundKeepAlive()
    static let taskIdentifier = "com.cadewardc.edge.render"

    /// Called when the system takes the background time away; the work should stop and save where it is.
    var onExpire: (() -> Void)?

    private var legacyTask: UIBackgroundTaskIdentifier = .invalid
    private var continued: AnyObject?
    private var active = false
    /// Paper jobs and spoken clips can run at the same time; background time ends when the last one does.
    private var users = 0
    private var fraction: Double = 0
    private var title = "Making audio"
    private var subtitle = ""

    /// Registers the handler for continued processing tasks; call once at launch.
    static func register() {
        if #available(iOS 26.0, *) {
            BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: .main) { task in
                MainActor.assumeIsolated {
                    BackgroundKeepAlive.shared.attach(task)
                }
            }
        }
    }

    func begin(title: String, subtitle: String) {
        users += 1
        guard !active else { return }
        active = true
        self.title = title
        self.subtitle = subtitle
        fraction = 0
        legacyTask = UIApplication.shared.beginBackgroundTask(withName: "Render") { [weak self] in
            MainActor.assumeIsolated { self?.legacyExpired() }
        }
        if #available(iOS 26.0, *) {
            submitContinued()
        }
    }

    func update(fraction: Double, title: String, subtitle: String) {
        self.fraction = min(max(fraction, 0), 1)
        self.title = title
        self.subtitle = subtitle
        if #available(iOS 26.0, *), let task = continued as? BGContinuedProcessingTask {
            task.progress.completedUnitCount = Int64(self.fraction * 1000)
            task.updateTitle(title, subtitle: subtitle)
        }
    }

    func end(success: Bool) {
        users = max(0, users - 1)
        guard active, users == 0 else { return }
        active = false
        if #available(iOS 26.0, *), let task = continued as? BGContinuedProcessingTask {
            task.progress.completedUnitCount = task.progress.totalUnitCount
            task.setTaskCompleted(success: success)
        }
        continued = nil
        endLegacy()
    }

    // MARK: iOS 26 continued processing

    @available(iOS 26.0, *)
    private func submitContinued() {
        let request = BGContinuedProcessingTaskRequest(identifier: Self.taskIdentifier, title: title, subtitle: subtitle)
        request.strategy = .queue
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            print("Edge: continued processing is not available: \(error)")
        }
    }

    private func attach(_ task: BGTask) {
        guard #available(iOS 26.0, *), let task = task as? BGContinuedProcessingTask else {
            task.setTaskCompleted(success: true)
            return
        }
        guard active else {
            // the work finished before the system started the task
            task.setTaskCompleted(success: true)
            return
        }
        continued = task
        task.progress.totalUnitCount = 1000
        task.progress.completedUnitCount = Int64(fraction * 1000)
        task.updateTitle(title, subtitle: subtitle)
        task.expirationHandler = { [weak self] in
            Task { @MainActor in self?.expired() }
        }
        // the continued task keeps the app running now
        endLegacy()
    }

    private func expired() {
        guard active else { return }
        onExpire?()
    }

    private func legacyExpired() {
        if continued == nil {
            expired()
        }
        endLegacy()
    }

    private func endLegacy() {
        if legacyTask != .invalid {
            UIApplication.shared.endBackgroundTask(legacyTask)
            legacyTask = .invalid
        }
    }
}
