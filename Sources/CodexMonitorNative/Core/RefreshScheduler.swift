import Foundation

@MainActor
final class RefreshScheduler {
    private let interval: TimeInterval
    private let onTick: @MainActor () -> Void
    private var timer: Timer?

    init(interval: TimeInterval, onTick: @escaping @MainActor () -> Void) {
        self.interval = interval
        self.onTick = onTick
    }

    func start() {
        stop()
        AppLogger.refresh.info("Starting refresh scheduler with interval \(self.interval, format: .fixed(precision: 0)) seconds")
        let onTick = self.onTick
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard self != nil else {
                return
            }
            Task { @MainActor in
                AppLogger.refresh.info("Refresh scheduler fired")
                onTick()
            }
        }
        if let timer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    func stop() {
        if timer != nil {
            AppLogger.refresh.info("Stopping refresh scheduler")
        }
        timer?.invalidate()
        timer = nil
    }
}
