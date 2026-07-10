import AppKit

@MainActor
final class SleepWakeObserver {
    private let notificationCenter: NotificationCenter
    private let wakeDelaySeconds: UInt64
    private let onSleep: (@MainActor () -> Void)?
    private let onWake: @MainActor () -> Void
    private let sleep: @Sendable (UInt64) async throws -> Void
    private let dispatchTask: @Sendable (@escaping @MainActor @Sendable () -> Void) -> Void
    private let resources: SleepWakeResources

    /// - Parameters:
    ///   - wakeDelaySeconds: Delay after wake before triggering refresh (3–10s).
    ///     Avoids spurious network failures while the system re-establishes connectivity.
    init(
        notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        wakeDelaySeconds: UInt64 = 5,
        onSleep: (@MainActor () -> Void)? = nil,
        sleep: @escaping @Sendable (UInt64) async throws -> Void = { nanoseconds in
            try await Task.sleep(nanoseconds: nanoseconds)
        },
        dispatchTask: @escaping @Sendable (@escaping @MainActor @Sendable () -> Void) -> Void = { action in
            Task { @MainActor in action() }
        },
        onWake: @escaping @MainActor () -> Void
    ) {
        self.notificationCenter = notificationCenter
        self.wakeDelaySeconds = wakeDelaySeconds
        self.onSleep = onSleep
        self.sleep = sleep
        self.dispatchTask = dispatchTask
        self.onWake = onWake
        self.resources = SleepWakeResources(notificationCenter: notificationCenter)
    }

    func start() {
        stop()
        let generation = resources.start()
        AppLogger.system.info("Starting sleep/wake observer (wakeDelay=\(self.wakeDelaySeconds)s)")

        // Sleep notification: fires BEFORE the system actually sleeps.
        if let onSleep {
            let sleepObserver = notificationCenter.addObserver(
                forName: NSWorkspace.willSleepNotification,
                object: nil,
                queue: .main
            ) { [weak resources, dispatchTask] _ in
                dispatchTask {
                    guard resources?.isCurrent(generation) == true else { return }
                    AppLogger.system.info("System will sleep; pausing")
                    onSleep()
                }
            }
            resources.observers.append(sleepObserver)
        }

        // Wake notification: fires AFTER the system wakes.
        // Delayed to let networking stabilize.
        let onWake = self.onWake
        let delay = wakeDelaySeconds
        let sleep = self.sleep
        let wakeObserver = notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak resources, dispatchTask] _ in
            dispatchTask {
                guard let resources, resources.isCurrent(generation) else { return }
                resources.pendingWakeTask?.cancel()
                resources.pendingWakeTask = Task { @MainActor [weak resources] in
                    AppLogger.system.info("System woke; scheduling refresh in \(delay)s")
                    do {
                        try await sleep(delay * 1_000_000_000)
                    } catch {
                        return
                    }
                    guard !Task.isCancelled, resources?.isCurrent(generation) == true else { return }
                    onWake()
                    resources?.clearPendingWakeTask(for: generation)
                }
            }
        }
        resources.observers.append(wakeObserver)
    }

    func stop() {
        if !resources.observers.isEmpty {
            AppLogger.system.info("Stopping sleep/wake observer")
        }
        resources.stop()
    }

}

private final class SleepWakeResources: @unchecked Sendable {
    let notificationCenter: NotificationCenter
    var observers: [NSObjectProtocol] = []
    var pendingWakeTask: Task<Void, Never>?
    private var generation = 0

    init(notificationCenter: NotificationCenter) {
        self.notificationCenter = notificationCenter
    }

    func start() -> Int {
        generation &+= 1
        return generation
    }

    func isCurrent(_ expectedGeneration: Int) -> Bool {
        generation == expectedGeneration
    }

    func clearPendingWakeTask(for expectedGeneration: Int) {
        guard isCurrent(expectedGeneration) else { return }
        pendingWakeTask = nil
    }

    func stop() {
        generation &+= 1
        for observer in observers {
            notificationCenter.removeObserver(observer)
        }
        observers.removeAll()
        pendingWakeTask?.cancel()
        pendingWakeTask = nil
    }

    deinit {
        stop()
    }
}
