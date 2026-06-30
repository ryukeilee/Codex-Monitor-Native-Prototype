import AppKit

@MainActor
final class SleepWakeObserver {
    private let notificationCenter: NotificationCenter
    private let wakeDelaySeconds: UInt64
    private let resumeCoalescingWindow: TimeInterval
    private let onSleep: (@MainActor () -> Void)?
    private let onWake: @MainActor () -> Void
    private var observers: [NSObjectProtocol] = []
    private var pendingWakeTask: Task<Void, Never>?
    private var lastWakeHandledAt: Date?

    /// - Parameters:
    ///   - wakeDelaySeconds: Delay after wake before triggering refresh (3–10s).
    ///     Avoids spurious network failures while the system re-establishes connectivity.
    init(
        notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        wakeDelaySeconds: UInt64 = 5,
        resumeCoalescingWindow: TimeInterval = 15,
        onSleep: (@MainActor () -> Void)? = nil,
        onWake: @escaping @MainActor () -> Void
    ) {
        self.notificationCenter = notificationCenter
        self.wakeDelaySeconds = wakeDelaySeconds
        self.resumeCoalescingWindow = resumeCoalescingWindow
        self.onSleep = onSleep
        self.onWake = onWake
    }

    func start() {
        stop()
        AppLogger.system.info("Starting sleep/wake observer (wakeDelay=\(self.wakeDelaySeconds)s)")

        // Sleep notification: fires BEFORE the system actually sleeps.
        if let onSleep {
            let sleepObserver = notificationCenter.addObserver(
                forName: NSWorkspace.willSleepNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard self != nil else { return }
                Task { @MainActor in
                    AppLogger.system.info("System will sleep; pausing")
                    onSleep()
                }
            }
            observers.append(sleepObserver)
        }

        observeResumeSignal(
            name: NSWorkspace.didWakeNotification,
            reason: "System woke"
        )
        observeResumeSignal(
            name: NSWorkspace.screensDidWakeNotification,
            reason: "Screens woke"
        )
        observeResumeSignal(
            name: NSWorkspace.sessionDidBecomeActiveNotification,
            reason: "Session became active"
        )
    }

    func stop() {
        if !observers.isEmpty {
            AppLogger.system.info("Stopping sleep/wake observer")
        }
        pendingWakeTask?.cancel()
        pendingWakeTask = nil
        for observer in observers {
            notificationCenter.removeObserver(observer)
        }
        observers.removeAll()
    }

    private func observeResumeSignal(name: Notification.Name, reason: String) {
        let observer = notificationCenter.addObserver(
            forName: name,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleWakeRefresh(reason: reason)
            }
        }
        observers.append(observer)
    }

    private func scheduleWakeRefresh(reason: String) {
        if pendingWakeTask != nil {
            AppLogger.system.info("Ignoring duplicate resume signal while refresh is already pending (\(reason, privacy: .public))")
            return
        }

        if let lastWakeHandledAt,
           Date.now.timeIntervalSince(lastWakeHandledAt) < resumeCoalescingWindow {
            AppLogger.system.info("Ignoring coalesced resume signal within \(self.resumeCoalescingWindow, format: .fixed(precision: 0))s (\(reason, privacy: .public))")
            return
        }

        let delay = wakeDelaySeconds
        let onWake = self.onWake
        AppLogger.system.info("\(reason, privacy: .public); scheduling refresh in \(delay)s")
        pendingWakeTask = Task { @MainActor [weak self] in
            if delay > 0 {
                do {
                    try await Task.sleep(nanoseconds: delay * 1_000_000_000)
                } catch {
                    return
                }
            }

            guard let self else { return }
            self.pendingWakeTask = nil
            self.lastWakeHandledAt = .now
            onWake()
        }
    }
}
