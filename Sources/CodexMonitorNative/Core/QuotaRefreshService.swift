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
        if forceMock {
            AppLogger.refresh.info("CODEX_MONITOR_FORCE_MOCK=1; using mock data")
            let mockSnapshot = try await mockProvider.fetchQuota(basedOn: currentSnapshot)
            return mockSnapshot
        }

        // Try real data; do NOT fall back to mock on failure.
        // The caller (AppState) will classify the error and preserve
        // the last successful real snapshot.
        let realSnapshot = try await realProvider.fetchQuota()
        guard realSnapshot.dataSource != .real
                || realSnapshot.accountBoundary?.isValid == true else {
            throw RealQuotaError.accountIdentityUnavailable
        }
        let mergedSnapshot = realSnapshot.mergingPartial(with: currentSnapshot)
        let enrichedSnapshot = await enrichResetCreditsDetails(
            for: mergedSnapshot,
            fallingBackTo: currentSnapshot
        )
        AppLogger.refresh.info("Real quota fetch succeeded")
        return enrichedSnapshot
    }

    private func enrichResetCreditsDetails(
        for snapshot: QuotaSnapshot,
        fallingBackTo previousSnapshot: QuotaSnapshot
    ) async -> QuotaSnapshot {
        do {
            let details = try await resetCreditsDetailProvider.fetchDetails()
            return QuotaSnapshot(
                weeklyQuotaPercent: snapshot.weeklyQuotaPercent,
                fiveHourQuotaPercent: snapshot.fiveHourQuotaPercent,
                weeklyQuotaState: snapshot.weeklyQuotaState,
                fiveHourQuotaState: snapshot.fiveHourQuotaState,
                resetAvailableCount: details.availableCount ?? snapshot.resetAvailableCount,
                resetCreditDetailsState: .detailed,
                resetCreditDiagnostic: nil,
                resetCreditDetails: details.availableCredits,
                resetCreditStatusSummary: details.statusSummary,
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
        } catch {
            let reusableDetails = reusableResetCreditDetails(
                from: previousSnapshot,
                for: snapshot
            )
            let fallbackDescription = reusableDetails.isEmpty
                ? "app-server count only"
                : "app-server count with previous unexpired detail times"
            AppLogger.refresh.warning("Reset credits detail fetch unavailable (\(sanitizedResetCreditsError(error), privacy: .public)); using \(fallbackDescription, privacy: .public)")
            return QuotaSnapshot(
                weeklyQuotaPercent: snapshot.weeklyQuotaPercent,
                fiveHourQuotaPercent: snapshot.fiveHourQuotaPercent,
                weeklyQuotaState: snapshot.weeklyQuotaState,
                fiveHourQuotaState: snapshot.fiveHourQuotaState,
                resetAvailableCount: snapshot.resetAvailableCount,
                resetCreditDetailsState: .unavailable,
                resetCreditDiagnostic: ResetCreditDiagnosticSnapshot(summary: sanitizedResetCreditsError(error)),
                resetCreditDetails: reusableDetails,
                resetCreditStatusSummary: reusableDetails.isEmpty
                    ? []
                    : [ResetCreditStatusSummary(status: "available", count: reusableDetails.count)],
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
