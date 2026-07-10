import Foundation

@MainActor
final class AppState: ObservableObject {
    enum RefreshTrigger {
        case manual
        case scheduled
        case wake
    }

    // MARK: - Published state

    @Published private(set) var snapshot: QuotaSnapshot
    @Published private(set) var status: QuotaRefreshStatus = .noSnapshot

    // MARK: - Diagnostics

    @Published private(set) var lastAttemptAt: Date?
    @Published private(set) var lastSuccessAt: Date?
    @Published private(set) var failureCount: Int = 0
    @Published private(set) var lastErrorSummary: String?
    @Published private(set) var realQuotaHealth = RealQuotaHealthDiagnostic(
        kind: .waitingForFirstRequest,
        isUsingCachedSnapshot: false
    )

    // MARK: - Backoff

    /// The current backoff interval, if consecutive failures are escalating.
    /// Callers should use this as the timer interval instead of the default 5 min.
    @Published private(set) var backoffInterval: TimeInterval = 300

    /// Called when the backoff interval changes so the scheduler can adapt.
    var onBackoffChanged: (@MainActor (TimeInterval) -> Void)?

    // MARK: - Private

    private let snapshotStore: SnapshotStore
    private let refreshAction: @Sendable (QuotaSnapshot) async throws -> QuotaSnapshot
    private var latestRealSnapshot: QuotaSnapshot?
    private var consecutiveFailures: Int = 0
    private let defaultInterval: TimeInterval = 300
    private let staleAfterInterval: TimeInterval = 20 * 60
    private let taskResources = AppStateTaskResources()
    private var activeRefreshID: UUID?

    var isRefreshing: Bool { status == .refreshing }
    var isUsingCachedSnapshot: Bool { realQuotaHealth.isUsingCachedSnapshot }

    var isDataStale: Bool {
        guard snapshot.dataSource == .real, let lastSuccessAt else {
            return false
        }

        return Date.now.timeIntervalSince(lastSuccessAt) >= staleAfterInterval
    }

    // MARK: - Init

    init<T: QuotaRefreshing>(snapshotStore: SnapshotStore, refreshService: T) {
        self.snapshotStore = snapshotStore
        self.refreshAction = { snapshot in
            try await refreshService.refresh(basedOn: snapshot)
        }

        if let stored = snapshotStore.loadSnapshot() {
            if stored.dataSource == .real {
                latestRealSnapshot = stored
                snapshot = stored
                status = stored.isFresh(referenceDate: .now, staleAfterInterval: staleAfterInterval) ? .success : .stale
                lastSuccessAt = stored.refreshedAt
                realQuotaHealth = RealQuotaHealthDiagnostic(
                    kind: .waitingForFirstRequest,
                    isUsingCachedSnapshot: true
                )
                AppLogger.snapshot.info("Restored real snapshot: weekly=\(stored.weeklyQuotaPercent)% fiveHour=\(stored.fiveHourQuotaPercent)%")
                scheduleFreshnessCheck()
            } else {
                snapshot = stored
                status = .demoMode
                realQuotaHealth = RealQuotaHealthDiagnostic(
                    kind: .waitingForFirstRequest,
                    isUsingCachedSnapshot: false
                )
                AppLogger.snapshot.info("Restored mock snapshot (no real data yet)")
            }
        } else {
            snapshot = .notConnected
            status = .noSnapshot
            realQuotaHealth = RealQuotaHealthDiagnostic(
                kind: .waitingForFirstRequest,
                isUsingCachedSnapshot: false
            )
            AppLogger.snapshot.info("No persisted snapshot; starting in not-connected state")
        }

    }

    // MARK: - Formatters

    var formattedRefreshedAt: String {
        StatusPopoverFormatting.shortTimestamp(for: snapshot.refreshedAt)
    }

    var displayStatus: QuotaRefreshStatus {
        if status == .success, isDataStale {
            return .stale
        }

        return status
    }

    var formattedLastAttempt: String? {
        lastAttemptAt.map { StatusPopoverFormatting.shortTimestamp(for: $0) }
    }

    var formattedLastSuccess: String? {
        lastSuccessAt.map { StatusPopoverFormatting.shortTimestamp(for: $0) }
    }

    var dataSource: QuotaDataSource {
        snapshot.dataSource
    }

    var hasUsableRealQuotaData: Bool {
        snapshot.dataSource == .real &&
        status != .noSnapshot &&
        status != .demoMode &&
        status != .idle
    }

    var quotaDecision: QuotaDecision {
        QuotaDecisionEngine.evaluate(snapshot: snapshot, hasUsableRealData: hasUsableRealQuotaData)
    }

    var effectiveFiveHourResetAt: Date? {
        QuotaDecisionEngine.effectiveFiveHourResetAt(
            for: snapshot,
            hasUsableRealData: hasUsableRealQuotaData
        )
    }

    // MARK: - Refresh

    func refresh(trigger: RefreshTrigger) {
        _ = startManagedRefresh(trigger: trigger)
    }

