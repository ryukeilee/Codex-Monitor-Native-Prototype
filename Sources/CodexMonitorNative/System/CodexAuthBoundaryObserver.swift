import Foundation

@MainActor
final class CodexAuthBoundaryObserver {
    private let pollInterval: TimeInterval
    private let boundaryProvider: @MainActor () -> QuotaAccountBoundary?
    private let onChange: @MainActor () -> Void
    private var timer: DispatchSourceTimer?
    private var lastBoundary: QuotaAccountBoundary?

    private(set) var isRunning = false

    init(
        pollInterval: TimeInterval = 1,
        boundaryProvider: @escaping @MainActor () -> QuotaAccountBoundary? = {
            CodexAuthIdentityReader.currentBoundary()
        },
        onChange: @escaping @MainActor () -> Void
    ) {
        self.pollInterval = max(0.001, pollInterval)
        self.boundaryProvider = boundaryProvider
        self.onChange = onChange
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        lastBoundary = boundaryProvider()

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
            deadline: .now() + pollInterval,
            repeating: pollInterval,
            leeway: .milliseconds(100)
        )
        timer.setEventHandler { [weak self] in
            self?.poll()
        }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        timer?.cancel()
        timer = nil
        lastBoundary = nil
    }

    private func poll() {
        guard isRunning else { return }
        let currentBoundary = boundaryProvider()
        guard currentBoundary != lastBoundary else { return }
        lastBoundary = currentBoundary
        onChange()
    }
}
