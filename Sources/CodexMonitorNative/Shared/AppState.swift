import Foundation

@MainActor
final class AppState: ObservableObject {
    enum RefreshTrigger {
        case manual
        case scheduled
        case wake
    }

    enum Status: String {
        case normal
        case refreshing
        case failed

        var displayName: String {
            switch self {
            case .normal:
                return "Normal"
            case .refreshing:
                return "Refreshing"
            case .failed:
                return "Refresh Failed"
            }
        }
    }

    @Published private(set) var snapshot: QuotaSnapshot
    @Published private(set) var status: Status = .normal

    private let snapshotStore: SnapshotStore
    private let refreshAction: @Sendable (QuotaSnapshot) async throws -> QuotaSnapshot
    private let refreshDateFormatter: DateFormatter
    private var latestSuccessfulSnapshot: QuotaSnapshot

    init<T: QuotaRefreshing>(snapshotStore: SnapshotStore, refreshService: T) {
        self.snapshotStore = snapshotStore
        self.refreshAction = { snapshot in
            try await refreshService.refresh(basedOn: snapshot)
        }

        let initialSnapshot = snapshotStore.loadSnapshot() ?? .fallback
        snapshot = initialSnapshot
        latestSuccessfulSnapshot = initialSnapshot
        AppLogger.snapshot.info("Initialized app state weekly=\(initialSnapshot.weeklyQuotaPercent)% fiveHour=\(initialSnapshot.fiveHourQuotaPercent)%")

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        refreshDateFormatter = formatter
    }

    var formattedRefreshedAt: String {
        refreshDateFormatter.string(from: snapshot.refreshedAt)
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
        let baselineSnapshot = latestSuccessfulSnapshot
        AppLogger.refresh.info("Starting \(triggerName, privacy: .public) refresh from weekly=\(baselineSnapshot.weeklyQuotaPercent)% fiveHour=\(baselineSnapshot.fiveHourQuotaPercent)%")

        do {
            let refreshedSnapshot = try await refreshAction(baselineSnapshot)
            latestSuccessfulSnapshot = refreshedSnapshot
            snapshot = refreshedSnapshot
            status = .normal
            snapshotStore.saveSnapshot(refreshedSnapshot)
            AppLogger.refresh.info("Refresh succeeded weekly=\(refreshedSnapshot.weeklyQuotaPercent)% fiveHour=\(refreshedSnapshot.fiveHourQuotaPercent)%")
        } catch {
            snapshot = latestSuccessfulSnapshot
            status = .failed
            AppLogger.refresh.error("Refresh failed; continuing with last successful snapshot")
        }
    }
}
