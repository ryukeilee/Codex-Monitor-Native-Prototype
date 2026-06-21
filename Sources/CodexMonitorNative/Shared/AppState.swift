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
    private var freshnessTask: Task<Void, Never>?

    var isRefreshing: Bool { status == .refreshing }
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
                AppLogger.snapshot.info("Restored real snapshot: weekly=\(stored.weeklyQuotaPercent)% fiveHour=\(stored.fiveHourQuotaPercent)%")
                scheduleFreshnessCheck()
            } else {
                snapshot = stored
                status = .demoMode
                AppLogger.snapshot.info("Restored mock snapshot (no real data yet)")
            }
        } else {
            snapshot = .notConnected
            status = .noSnapshot
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
        Task {
            await refreshNow(trigger: trigger)
        }
    }

    func refreshNow(trigger: RefreshTrigger) async {
        guard status != .refreshing else {
            AppLogger.refresh.info("Ignored refresh request because a refresh is already in progress")
            return
        }

        let triggerName = triggerName(for: trigger)

        status = .refreshing
        lastAttemptAt = .now
        freshnessTask?.cancel()

        let baselineSnapshot = latestRealSnapshot ?? snapshot
        AppLogger.refresh.info("Starting \(triggerName, privacy: .public) refresh (baseline source=\(baselineSnapshot.dataSource.rawValue, privacy: .public))")

        do {
            let refreshed = try await refreshAction(baselineSnapshot)

            // Success path
            if refreshed.dataSource == .real {
                latestRealSnapshot = refreshed
                consecutiveFailures = 0
                failureCount = 0
                lastSuccessAt = refreshed.refreshedAt
                lastErrorSummary = nil
                snapshot = refreshed
                status = .success
                backoffInterval = defaultInterval
                snapshotStore.saveSnapshot(refreshed)
                scheduleFreshnessCheck()
                AppLogger.refresh.info("Real refresh succeeded: weekly=\(refreshed.weeklyQuotaPercent)% fiveHour=\(refreshed.fiveHourQuotaPercent)%")
            } else {
                // Mock success (dev mode)
                snapshot = refreshed
                status = .demoMode
                lastErrorSummary = nil
                AppLogger.refresh.info("Mock refresh succeeded")
            }
        } catch {
            // Failure path — classify and preserve
            consecutiveFailures += 1
            failureCount = consecutiveFailures

            let classifiedStatus = classifyError(error)
            lastErrorSummary = safeErrorMessage(from: error)
            status = classifiedStatus
            freshnessTask?.cancel()

            // Always keep the last successful real snapshot visible
            if let real = latestRealSnapshot {
                snapshot = real
            }
            // else: keep current snapshot (may be notConnected or mock)

            // Escalate backoff
            backoffInterval = backoffFor(consecutiveFailures: consecutiveFailures)
            onBackoffChanged?(backoffInterval)

            AppLogger.refresh.error("Refresh failed (consecutive=\(self.consecutiveFailures)) status=\(classifiedStatus.rawValue, privacy: .public) backoff=\(self.backoffInterval)s")
        }
    }

    // MARK: - Error classification

    private func classifyError(_ error: Error) -> QuotaRefreshStatus {
        if let realError = error as? RealQuotaError {
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
            return "未找到数据源"
        case .spawnFailed, .handshakeFailed, .requestTimedOut, .processExited:
            return "数据源不可达"
        case .rpcError(let message):
            let lower = message.lowercased()
            if lower.contains("auth") || lower.contains("unauthorized") || lower.contains("login") {
                return "登录会话不可用"
            }
            return "数据源拒绝请求"
        case .parseFailed, .noUsableRateLimits:
            return "数据源返回异常"
        }
    }

    private func scheduleFreshnessCheck() {
        freshnessTask?.cancel()

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

        freshnessTask = Task { [weak self] in
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

    deinit {
        freshnessTask?.cancel()
    }
}

private extension QuotaSnapshot {
    func isFresh(referenceDate: Date, staleAfterInterval: TimeInterval) -> Bool {
        referenceDate.timeIntervalSince(refreshedAt) < staleAfterInterval
    }
}
