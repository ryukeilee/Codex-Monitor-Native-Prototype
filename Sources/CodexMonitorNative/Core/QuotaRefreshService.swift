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
        let enrichedSnapshot = await enrichResetCreditsDetails(for: realSnapshot)
        AppLogger.refresh.info("Real quota fetch succeeded")
        return enrichedSnapshot
    }

    private func enrichResetCreditsDetails(for snapshot: QuotaSnapshot) async -> QuotaSnapshot {
        do {
            let details = try await resetCreditsDetailProvider.fetchDetails()
            return QuotaSnapshot(
                weeklyQuotaPercent: snapshot.weeklyQuotaPercent,
                fiveHourQuotaPercent: snapshot.fiveHourQuotaPercent,
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
                schemaVersion: snapshot.schemaVersion
            )
        } catch {
            AppLogger.refresh.warning("Reset credits detail fetch unavailable (\(sanitizedResetCreditsError(error), privacy: .public)); falling back to app-server count only")
            return QuotaSnapshot(
                weeklyQuotaPercent: snapshot.weeklyQuotaPercent,
                fiveHourQuotaPercent: snapshot.fiveHourQuotaPercent,
                resetAvailableCount: snapshot.resetAvailableCount,
                resetCreditDetailsState: .unavailable,
                resetCreditDiagnostic: ResetCreditDiagnosticSnapshot(summary: sanitizedResetCreditsError(error)),
                resetCreditDetails: [],
                resetCreditStatusSummary: [],
                resetCreditTimeEntries: [],
                resetCreditRawFields: [],
                fiveHourResetAt: snapshot.fiveHourResetAt,
                resetBanks: snapshot.resetBanks,
                refreshedAt: snapshot.refreshedAt,
                dataSource: snapshot.dataSource,
                errorMessage: snapshot.errorMessage,
                schemaVersion: snapshot.schemaVersion
            )
        }
    }

    private func sanitizedResetCreditsError(_ error: Error) -> String {
        if let detailError = error as? ResetCreditsDetailError {
            return detailError.localizedDescription
        }

        return String(describing: type(of: error))
    }
}
