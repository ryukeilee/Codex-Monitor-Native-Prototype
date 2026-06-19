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

    var isRefreshing: Bool { status == .refreshing }

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
                status = .success
                lastSuccessAt = stored.refreshedAt
                AppLogger.snapshot.info("Restored real snapshot: weekly=\(stored.weeklyQuotaPercent)% fiveHour=\(stored.fiveHourQuotaPercent)%")
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

    var formattedLastAttempt: String? {
        lastAttemptAt.map { StatusPopoverFormatting.shortTimestamp(for: $0) }
    }

    var formattedLastSuccess: String? {
        lastSuccessAt.map { StatusPopoverFormatting.shortTimestamp(for: $0) }
    }

    var dataSource: QuotaDataSource {
        snapshot.dataSource
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
                AppLogger.refresh.info("Real refresh succeeded: weekly=\(refreshed.weeklyQuotaPercent)% fiveHour=\(refreshed.fiveHourQuotaPercent)%")
            } else {
                // Mock success (dev mode)
                snapshot = refreshed
                status = .demoMode
                AppLogger.refresh.info("Mock refresh succeeded")
            }
        } catch {
            // Failure path — classify and preserve
            consecutiveFailures += 1
            failureCount = consecutiveFailures

            let classifiedStatus = classifyError(error)
            lastErrorSummary = safeErrorMessage(from: error)
            status = classifiedStatus

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
        let message = error.localizedDescription

        // Scrub sensitive tokens / headers from error messages
        let lower = message.lowercased()
        if lower.contains("bearer ") || lower.contains("authorization")
            || lower.contains("access_token") || lower.contains("api_key") {
            return "Authentication error"
        }
        if lower.contains("401") || lower.contains("403") {
            return "Authentication required"
        }
        if lower.contains("timed out") || lower.contains("timeout") {
            return "Request timed out"
        }

        return message
    }

    private func triggerName(for trigger: RefreshTrigger) -> String {
        switch trigger {
        case .manual: return "manual"
        case .scheduled: return "scheduled"
        case .wake: return "wake"
        }
    }
}
