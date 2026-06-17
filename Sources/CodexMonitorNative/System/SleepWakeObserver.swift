import AppKit

@MainActor
final class SleepWakeObserver {
    private let notificationCenter: NotificationCenter
    private let wakeDelaySeconds: UInt64
    private let onSleep: (@MainActor () -> Void)?
    private let onWake: @MainActor () -> Void
    private var observers: [NSObjectProtocol] = []

    /// - Parameters:
    ///   - wakeDelaySeconds: Delay after wake before triggering refresh (3–10s).
    ///     Avoids spurious network failures while the system re-establishes connectivity.
    init(
        notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        wakeDelaySeconds: UInt64 = 5,
        onSleep: (@MainActor () -> Void)? = nil,
        onWake: @escaping @MainActor () -> Void
    ) {
        self.notificationCenter = notificationCenter
        self.wakeDelaySeconds = wakeDelaySeconds
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

        // Wake notification: fires AFTER the system wakes.
        // Delayed to let networking stabilize.
        let onWake = self.onWake
        let delay = wakeDelaySeconds
        let wakeObserver = notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard self != nil else { return }
            Task { @MainActor in
                AppLogger.system.info("System woke; scheduling refresh in \(delay)s")
                try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
                onWake()
            }
        }
        observers.append(wakeObserver)
    }

    func stop() {
        if !observers.isEmpty {
            AppLogger.system.info("Stopping sleep/wake observer")
        }
        for observer in observers {
            notificationCenter.removeObserver(observer)
        }
        observers.removeAll()
    }
}
