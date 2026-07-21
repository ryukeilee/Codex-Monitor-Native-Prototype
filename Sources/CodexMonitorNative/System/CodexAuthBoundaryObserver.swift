import Foundation

@MainActor
protocol CodexAuthBoundaryRepeatingTask: AnyObject {
    func cancel()
}

@MainActor
protocol CodexAuthBoundaryRepeatingScheduling: AnyObject {
    func scheduleRepeating(
        every interval: TimeInterval,
        handler: @escaping @MainActor () -> Void
    ) -> any CodexAuthBoundaryRepeatingTask
}

@MainActor
final class CodexAuthBoundaryObserver {
    private let pollInterval: TimeInterval
    private let boundaryProvider: @MainActor () -> QuotaAccountBoundary?
    private let onChange: @MainActor () -> Void
    private let scheduler: any CodexAuthBoundaryRepeatingScheduling
    private var scheduledTask: (any CodexAuthBoundaryRepeatingTask)?
    private var lastBoundary: QuotaAccountBoundary?
    private var generation = 0

    private(set) var isRunning = false

    init(
        pollInterval: TimeInterval = 1,
        boundaryProvider: @escaping @MainActor () -> QuotaAccountBoundary? = {
            CodexAuthIdentityReader.currentBoundary()
        },
        scheduler: any CodexAuthBoundaryRepeatingScheduling = DispatchMainRepeatingScheduler(),
        onChange: @escaping @MainActor () -> Void
    ) {
        self.pollInterval = max(0.001, pollInterval)
        self.boundaryProvider = boundaryProvider
        self.scheduler = scheduler
        self.onChange = onChange
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        lastBoundary = boundaryProvider()
        generation &+= 1
        let currentGeneration = generation

        scheduledTask = scheduler.scheduleRepeating(every: pollInterval) { [weak self] in
            self?.poll(generation: currentGeneration)
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        generation &+= 1
        scheduledTask?.cancel()
        scheduledTask = nil
        lastBoundary = nil
    }

    private func poll(generation: Int) {
        guard isRunning, generation == self.generation else { return }
        let currentBoundary = boundaryProvider()
        guard currentBoundary != lastBoundary else { return }
        lastBoundary = currentBoundary
        onChange()
    }
}

@MainActor
private final class DispatchMainRepeatingScheduler: CodexAuthBoundaryRepeatingScheduling {
    func scheduleRepeating(
        every interval: TimeInterval,
        handler: @escaping @MainActor () -> Void
    ) -> any CodexAuthBoundaryRepeatingTask {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
            deadline: .now() + interval,
            repeating: interval,
            leeway: .milliseconds(100)
        )
        // Passing a global-actor closure directly through Dispatch's block
        // bridge can crash while copying the block on macOS. The source runs
        // on the main queue, so enter MainActor explicitly from a plain block.
        timer.setEventHandler {
            MainActor.assumeIsolated {
                handler()
            }
        }
        timer.resume()
        return DispatchMainRepeatingTask(timer: timer)
    }
}

@MainActor
private final class DispatchMainRepeatingTask: CodexAuthBoundaryRepeatingTask {
    private var timer: DispatchSourceTimer?

    init(timer: DispatchSourceTimer) {
        self.timer = timer
    }

    func cancel() {
        timer?.cancel()
        timer = nil
    }
}
