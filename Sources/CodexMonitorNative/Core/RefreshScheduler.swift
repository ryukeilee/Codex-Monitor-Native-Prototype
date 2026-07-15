import Foundation

@MainActor
final class RefreshScheduler {
    private var interval: TimeInterval
    private let onTick: @MainActor () -> Void
    private let timerResource = RefreshSchedulerTimerResource()
    private(set) var isPaused: Bool = false
    private var isRunning: Bool = false

    /// Exposed for lifecycle verification without leaking the timer itself.
    var hasScheduledTimer: Bool {
        timerResource.timer != nil
    }

    init(interval: TimeInterval, onTick: @escaping @MainActor () -> Void) {
        self.interval = interval
        self.onTick = onTick
    }

    func start() {
        stop()
        isRunning = true
        isPaused = false
        AppLogger.refresh.info("Starting refresh scheduler with interval \(self.interval, format: .fixed(precision: 0)) seconds")
        scheduleTimer()
    }

    func stop() {
        if timerResource.timer != nil {
            AppLogger.refresh.info("Stopping refresh scheduler")
        }
        isRunning = false
        isPaused = false
        timerResource.invalidate()
    }

    /// Update the interval without restarting. Takes effect at the next fire.
    func updateInterval(_ newInterval: TimeInterval) {
        guard newInterval != interval else { return }
        AppLogger.refresh.info("Updating refresh interval: \(self.interval, format: .fixed(precision: 0)) → \(newInterval, format: .fixed(precision: 0)) seconds")
        interval = newInterval
        guard isRunning, !isPaused else { return }
        scheduleTimer()
    }

    /// Pause the scheduler during sleep. Fires are silently dropped.
    func pause() {
        guard isRunning, !isPaused else { return }
        isPaused = true
        AppLogger.system.info("Refresh scheduler paused (system sleep)")
        timerResource.invalidate()
    }

    /// Resume after wake. Resets the timer from now.
    func resume() {
        guard isRunning, isPaused else { return }
        isPaused = false
        AppLogger.system.info("Refresh scheduler resumed (system wake)")
        scheduleTimer()
    }

    // MARK: - Private

    private func scheduleTimer() {
        timerResource.invalidate()
        guard isRunning, !isPaused else { return }
        let onTick = self.onTick
        timerResource.timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isRunning, !self.isPaused else {
                    return
                }
                AppLogger.refresh.info("Refresh scheduler fired (interval=\(self.interval, format: .fixed(precision: 0))s)")
                onTick()
            }
        }
        if let timer = timerResource.timer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }
}

private final class RefreshSchedulerTimerResource {
    var timer: Timer?

    func invalidate() {
        timer?.invalidate()
        timer = nil
    }

    deinit {
        invalidate()
    }
}
