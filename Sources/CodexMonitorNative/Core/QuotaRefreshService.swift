import Foundation

protocol QuotaRefreshing: Sendable {
    func refresh(basedOn currentSnapshot: QuotaSnapshot) async throws -> QuotaSnapshot
}

struct QuotaRefreshService: QuotaRefreshing {
    private let realProvider: any RealQuotaRefreshing
    private let resetCreditsDetailProvider: any ResetCreditsDetailRefreshing
    private let mockProvider: MockQuotaProvider
    private let forceMock: Bool

    /// Reads the account/session identity `auth.json` currently holds. The reset-credit detail leg
    /// runs before the RPC leg proves an identity, so it is gated on the identity it was fetched
    /// under instead of on the order of the two legs.
    private let currentAccountBoundary: @Sendable () -> QuotaAccountBoundary?

    init(realProvider: any RealQuotaRefreshing = RealQuotaProvider(),
         resetCreditsDetailProvider: any ResetCreditsDetailRefreshing = ResetCreditsDetailProvider(),
         mockProvider: MockQuotaProvider = MockQuotaProvider(),
         currentAccountBoundary: @escaping @Sendable () -> QuotaAccountBoundary? = {
             CodexAuthIdentityReader.currentBoundary()
         }) {
        self.realProvider = realProvider
        self.resetCreditsDetailProvider = resetCreditsDetailProvider
        self.mockProvider = mockProvider
        self.forceMock = ProcessInfo.processInfo.environment["CODEX_MONITOR_FORCE_MOCK"] == "1"
        self.currentAccountBoundary = currentAccountBoundary
    }

    /// Refreshes quota with the reset-credit detail leg running concurrently with the RPC leg.
    ///
    /// The detail leg needs only the account/session identity, not the quota values, so the two
    /// legs overlap instead of running in series. The identity guarantee the serial order used to
    /// provide is kept by an exact identity gate: a prefetched outcome is published only when the
    /// identity its request was bound to matches the identity the refreshed snapshot proves.
    ///
    /// Behaviour equivalence with the serial composition:
    /// - RPC (or identity validation) failure: the detail request that started is cancelled and
    ///   drained by the scope; the refresh fails with the RPC error and publishes no snapshot.
    /// - RPC ok + details: `.detailed` with the same fields.
    /// - RPC ok + server reports no available credits without reusable details:
    ///   `.appServerCountOnly`.
    /// - RPC ok + detail failure: `.unavailable` with the same persisted diagnostic and the same
    ///   reusable-details fallback.
    /// - RPC ok + detail cancellation: `CancellationError`.
    /// - No usable `auth.json` identity when the detail leg starts: the request runs after the RPC
    ///   leg, exactly as before.
    /// - Identity change racing the refresh: results produced under the old identity are dropped
    ///   (fail-closed) instead of being published under the new one.
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
        async let prefetchedResetCredits = prefetchResetCreditsDetails()

