import Foundation

@MainActor
final class RefreshScheduler {
    private var interval: TimeInterval
    private let onTick: @MainActor () -> Void
    private var timer: Timer?
    private(set) var isPaused: Bool = false

    init(interval: TimeInterval, onTick: @escaping @MainActor () -> Void) {
        self.interval = interval
        self.onTick = onTick
    }

    func start() {
        stop()
        AppLogger.refresh.info("Starting refresh scheduler with interval \(self.interval, format: .fixed(precision: 0)) seconds")
        scheduleTimer()
    }

    func stop() {
        if timer != nil {
            AppLogger.refresh.info("Stopping refresh scheduler")
        }
        timer?.invalidate()
        timer = nil
    }

    /// Update the interval without restarting. Takes effect at the next fire.
    func updateInterval(_ newInterval: TimeInterval) {
        guard newInterval != interval else { return }
        AppLogger.refresh.info("Updating refresh interval: \(self.interval, format: .fixed(precision: 0)) → \(newInterval, format: .fixed(precision: 0)) seconds")
        interval = newInterval
        guard !isPaused else { return }
        scheduleTimer()
    }

    /// Pause the scheduler during sleep. Fires are silently dropped.
    func pause() {
        guard !isPaused else { return }
        isPaused = true
        AppLogger.system.info("Refresh scheduler paused (system sleep)")
        timer?.invalidate()
        timer = nil
    }

    /// Resume after wake. Resets the timer from now.
    func resume() {
        guard isPaused else { return }
        isPaused = false
        AppLogger.system.info("Refresh scheduler resumed (system wake)")
        scheduleTimer()
    }

    // MARK: - Private

    private func scheduleTimer() {
        timer?.invalidate()
        let onTick = self.onTick
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.isPaused else {
                    return
                }
                AppLogger.refresh.info("Refresh scheduler fired (interval=\(self.interval, format: .fixed(precision: 0))s)")
                onTick()
            }
        }
        if let timer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }
}
