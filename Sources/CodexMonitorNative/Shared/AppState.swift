import Foundation

struct AppStateEvent: Equatable {
    let persistedState: PersistedAppState
    let presentationSnapshot: QuotaPresentationSnapshot

    init(
        snapshot: QuotaSnapshot,
        status: QuotaRefreshStatus,
        lastSuccessAt: Date?,
        lastAttemptAt: Date?,
        failureCount: Int,
        effectiveFiveHourResetAt: Date?,
        savedAt: Date = .now
    ) {
        let persistedState = PersistedAppState(
            snapshot: snapshot,
            status: status,
            lastSuccessAt: lastSuccessAt,
            lastAttemptAt: lastAttemptAt,
            failureCount: failureCount,
            savedAt: savedAt
        )
        self.persistedState = persistedState
        self.presentationSnapshot = QuotaPresentationSnapshot.make(
            snapshot: snapshot,
            status: status,
            lastSuccessAt: lastSuccessAt,
            lastAttemptAt: lastAttemptAt,
            effectiveFiveHourResetAt: effectiveFiveHourResetAt,
            savedAt: savedAt
        )
    }

    static let placeholder = AppStateEvent(
        snapshot: .notConnected,
        status: .noSnapshot,
        lastSuccessAt: nil,
        lastAttemptAt: nil,
        failureCount: 0,
        effectiveFiveHourResetAt: nil
    )
}

@MainActor
final class AppState: ObservableObject {
    enum RefreshTrigger {
        case manual
        case scheduled
        case wake
    }

    // MARK: - Published state

    @Published private(set) var stateEvent: AppStateEvent = .placeholder
    private(set) var snapshot: QuotaSnapshot = .notConnected
    private(set) var status: QuotaRefreshStatus = .noSnapshot
    var presentationSnapshot: QuotaPresentationSnapshot { stateEvent.presentationSnapshot }

    // MARK: - Diagnostics

    private(set) var lastAttemptAt: Date?
    private(set) var lastSuccessAt: Date?
    private(set) var failureCount: Int = 0
    private(set) var lastErrorSummary: String?
    private(set) var realQuotaHealth = RealQuotaHealthDiagnostic(
        kind: .waitingForFirstRequest,
        isUsingCachedSnapshot: false
    )

    // MARK: - Backoff

    /// The current backoff interval, if consecutive failures are escalating.
    /// Callers should use this as the timer interval instead of the default 5 min.
    private(set) var backoffInterval: TimeInterval = 300

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
    private var activeRefresh: ActiveRefresh?
    private var pendingRefresh: PendingRefresh?
    private var lastSettledStatus: QuotaRefreshStatus = .noSnapshot

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

