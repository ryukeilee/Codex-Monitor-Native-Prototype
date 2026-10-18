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
        boundaryProvider: @escaping @MainActor () -> QuotaAccountBoundary? = CodexAuthBoundaryObserver
            .makeDefaultAuthBoundaryProvider(),
        scheduler: any CodexAuthBoundaryRepeatingScheduling = DispatchMainRepeatingScheduler(),
        onChange: @escaping @MainActor () -> Void
    ) {
        self.pollInterval = max(0.001, pollInterval)
        self.boundaryProvider = boundaryProvider
        self.scheduler = scheduler
        self.onChange = onChange
    }

    /// 默认边界提供者的工厂。默认参数表达式在每次 `init` 调用时求值一次，所以这里只创建
    /// **一个** poller 并让返回的闭包持有它；不能把 `CodexAuthBoundaryPoller().currentBoundary()`
    /// 直接写成默认值，那样每次求值都会新建 poller，memo 永远不命中。
    static func makeDefaultAuthBoundaryProvider() -> @MainActor () -> QuotaAccountBoundary? {
        let poller = CodexAuthBoundaryPoller()
        return { poller.currentBoundary() }
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

/// 以原始字节为键复用已解析出的边界。
///
/// `CodexAuthIdentityReader.parse(data:)` 是 `data` 的纯函数（只读取入参和文件内的静态常量），
/// 因此同一份字节重复解析必然得到同一答案，命中时跳过解析不可能改变任何可观察结果。
/// 每次调用仍然重新解析 `CODEX_HOME` 并真实读取 `auth.json`，所以字节变化在同一次轮询被重新
/// 解析并上报；文件不可读时仍然返回 `nil`，不会退回缓存值。
/// memo 只属于单个轮询者：没有全局状态，也没有跨 observer 共享。
@MainActor
final class CodexAuthBoundaryPoller {
    private let readData: @MainActor () -> Data?
    private let parse: @MainActor (Data) -> QuotaAccountBoundary?
    private var lastData: Data?
    private var lastBoundary: QuotaAccountBoundary?

    init(
        readData: @escaping @MainActor () -> Data? = { CodexAuthIdentityReader.currentAuthData() },
        parse: @escaping @MainActor (Data) -> QuotaAccountBoundary? = {
            CodexAuthIdentityReader.parse(data: $0)
        }
    ) {
        self.readData = readData
        self.parse = parse
    }

    func currentBoundary() -> QuotaAccountBoundary? {
        let data = readData()
        guard data != lastData else { return lastBoundary }
        lastData = data
        lastBoundary = data.flatMap(parse)
        return lastBoundary
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
