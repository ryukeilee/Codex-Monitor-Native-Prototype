import Foundation

protocol QuotaRefreshing: Sendable {
    func refresh(basedOn currentSnapshot: QuotaSnapshot) async throws -> QuotaSnapshot
}

struct QuotaRefreshService: QuotaRefreshing {
    private let realProvider: any RealQuotaRefreshing
    private let resetCreditsDetailProvider: any ResetCreditsDetailRefreshing
    private let mockProvider: MockQuotaProvider
    private let forceMock: Bool

    init(realProvider: any RealQuotaRefreshing = RealQuotaProvider(),
         resetCreditsDetailProvider: any ResetCreditsDetailRefreshing = ResetCreditsDetailProvider(),
         mockProvider: MockQuotaProvider = MockQuotaProvider()) {
        self.realProvider = realProvider
        self.resetCreditsDetailProvider = resetCreditsDetailProvider
        self.mockProvider = mockProvider
        self.forceMock = ProcessInfo.processInfo.environment["CODEX_MONITOR_FORCE_MOCK"] == "1"
    }

    func refresh(basedOn currentSnapshot: QuotaSnapshot) async throws -> QuotaSnapshot {
        try Task.checkCancellation()

        if forceMock {
            AppLogger.refresh.info("CODEX_MONITOR_FORCE_MOCK=1; using mock data")
            let mockSnapshot = try await mockProvider.fetchQuota(basedOn: currentSnapshot)
            try Task.checkCancellation()
            return mockSnapshot
        }

        // Try real data; do NOT fall back to mock on failure.
        // The caller (AppState) will classify the error and preserve
        // the last successful real snapshot.
        let realSnapshot = try await realProvider.fetchQuota()
        try Task.checkCancellation()
        guard realSnapshot.dataSource != .real
                || realSnapshot.accountBoundary?.isValid == true else {
            throw RealQuotaError.accountIdentityUnavailable
        }
        let mergedSnapshot = realSnapshot.mergingPartial(with: currentSnapshot)
        let enrichedSnapshot = try await enrichResetCreditsDetails(
            for: mergedSnapshot,
            fallingBackTo: currentSnapshot
        )
        try Task.checkCancellation()
        AppLogger.refresh.info("Real quota fetch succeeded")
        return enrichedSnapshot
    }

    private func enrichResetCreditsDetails(
        for snapshot: QuotaSnapshot,
        fallingBackTo previousSnapshot: QuotaSnapshot
    ) async throws -> QuotaSnapshot {
        try Task.checkCancellation()

        do {
            guard let accountBoundary = snapshot.accountBoundary,
                  accountBoundary.isValid else {
                throw ResetCreditsDetailError.accountBoundaryMismatch
            }
            let details = try await resetCreditsDetailProvider.fetchDetails(
                for: accountBoundary
            )
            try Task.checkCancellation()
            return projectingResetCredits(
                onto: snapshot,
                state: .detailed,
                availableCount: details.availableCount ?? snapshot.resetAvailableCount,
                details: details.availableCredits,
                statusSummary: details.statusSummary
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            let reusableDetails = reusableResetCreditDetails(
                from: previousSnapshot,
                for: snapshot
            )
            if case ResetCreditsDetailError.noAvailableCredits = error,
               reusableDetails.isEmpty {
                // The server explicitly reported no available reset credits:
                // that is a normal account state, not a detail fetch failure.
                // Keep the neutral app-server count presentation.
                return projectingResetCredits(
                    onto: snapshot,
                    state: .appServerCountOnly,
                    availableCount: snapshot.resetAvailableCount
                )
            }

            // The same sanitized reason is logged and persisted, so it is
            // formatted once instead of twice.
            let diagnosticSummary = sanitizedResetCreditsError(error)
            let fallbackDescription = reusableDetails.isEmpty
                ? "app-server count only"
                : "app-server count with previous unexpired detail times"
            AppLogger.refresh.warning("Reset credits detail fetch unavailable (\(diagnosticSummary, privacy: .public)); using \(fallbackDescription, privacy: .public)")
            return projectingResetCredits(
                onto: snapshot,
                state: .unavailable,
                availableCount: snapshot.resetAvailableCount,
                diagnostic: ResetCreditDiagnosticSnapshot(summary: diagnosticSummary),
                details: reusableDetails,
                statusSummary: reusableDetails.isEmpty
                    ? []
                    : [ResetCreditStatusSummary(status: "available", count: reusableDetails.count)]
            )
        }
    }

    /// Shared projection for every reset-credit detail outcome.
    ///
    /// "Details available", "server reported no available credits", and
    /// "detail fetch failed" all describe the same refreshed quota snapshot;
    /// only the reset-credit fields differ. Keeping the projection in one place
    /// means a new quota field is carried through here once, instead of in each
    /// outcome, and cannot be forgotten in one of them.
    ///
    /// The detail provider is authoritative for this path, so the raw
    /// app-server reset-credit fields and time entries are always cleared.
    private func projectingResetCredits(
        onto snapshot: QuotaSnapshot,
        state: ResetCreditDetailsState,
        availableCount: Int?,
        diagnostic: ResetCreditDiagnosticSnapshot? = nil,
        details: [ResetCreditDetailSnapshot] = [],
        statusSummary: [ResetCreditStatusSummary] = []
    ) -> QuotaSnapshot {
        QuotaSnapshot(
            weeklyQuotaPercent: snapshot.weeklyQuotaPercent,
            fiveHourQuotaPercent: snapshot.fiveHourQuotaPercent,
            weeklyQuotaState: snapshot.weeklyQuotaState,
            fiveHourQuotaState: snapshot.fiveHourQuotaState,
            resetAvailableCount: availableCount,
            resetCreditDetailsState: state,
            resetCreditDiagnostic: diagnostic,
            resetCreditDetails: details,
            resetCreditStatusSummary: statusSummary,
            resetCreditTimeEntries: [],
            resetCreditRawFields: [],
            fiveHourResetAt: snapshot.fiveHourResetAt,
            resetBanks: snapshot.resetBanks,
            refreshedAt: snapshot.refreshedAt,
            dataSource: snapshot.dataSource,
            errorMessage: snapshot.errorMessage,
            schemaVersion: snapshot.schemaVersion,
            quotaWindows: snapshot.quotaWindows,
            accountBoundary: snapshot.accountBoundary
        )
    }

    private func reusableResetCreditDetails(
        from previousSnapshot: QuotaSnapshot,
        for refreshedSnapshot: QuotaSnapshot
    ) -> [ResetCreditDetailSnapshot] {
        guard previousSnapshot.dataSource == .real,
              let accountBoundary = refreshedSnapshot.accountBoundary,
              accountBoundary.matches(previousSnapshot.accountBoundary),
              let refreshedCount = refreshedSnapshot.resetAvailableCount,
              refreshedCount > 0,
              previousSnapshot.resetAvailableCount == refreshedCount else {
            return []
        }

        return previousSnapshot.resetCreditDetails.filter { detail in
            detail.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "available" &&
            detail.expiresAt.map { $0 > refreshedSnapshot.refreshedAt } == true
        }
    }

    private func sanitizedResetCreditsError(_ error: Error) -> String {
        if let detailError = error as? ResetCreditsDetailError {
            return detailError.localizedDescription
        }

        return String(describing: type(of: error))
    }
}