        let realSnapshot = try await realProvider.fetchQuota()
        try Task.checkCancellation()
        guard realSnapshot.dataSource != .real
                || realSnapshot.accountBoundary?.isValid == true else {
            throw RealQuotaError.accountIdentityUnavailable
        }
        let mergedSnapshot = realSnapshot.mergingPartial(with: currentSnapshot)
        let prefetchedDetails = await prefetchedResetCredits
        try Task.checkCancellation()
        let enrichedSnapshot = try await enrichResetCreditsDetails(
            for: mergedSnapshot,
            fallingBackTo: currentSnapshot,
            prefetched: prefetchedDetails
        )
        try Task.checkCancellation()
        AppLogger.refresh.info("Real quota fetch succeeded")
        return enrichedSnapshot
    }

    /// What the reset-credit detail leg produced while the RPC leg was in flight.
    private enum PrefetchedResetCreditsDetails: Sendable {
        /// `auth.json` held no usable account/session identity when the leg started, so no request
        /// could be bound to an identity: the serial leg below runs instead.
        case identityUnavailable
        /// The leg was cancelled together with its refresh; never published.
        case cancelled
        /// An outcome produced by a request that was bound to `requestBoundary`.
        case resolved(ResetCreditsDetailOutcome, requestBoundary: QuotaAccountBoundary)
    }

    /// Runs the reset-credit detail leg concurrently with the RPC leg.
    ///
    /// This function never throws: it can only degrade the reset-credit
    /// presentation, never fail the refresh by itself. Cancellation stays
    /// cancellation: it is reported as `.cancelled` and still propagates from
    /// `refresh`.
    private func prefetchResetCreditsDetails() async -> PrefetchedResetCreditsDetails {
        guard let requestBoundary = currentAccountBoundary(), requestBoundary.isValid else {
            return .identityUnavailable
        }
        do {
            let payload = try await resetCreditsDetailProvider.fetchDetails(for: requestBoundary)
            return .resolved(.payload(payload), requestBoundary: requestBoundary)
        } catch is CancellationError {
            return .cancelled
        } catch {
            // `URLSession` reports cancellation as `URLError.cancelled`, which must stay a
            // cancellation instead of becoming a published diagnostic.
            guard !Task.isCancelled else { return .cancelled }
            if let detailError = error as? ResetCreditsDetailError,
               case .noAvailableCredits = detailError {
                return .resolved(.noAvailableCredits, requestBoundary: requestBoundary)
            }
            // The sanitizer stays the single owner of diagnostic formatting.
            return .resolved(
                .failure(summary: sanitizedResetCreditsError(error)),
                requestBoundary: requestBoundary
            )
        }
    }

    /// The outcome of the reset-credit detail leg before it is projected onto a snapshot.
    ///
    /// The prefetched leg and the serial leg both end here, so every published
    /// reset-credit state goes through the same projection below.
    private enum ResetCreditsDetailOutcome {
        case payload(ResetCreditsDetailPayload)
        case noAvailableCredits
        case failure(summary: String)
    }

    private func enrichResetCreditsDetails(
        for snapshot: QuotaSnapshot,
        fallingBackTo previousSnapshot: QuotaSnapshot,
        prefetched: PrefetchedResetCreditsDetails
    ) async throws -> QuotaSnapshot {
        try Task.checkCancellation()

        let outcome = try await resetCreditsDetailOutcome(
            for: snapshot,
            prefetched: prefetched
        )
        let reusableDetails = reusableResetCreditDetails(
            from: previousSnapshot,
            for: snapshot
        )

        switch outcome {
        case .payload(let payload):
            return projectingResetCredits(
                onto: snapshot,
                state: .detailed,
                availableCount: payload.availableCount ?? snapshot.resetAvailableCount,
                details: payload.availableCredits,
                statusSummary: payload.statusSummary
            )

        case .noAvailableCredits where reusableDetails.isEmpty:
            // The server explicitly reported no available reset credits:
            // that is a normal account state, not a detail fetch failure.
            // Keep the neutral app-server count presentation.
            return projectingResetCredits(
                onto: snapshot,
                state: .appServerCountOnly,
                availableCount: snapshot.resetAvailableCount
            )

        case .noAvailableCredits:
            // Previous unexpired detail times still exist, so the serial
            // composition published them as `.unavailable` together with this
            // reason instead of the neutral count.
            return projectingUnavailableResetCredits(
                onto: snapshot,
                reusableDetails: reusableDetails,
                diagnosticSummary: ResetCreditsDetailError.noAvailableCredits.localizedDescription
            )

        case .failure(let summary):
            return projectingUnavailableResetCredits(
                onto: snapshot,
                reusableDetails: reusableDetails,
                diagnosticSummary: summary
            )
        }
    }

    /// Projection shared by "the server reported no available credits" (when
    /// previous unexpired detail times still exist) and every detail fetch
    /// failure.
    private func projectingUnavailableResetCredits(
        onto snapshot: QuotaSnapshot,
        reusableDetails: [ResetCreditDetailSnapshot],
        diagnosticSummary: String
    ) -> QuotaSnapshot {
        // The same sanitized reason is logged and persisted, so it is
        // formatted once instead of twice.
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

    /// Chooses the reset-credit outcome for this refresh.
    ///
    /// A prefetched outcome is used only when the identity its request was bound
    /// to matches the identity the refreshed snapshot proves. When `auth.json`
    /// held no usable identity when the detail leg started, no request could be
    /// bound to an identity, so the serial path runs instead.
    private func resetCreditsDetailOutcome(
        for snapshot: QuotaSnapshot,
        prefetched: PrefetchedResetCreditsDetails
    ) async throws -> ResetCreditsDetailOutcome {
        switch prefetched {
        case .cancelled:
            // Defensive: the caller re-checks cancellation before this point.
            throw CancellationError()
        case .identityUnavailable:
            return try await fetchResetCreditsDetailsSerially(for: snapshot)
        case .resolved(let outcome, let requestBoundary):
            return gatedResetCreditsDetailOutcome(
                outcome,
                requestBoundary: requestBoundary,
                snapshot: snapshot
            )
        }
    }

    /// Fail-closed identity gate for a prefetched outcome.
    ///
    /// The request was bound to the identity `auth.json` held when the refresh
    /// started, while the RPC leg proves the identity the snapshot carries. An
    /// outcome is published only when both are valid and exactly equal; an
    /// account/session change that raced the refresh is dropped, because
    /// publishing another account's or session's data is exactly what the
    /// serial order used to prevent.
    private func gatedResetCreditsDetailOutcome(
        _ outcome: ResetCreditsDetailOutcome,
        requestBoundary: QuotaAccountBoundary,
        snapshot: QuotaSnapshot
    ) -> ResetCreditsDetailOutcome {
        guard let accountBoundary = snapshot.accountBoundary, accountBoundary.isValid else {
            // Same fail-closed outcome as the serial path's boundary guard: this
            // snapshot does not prove any account/session, so nothing fetched under
            // one may be published with it.
            return .failure(summary: ResetCreditsDetailError.accountBoundaryMismatch.localizedDescription)
        }
        guard accountBoundary.matches(requestBoundary) else {
            AppLogger.refresh.warning("Reset credits detail fetch discarded: account/session identity changed during the refresh")
            return .failure(summary: ResetCreditsDetailError.accountBoundaryMismatch.localizedDescription)
        }
        return outcome
    }

    /// The previous serial leg: fetch details under the boundary the refreshed
    /// snapshot proves.
    ///
    /// Used only when `auth.json` held no usable identity when the refresh
    /// started, so no prefetched request could be bound to an identity.
    private func fetchResetCreditsDetailsSerially(
        for snapshot: QuotaSnapshot
    ) async throws -> ResetCreditsDetailOutcome {
        do {
            guard let accountBoundary = snapshot.accountBoundary,
                  accountBoundary.isValid else {
                throw ResetCreditsDetailError.accountBoundaryMismatch
            }
            let details = try await resetCreditsDetailProvider.fetchDetails(
                for: accountBoundary
            )
            try Task.checkCancellation()
            return .payload(details)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            if case ResetCreditsDetailError.noAvailableCredits = error {
                return .noAvailableCredits
            }
            return .failure(summary: sanitizedResetCreditsError(error))
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
