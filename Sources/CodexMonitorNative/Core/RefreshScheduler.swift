import Foundation

@MainActor
final class RefreshScheduler {
    enum PauseReason: Hashable {
        case unspecified
        case systemSleep
        case networkUnavailable
    }

    private var interval: TimeInterval
    private let onTick: @MainActor () -> Void
    private let timerResource = RefreshSchedulerTimerResource()
    private var pauseReasons: Set<PauseReason> = []
    private var isRunning: Bool = false

    var isPaused: Bool { !pauseReasons.isEmpty }

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
        pauseReasons.removeAll()
        AppLogger.refresh.info("Starting refresh scheduler with interval \(self.interval, format: .fixed(precision: 0)) seconds")
        scheduleTimer()
    }

    func stop() {
        if timerResource.timer != nil {
            AppLogger.refresh.info("Stopping refresh scheduler")
        }
        isRunning = false
        pauseReasons.removeAll()
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

    /// Pauses for one lifecycle reason. Overlapping reasons must each resume
    /// before the timer is recreated.
    func pause(for reason: PauseReason = .unspecified) {
        guard isRunning, pauseReasons.insert(reason).inserted else { return }
        AppLogger.system.info("Refresh scheduler paused (reason=\(String(describing: reason), privacy: .public))")
        timerResource.invalidate()
    }

    /// Clears one pause reason and resets the timer from now once all blockers
    /// have cleared.
    func resume(for reason: PauseReason = .unspecified) {
        guard isRunning, pauseReasons.remove(reason) != nil else { return }
        guard !isPaused else { return }
        AppLogger.system.info("Refresh scheduler resumed")
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
