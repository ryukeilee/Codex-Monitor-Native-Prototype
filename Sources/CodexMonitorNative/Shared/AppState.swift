import Foundation

@MainActor
final class AppState: ObservableObject {
    enum RefreshTrigger {
        case manual
        case scheduled
        case wake
    }

    @Published private(set) var snapshot: QuotaSnapshot
    @Published private(set) var status: QuotaRefreshStatus = .notConnected

    private let snapshotStore: SnapshotStore
    private let refreshAction: @Sendable (QuotaSnapshot) async throws -> QuotaSnapshot
    private let refreshDateFormatter: DateFormatter

    private var latestRealSnapshot: QuotaSnapshot?
    private var latestMockSnapshot: QuotaSnapshot?
    private var consecutiveFailures: Int = 0

    var isRefreshing: Bool { status == .refreshing }

    init<T: QuotaRefreshing>(snapshotStore: SnapshotStore, refreshService: T) {
        self.snapshotStore = snapshotStore
        self.refreshAction = { snapshot in
            try await refreshService.refresh(basedOn: snapshot)
        }

        if let stored = snapshotStore.loadSnapshot() {
            if stored.dataSource == .real {
                latestRealSnapshot = stored
                snapshot = stored
                status = .normal
                AppLogger.snapshot.info("Restored real snapshot: weekly=\(stored.weeklyQuotaPercent)% fiveHour=\(stored.fiveHourQuotaPercent)%")
            } else {
                latestMockSnapshot = stored
                snapshot = stored
                status = .notConnected
                AppLogger.snapshot.info("Restored mock snapshot (no real data yet)")
            }
        } else {
            snapshot = .notConnected
            status = .notConnected
            AppLogger.snapshot.info("No persisted snapshot; starting in not-connected state")
        }

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        refreshDateFormatter = formatter
    }

    var formattedRefreshedAt: String {
        refreshDateFormatter.string(from: snapshot.refreshedAt)
    }

    var dataSource: QuotaDataSource {
        snapshot.dataSource
    }

    var lastError: String? {
        snapshot.errorMessage
    }

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

        let triggerName: String
        switch trigger {
        case .manual:
            triggerName = "manual"
        case .scheduled:
            triggerName = "scheduled"
        case .wake:
            triggerName = "wake"
        }

        status = .refreshing
        let baselineSnapshot = latestRealSnapshot ?? latestMockSnapshot ?? snapshot
        AppLogger.refresh.info("Starting \(triggerName, privacy: .public) refresh (baseline source=\(baselineSnapshot.dataSource.rawValue, privacy: .public))")

        do {
            let refreshed = try await refreshAction(baselineSnapshot)

            if refreshed.dataSource == .real {
                latestRealSnapshot = refreshed
                consecutiveFailures = 0
            } else {
                latestMockSnapshot = refreshed
            }

            snapshot = refreshed
            status = refreshed.dataSource == .real ? .normal : .notConnected
            snapshotStore.saveSnapshot(refreshed)

            AppLogger.refresh.info("Refresh succeeded source=\(refreshed.dataSource.rawValue, privacy: .public) weekly=\(refreshed.weeklyQuotaPercent)% fiveHour=\(refreshed.fiveHourQuotaPercent)%")
        } catch {
            consecutiveFailures += 1

            // Keep displaying last successful data, don't clear
            if let real = latestRealSnapshot {
                snapshot = real
            } else if let mock = latestMockSnapshot {
                snapshot = mock
            }
            // else keep current snapshot (notConnected)

            status = (latestRealSnapshot != nil || latestMockSnapshot != nil) ? .failed : .notConnected

            let safeError = safeErrorMessage(from: error)
            AppLogger.refresh.error("Refresh failed (consecutive=\(self.consecutiveFailures)): \(safeError, privacy: .public)")
        }
    }

    private func safeErrorMessage(from error: Error) -> String {
        let message = error.localizedDescription

        // Scrub any potential tokens or keys from error messages
        if message.contains("Bearer ") || message.contains("Authorization") {
            return "Authentication error"
        }
        if message.contains("401") || message.contains("403") {
            return "Authentication required"
        }
        if message.contains("timed out") || message.contains("timeout") {
            return "Request timed out"
        }

        return message
    }
}
