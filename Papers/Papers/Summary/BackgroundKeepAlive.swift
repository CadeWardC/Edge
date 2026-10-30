import BackgroundTasks
import UIKit

/// Keeps a summary running after the user leaves the app.
///
/// On iOS 26 and later this is a continued processing task: the system shows its progress (on the Lock Screen and
/// in the Dynamic Island) and lets the work run to the end, unless the phone needs the resources or the user stops
/// it there. Where the phone allows it, the task also asks for the GPU; otherwise the summary model moves to the
/// CPU while the app is in the background. Before iOS 26 the app only gets the usual short grace period.
@MainActor
final class BackgroundKeepAlive {
    static let shared = BackgroundKeepAlive()
    static let taskIdentifier = "com.cadewardc.papers.summarize"

    /// Called when the system takes the background time away; the work should stop and save where it is.
    var onExpire: (() -> Void)?

    /// Whether GPU work is allowed while the app is in the background.
    private(set) var backgroundGPU = false

    private var legacyTask: UIBackgroundTaskIdentifier = .invalid
    private var continued: AnyObject?
    private var active = false
    private var fraction: Double = 0
    private var title = "Summarizing"
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
        guard !active else { return }
        active = true
        self.title = title
        self.subtitle = subtitle
        fraction = 0
        legacyTask = UIApplication.shared.beginBackgroundTask(withName: "Summary") { [weak self] in
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
        guard active else { return }
        active = false
        backgroundGPU = false
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
        if BGTaskScheduler.supportedResources.contains(.gpu) {
            request.requiredResources = .gpu
        }
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            print("Papers: continued processing is not available: \(error)")
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
        backgroundGPU = BGTaskScheduler.supportedResources.contains(.gpu)
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