    func refreshNow(trigger: RefreshTrigger) async {
        guard let refreshTask = startManagedRefresh(trigger: trigger) else {
            AppLogger.refresh.info("Ignored refresh request because a refresh is already queued or in progress")
            if let refreshTask = taskResources.refreshTask {
                await refreshTask.value
            }
            return
        }
        await refreshTask.value
    }

    @discardableResult
    private func startManagedRefresh(trigger: RefreshTrigger) -> Task<Void, Never>? {
        guard taskResources.refreshTask == nil else {
            return nil
        }
        let refreshID = UUID()
        activeRefreshID = refreshID
        let baselineSnapshot = beginRefresh(trigger: trigger)
        let refreshAction = refreshAction
        let refreshTask = Task { [weak self] in
            let result: Result<QuotaSnapshot, Error>
            do {
                result = .success(try await refreshAction(baselineSnapshot))
            } catch {
                result = .failure(error)
            }
            self?.finishManagedRefresh(result, refreshID: refreshID)
        }
        taskResources.refreshTask = refreshTask
        return refreshTask
    }

    /// Cancels the managed refresh and immediately leaves presentation state usable.
    /// A provider that ignores cancellation may finish later, but cannot retain the
    /// refresh slot or leave the app/widget in the refreshing state.
    func shutdown() {
        taskResources.refreshTask?.cancel()
        taskResources.refreshTask = nil
        taskResources.freshnessTask?.cancel()
        taskResources.freshnessTask = nil
        activeRefreshID = nil
        guard status == .refreshing else { return }

        if let real = latestRealSnapshot {
            snapshot = real
            status = real.isFresh(referenceDate: .now, staleAfterInterval: staleAfterInterval) ? .success : .stale
            realQuotaHealth = RealQuotaHealthDiagnostic(kind: .waitingForFirstRequest, isUsingCachedSnapshot: true)
        } else {
            status = snapshot.dataSource == .mock ? .demoMode : .noSnapshot
            realQuotaHealth = RealQuotaHealthDiagnostic(kind: .waitingForFirstRequest, isUsingCachedSnapshot: false)
        }
        lastErrorSummary = nil
    }

    private func beginRefresh(trigger: RefreshTrigger) -> QuotaSnapshot {
        let triggerName = triggerName(for: trigger)
        status = .refreshing
        lastAttemptAt = .now
        taskResources.freshnessTask?.cancel()
        realQuotaHealth = RealQuotaHealthDiagnostic(
            kind: .requestInProgress,
            isUsingCachedSnapshot: latestRealSnapshot != nil
        )

        let baselineSnapshot = latestRealSnapshot ?? snapshot
        AppLogger.refresh.info("Starting \(triggerName, privacy: .public) refresh (baseline source=\(baselineSnapshot.dataSource.rawValue, privacy: .public))")
        return baselineSnapshot
    }

    private func finishManagedRefresh(_ result: Result<QuotaSnapshot, Error>, refreshID: UUID) {
        guard activeRefreshID == refreshID else { return }
        applyRefreshResult(result)
        taskResources.refreshTask = nil
        activeRefreshID = nil
    }

    private func applyRefreshResult(_ result: Result<QuotaSnapshot, Error>) {
        switch result {
        case .success(let refreshed):
            if refreshed.dataSource == .real {
                latestRealSnapshot = refreshed
                consecutiveFailures = 0
                failureCount = 0
                lastSuccessAt = refreshed.refreshedAt
                lastErrorSummary = nil
                snapshot = refreshed
                status = .success
                realQuotaHealth = RealQuotaHealthDiagnostic(kind: .requestSucceeded, isUsingCachedSnapshot: false)
                setBackoffInterval(defaultInterval)
                snapshotStore.saveSnapshot(refreshed)
                scheduleFreshnessCheck()
                AppLogger.refresh.info("Real refresh succeeded: weekly=\(refreshed.weeklyQuotaPercent)% fiveHour=\(refreshed.fiveHourQuotaPercent)%")
            } else {
                snapshot = refreshed
                status = .demoMode
                lastErrorSummary = nil
                realQuotaHealth = RealQuotaHealthDiagnostic(kind: .waitingForFirstRequest, isUsingCachedSnapshot: false)
                AppLogger.refresh.info("Mock refresh succeeded")
            }
        case .failure(let error):
            consecutiveFailures += 1
            failureCount = consecutiveFailures
            let classifiedStatus = classifyError(error)
            lastErrorSummary = safeErrorMessage(from: error)
            status = classifiedStatus
            taskResources.freshnessTask?.cancel()
            realQuotaHealth = healthDiagnostic(for: error)
            if let real = latestRealSnapshot { snapshot = real }
            setBackoffInterval(backoffFor(consecutiveFailures: consecutiveFailures))
            AppLogger.refresh.error("Refresh failed (consecutive=\(self.consecutiveFailures)) status=\(classifiedStatus.rawValue, privacy: .public) backoff=\(self.backoffInterval)s")
        }
    }

    // MARK: - Error classification