        let persistedState = snapshotStore.loadState()
        if let persistedState {
            let stored = persistedState.snapshot
            snapshot = stored
            lastSuccessAt = persistedState.lastSuccessAt ?? (stored.dataSource == .real ? stored.refreshedAt : nil)
            lastAttemptAt = persistedState.lastAttemptAt
            failureCount = persistedState.failureCount
            consecutiveFailures = failureCount

            if stored.dataSource == .real {
                latestRealSnapshot = stored
                status = normalizedRestoredStatus(
                    persistedStatus: persistedState.status,
                    snapshot: stored
                )
                realQuotaHealth = RealQuotaHealthDiagnostic(
                    kind: .waitingForFirstRequest,
                    isUsingCachedSnapshot: true
                )
                AppLogger.snapshot.info("Restored real snapshot: weekly=\(stored.weeklyQuotaPercent)% fiveHour=\(stored.fiveHourQuotaPercent)%")
            } else {
                status = normalizedRestoredStatus(
                    persistedStatus: persistedState.status,
                    snapshot: stored
                )
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

        commitState()
        if status == .success {
            scheduleFreshnessCheck()
        }
    }

    deinit {
        activeRefresh?.resumeWaiters()
        pendingRefresh?.resumeWaiters()
    }

    // MARK: - Formatters

    var formattedRefreshedAt: String {
        StatusPopoverFormatting.shortTimestamp(for: snapshot.refreshedAt)
    }

    var displayStatus: QuotaRefreshStatus {
        resolvedDisplayStatus(for: status)
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
        enqueueRefresh(trigger: trigger)
    }

    func refreshNow(trigger: RefreshTrigger) async {
        await withCheckedContinuation { continuation in
            enqueueRefresh(trigger: trigger, waiter: continuation)
        }
    }

    private func enqueueRefresh(
        trigger: RefreshTrigger,
        waiter: CheckedContinuation<Void, Never>? = nil
    ) {
        guard activeRefresh == nil else {
            if pendingRefresh == nil {
                pendingRefresh = PendingRefresh(trigger: trigger)
            } else {
                pendingRefresh?.trigger = trigger
            }
            if let waiter {
                pendingRefresh?.waiters.append(waiter)
            }

            if status != .refreshing {
                markQueuedRefresh()
            }
            AppLogger.refresh.info("Coalesced \(self.triggerName(for: trigger), privacy: .public) refresh behind the active request")
            return
        }

        startManagedRefresh(
            trigger: trigger,
            waiters: waiter.map { [$0] } ?? []
        )
    }

    private func startManagedRefresh(
        trigger: RefreshTrigger,
        waiters: [CheckedContinuation<Void, Never>]
    ) {
        let refreshID = UUID()
        activeRefresh = ActiveRefresh(id: refreshID, waiters: waiters)
        let baselineSnapshot = beginRefresh(trigger: trigger)

        // A synchronous observer of the refreshing presentation can shut the
        // state down before the provider task is installed.
        guard activeRefresh?.id == refreshID,
              activeRefresh?.isInvalidated == false else {
            finishInvalidatedRefreshBeforeStart(refreshID: refreshID)
            return
        }

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
    }

    /// Cancels the managed refresh and immediately leaves presentation state usable.
    /// A provider that ignores cancellation keeps the physical single-flight slot
    /// until it really returns. Any later trigger is coalesced behind that barrier.
    func shutdown() {
        taskResources.refreshTask?.cancel()
        taskResources.freshnessTask?.cancel()
        taskResources.freshnessTask = nil

        pendingRefresh?.resumeWaiters()
        pendingRefresh = nil
        if var activeRefresh {
            activeRefresh.isInvalidated = true
            activeRefresh.resumeWaiters()
            self.activeRefresh = activeRefresh
        }

        guard status == .refreshing else { return }

        if let real = latestRealSnapshot {
            snapshot = real
        }
        status = resolvedDisplayStatus(for: lastSettledStatus)
        realQuotaHealth = RealQuotaHealthDiagnostic(
            kind: .waitingForFirstRequest,
            isUsingCachedSnapshot: latestRealSnapshot != nil
        )
        lastErrorSummary = nil
        commitState()
    }

    private func markQueuedRefresh() {
        enterRefreshingState(attemptedAt: nil)
    }

    private func beginRefresh(trigger: RefreshTrigger) -> QuotaSnapshot {
        let triggerName = triggerName(for: trigger)
        let baselineSnapshot = latestRealSnapshot ?? snapshot
        enterRefreshingState(attemptedAt: .now)
        AppLogger.refresh.info("Starting \(triggerName, privacy: .public) refresh (baseline source=\(baselineSnapshot.dataSource.rawValue, privacy: .public))")
        return baselineSnapshot
    }

    private func finishManagedRefresh(_ result: Result<QuotaSnapshot, Error>, refreshID: UUID) {
        guard var completedRefresh = activeRefresh,
              completedRefresh.id == refreshID else {
            return
        }

        taskResources.refreshTask = nil

        if completedRefresh.isInvalidated {
            activeRefresh = nil
            AppLogger.refresh.info("Discarded the cancelled refresh result")
            startPendingRefreshIfNeeded(carrying: [])
            return
        }

        if pendingRefresh != nil {
            activeRefresh = nil
            AppLogger.refresh.info("Discarded a superseded refresh result; starting the coalesced trailing request")
            startPendingRefreshIfNeeded(carrying: completedRefresh.waiters)
            return
        }

        activeRefresh = nil
        applyRefreshResult(result)
        completedRefresh.resumeWaiters()
    }

    private func finishInvalidatedRefreshBeforeStart(refreshID: UUID) {
        guard let activeRefresh, activeRefresh.id == refreshID else { return }
        self.activeRefresh = nil
        startPendingRefreshIfNeeded(carrying: [])
    }

    private func startPendingRefreshIfNeeded(
        carrying waiters: [CheckedContinuation<Void, Never>]
    ) {
        guard var pendingRefresh else {
            waiters.forEach { $0.resume() }
            return
        }

        self.pendingRefresh = nil
        pendingRefresh.waiters.insert(contentsOf: waiters, at: 0)
        startManagedRefresh(
            trigger: pendingRefresh.trigger,
            waiters: pendingRefresh.waiters
        )
    }

    private func applyRefreshResult(_ result: Result<QuotaSnapshot, Error>) {
        switch result {
        case .success(let refreshed):
            if refreshed.dataSource == .real {
                if let latestRealSnapshot, refreshed.refreshedAt < latestRealSnapshot.refreshedAt {
                    snapshot = latestRealSnapshot
                    status = latestRealSnapshot.isFresh(referenceDate: .now, staleAfterInterval: staleAfterInterval) ? .success : .stale
                    realQuotaHealth = RealQuotaHealthDiagnostic(kind: .requestSucceeded, isUsingCachedSnapshot: true)
                    commitState()
                    AppLogger.refresh.error("Ignored out-of-order real refresh refreshedAt=\(refreshed.refreshedAt.timeIntervalSince1970, format: .fixed(precision: 0)) olderThan=\(latestRealSnapshot.refreshedAt.timeIntervalSince1970, format: .fixed(precision: 0))")
                    return
                }
                latestRealSnapshot = refreshed
                consecutiveFailures = 0
                failureCount = 0
                lastSuccessAt = refreshed.refreshedAt
                lastErrorSummary = nil
                snapshot = refreshed
                status = .success
                realQuotaHealth = RealQuotaHealthDiagnostic(kind: .requestSucceeded, isUsingCachedSnapshot: false)
                setBackoffInterval(defaultInterval)
                commitState()
                scheduleFreshnessCheck()
                AppLogger.refresh.info("Real refresh succeeded: weekly=\(refreshed.weeklyQuotaPercent)% fiveHour=\(refreshed.fiveHourQuotaPercent)%")
            } else if let latestRealSnapshot {
                snapshot = latestRealSnapshot
                status = resolvedDisplayStatus(for: lastSettledStatus)
                realQuotaHealth = RealQuotaHealthDiagnostic(
                    kind: .waitingForFirstRequest,
                    isUsingCachedSnapshot: true
                )
                commitState()
                if status == .success {
                    scheduleFreshnessCheck()
                }
                AppLogger.refresh.info("Ignored mock refresh because a real snapshot is already cached")
            } else {
                snapshot = refreshed
                status = .demoMode
                lastErrorSummary = nil
                realQuotaHealth = RealQuotaHealthDiagnostic(kind: .waitingForFirstRequest, isUsingCachedSnapshot: false)
                commitState()
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
            commitState()
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
                commitState()
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
                self.commitState()
                AppLogger.refresh.info("Marked data stale after \(self.staleAfterInterval, format: .fixed(precision: 0)) seconds without a successful refresh")
            }
        }
    }

    private func commitState() {
        let resolvedStatus = resolvedDisplayStatus(for: status)
        if resolvedStatus != status {
            status = resolvedStatus
        }
        if resolvedStatus != .refreshing {
            lastSettledStatus = resolvedStatus
        }
        let event = AppStateEvent(
            snapshot: snapshot,
            status: resolvedStatus,
            lastSuccessAt: lastSuccessAt,
            lastAttemptAt: lastAttemptAt,
            failureCount: failureCount,
            effectiveFiveHourResetAt: effectiveFiveHourResetAt
        )
        snapshotStore.saveState(event.persistedState)
        stateEvent = event
    }

    private func enterRefreshingState(attemptedAt: Date?) {
        status = .refreshing
        if let attemptedAt {
            lastAttemptAt = attemptedAt
        }
        taskResources.freshnessTask?.cancel()
        realQuotaHealth = RealQuotaHealthDiagnostic(
            kind: .requestInProgress,
            isUsingCachedSnapshot: latestRealSnapshot != nil
        )
        commitState()
    }

    private func resolvedDisplayStatus(for status: QuotaRefreshStatus) -> QuotaRefreshStatus {
        if status == .success, isDataStale {
            return .stale
        }

        return status
    }

    private func normalizedRestoredStatus(
        persistedStatus: QuotaRefreshStatus,
        snapshot: QuotaSnapshot
    ) -> QuotaRefreshStatus {
        if snapshot.dataSource == .real {
            switch persistedStatus {
            case .networkFailed, .authRequired, .parseFailed:
                return persistedStatus
            case .idle, .refreshing, .success, .stale, .noSnapshot, .demoMode:
                return snapshot.isFresh(referenceDate: .now, staleAfterInterval: staleAfterInterval) ? .success : .stale
            }
        }

        switch persistedStatus {
        case .networkFailed, .authRequired, .parseFailed, .noSnapshot:
            return persistedStatus
        case .refreshing, .idle:
            return .noSnapshot
        case .success, .stale, .demoMode:
            return .demoMode
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

private struct ActiveRefresh {
    let id: UUID
    var waiters: [CheckedContinuation<Void, Never>]
    var isInvalidated = false

    mutating func resumeWaiters() {
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

private struct PendingRefresh {
    var trigger: AppState.RefreshTrigger
    var waiters: [CheckedContinuation<Void, Never>] = []

    mutating func resumeWaiters() {
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

private extension QuotaSnapshot {
    func isFresh(referenceDate: Date, staleAfterInterval: TimeInterval) -> Bool {
        referenceDate.timeIntervalSince(refreshedAt) < staleAfterInterval
    }
}