    private func classifyError(_ error: Error) -> QuotaRefreshStatus {
        if let realError = error as? RealQuotaError {
            if case .codexNotFound = realError, latestRealSnapshot != nil {
                return .networkFailed
            }
            return realError.refreshStatus
        }

        if error is MockRefreshError {
            return .networkFailed
        }

        let message = error.localizedDescription.lowercased()
        if message.contains("auth") || message.contains("401") || message.contains("403") {
            return .authRequired
        }
        if message.contains("parse") || message.contains("decode") || message.contains("malformed") {
            return .parseFailed
        }

        return .networkFailed
    }

    private func healthDiagnostic(for error: Error) -> RealQuotaHealthDiagnostic {
        let usingCachedSnapshot = latestRealSnapshot != nil

        if let realError = error as? RealQuotaError {
            return RealQuotaHealthDiagnostic(
                kind: realError.healthKind,
                isUsingCachedSnapshot: usingCachedSnapshot
            )
        }

        if error is MockRefreshError {
            return RealQuotaHealthDiagnostic(
                kind: .rpcRejected,
                isUsingCachedSnapshot: usingCachedSnapshot
            )
        }

        let message = error.localizedDescription.lowercased()
        if message.contains("auth") || message.contains("401") || message.contains("403") || message.contains("login") {
            return RealQuotaHealthDiagnostic(
                kind: .loginRequired,
                isUsingCachedSnapshot: usingCachedSnapshot
            )
        }
        if message.contains("timeout") || message.contains("timed out") {
            return RealQuotaHealthDiagnostic(
                kind: .requestTimedOut,
                isUsingCachedSnapshot: usingCachedSnapshot
            )
        }
        if message.contains("parse") || message.contains("decode") || message.contains("malformed") {
            return RealQuotaHealthDiagnostic(
                kind: .responseInvalid,
                isUsingCachedSnapshot: usingCachedSnapshot
            )
        }

        return RealQuotaHealthDiagnostic(
            kind: .rpcRejected,
            isUsingCachedSnapshot: usingCachedSnapshot
        )
    }

    // MARK: - Backoff

    private func backoffFor(consecutiveFailures count: Int) -> TimeInterval {
        switch count {
        case 0...1:
            return defaultInterval       // 5 min
        case 2:
            return 600                   // 10 min
        default:
            return 900                   // 15 min
        }
    }

    private func setBackoffInterval(_ newInterval: TimeInterval) {
        guard backoffInterval != newInterval else { return }
        backoffInterval = newInterval
        onBackoffChanged?(newInterval)
    }

    // MARK: - Safe error messages

    private func safeErrorMessage(from error: Error) -> String {
        switch error {
        case let realError as RealQuotaError:
            return shortMessage(for: realError)
        case is MockRefreshError:
            return "数据源不可达"
        default:
            let message = error.localizedDescription.lowercased()
            if message.contains("auth") || message.contains("login") {
                return "登录会话不可用"
            }
            if message.contains("timeout") || message.contains("timed out") {
                return "数据源超时"
            }
            return "上次刷新失败"
        }
    }

    private func shortMessage(for error: RealQuotaError) -> String {
        switch error {
        case .codexNotFound:
            return "未找到 codex 可执行文件"
        case .spawnFailed:
            return "启动 codex 失败"
        case .handshakeFailed:
            return "Codex 握手失败"
        case .requestTimedOut:
            return "请求超时"
        case .processExited:
            return "Codex 提前退出"
        case .rpcError(let message):
            let lower = message.lowercased()
            if lower.contains("auth") || lower.contains("unauthorized") || lower.contains("login") {
                return "需要重新登录 Codex"
            }
            return "RPC 请求失败"
        case .parseFailed, .noUsableRateLimits:
            return "响应不可解析"
        }
    }

    private func scheduleFreshnessCheck() {
        taskResources.freshnessTask?.cancel()

        guard snapshot.dataSource == .real, let lastSuccessAt else {
            return
        }

        let elapsed = Date.now.timeIntervalSince(lastSuccessAt)
        let remaining = staleAfterInterval - elapsed

        if remaining <= 0 {
            if status == .success {
                status = .stale
            }
            return
        }

        taskResources.freshnessTask = Task { [weak self] in
            let delay = UInt64(remaining * 1_000_000_000)
            do {
                try await Task.sleep(nanoseconds: delay)
            } catch {
                return
            }

            await MainActor.run {
                guard let self else { return }
                guard self.status == .success, self.isDataStale else { return }

                self.status = .stale
                self.lastErrorSummary = nil
                AppLogger.refresh.info("Marked data stale after \(self.staleAfterInterval, format: .fixed(precision: 0)) seconds without a successful refresh")
            }
        }
    }

    private func triggerName(for trigger: RefreshTrigger) -> String {
        switch trigger {
        case .manual: return "manual"
        case .scheduled: return "scheduled"
        case .wake: return "wake"
        }
    }

}

private final class AppStateTaskResources {
    var freshnessTask: Task<Void, Never>?
    var refreshTask: Task<Void, Never>?

    deinit {
        freshnessTask?.cancel()
        refreshTask?.cancel()
    }
}

private extension QuotaSnapshot {
    func isFresh(referenceDate: Date, staleAfterInterval: TimeInterval) -> Bool {
        referenceDate.timeIntervalSince(refreshedAt) < staleAfterInterval
    }
}
