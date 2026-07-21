import Foundation

struct AppStateEvent: Equatable {
    enum UpdateReason: Equatable {
        case stateChange
        case temporalReconciliation
    }

    let persistedState: PersistedAppState
    let presentationSnapshot: QuotaPresentationSnapshot
    let updateReason: UpdateReason

    init(
        snapshot: QuotaSnapshot,
        status: QuotaRefreshStatus,
        lastSuccessAt: Date?,
        lastAttemptAt: Date?,
        failureCount: Int,
        effectiveFiveHourResetAt: Date?,
        savedAt: Date = .now,
        updateReason: UpdateReason = .stateChange
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
        self.updateReason = updateReason
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
    enum RefreshTrigger: Equatable {
        case manual
        case scheduled
        case wake
        case networkRestored
        case networkChanged
        case temporalBoundary
        case systemClockChange
        case accountBoundaryChanged
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

    /// Publishes the immutable inputs used by the adaptive scheduler after a
    /// state transition. AppState remains the owner of RPC execution,
    /// persistence, account-bound cache validation, and failure classification.
    var onRefreshSchedulingStateChanged: (@MainActor (RefreshSchedulingState) -> Void)?

    /// Optional product-level ingress for refresh intents. `refreshNow` keeps
    /// bypassing this hook so the scheduler can delegate the actual request
    /// back to AppState without recursion.
    var onRefreshRequested: (@MainActor (RefreshTrigger) -> Void)?

    // MARK: - Private

    private let snapshotStore: SnapshotStore
    private let refreshAction: @Sendable (QuotaSnapshot) async throws -> QuotaSnapshot
    private var latestRealSnapshot: QuotaSnapshot?
    private var consecutiveFailures: Int = 0
    private let defaultInterval: TimeInterval = 300
    private let staleAfterInterval: TimeInterval
    private let now: () -> Date
    private let sleep: @Sendable (UInt64) async throws -> Void
    private let accountBoundaryProvider: () -> QuotaAccountBoundary?
    private let allowsUnboundSnapshotsForTesting: Bool
    private let taskResources = AppStateTaskResources()
    private var activeRefresh: ActiveRefresh?
    private var pendingRefresh: PendingRefresh?
    private var lastSettledStatus: QuotaRefreshStatus = .noSnapshot
    private var lastObservedAccountBoundary: QuotaAccountBoundary?
    private var isShutdown = false
    private(set) var networkIsReachable: Bool?

    var isRefreshing: Bool { status == .refreshing }
    var isUsingCachedSnapshot: Bool { realQuotaHealth.isUsingCachedSnapshot }
    var hasScheduledFreshnessTask: Bool { taskResources.freshnessTask != nil }
    var hasScheduledTemporalTask: Bool { taskResources.freshnessTask != nil }
    var hasManagedRefreshTask: Bool { taskResources.refreshTask != nil }

    var refreshSchedulingState: RefreshSchedulingState {
        RefreshSchedulingState(
            snapshot: snapshot,
            status: status,
            lastSuccessAt: lastSuccessAt,
            lastAttemptAt: lastAttemptAt,
            failureCount: failureCount,
            backoffInterval: backoffInterval
        )
    }

    var isDataStale: Bool {
        isDataStale(at: now())
    }

    // MARK: - Init

    init<T: QuotaRefreshing>(
        snapshotStore: SnapshotStore,
        refreshService: T,
        staleAfterInterval: TimeInterval = QuotaTemporalSemantics.defaultStaleAfterInterval,
        now: @escaping () -> Date = { .now },
        sleep: @escaping @Sendable (UInt64) async throws -> Void = { nanoseconds in
            try await Task.sleep(nanoseconds: nanoseconds)
        },
        initialNetworkReachability: Bool? = true,
        accountBoundaryProvider: @escaping () -> QuotaAccountBoundary?,
        allowsUnboundSnapshotsForTesting: Bool = false
    ) {
        self.snapshotStore = snapshotStore
        self.staleAfterInterval = staleAfterInterval
        self.now = now
        self.sleep = sleep
        self.networkIsReachable = initialNetworkReachability
        self.accountBoundaryProvider = accountBoundaryProvider
        self.allowsUnboundSnapshotsForTesting = allowsUnboundSnapshotsForTesting
        self.refreshAction = { snapshot in
            try await refreshService.refresh(basedOn: snapshot)
        }

        let currentAccountBoundary = accountBoundaryProvider()
        lastObservedAccountBoundary = currentAccountBoundary

        let persistedState = snapshotStore.loadState()
        if let persistedState {
            let stored = persistedState.snapshot
            if stored.dataSource == .real {
                let canRestoreAccountBoundSnapshot = stored.accountBoundary?
                    .matches(currentAccountBoundary) == true
                let canRestoreUnboundTestSnapshot = allowsUnboundSnapshotsForTesting
                    && stored.accountBoundary == nil
                if canRestoreAccountBoundSnapshot || canRestoreUnboundTestSnapshot {
                    snapshot = stored
                    latestRealSnapshot = stored
                    lastSuccessAt = persistedState.lastSuccessAt ?? stored.refreshedAt
                    lastAttemptAt = persistedState.lastAttemptAt
                    failureCount = persistedState.failureCount
                    consecutiveFailures = failureCount
                    status = normalizedRestoredStatus(
                        persistedStatus: persistedState.status,
                        snapshot: stored,
                        lastSuccessAt: lastSuccessAt,
                        referenceDate: now()
                    )
                    realQuotaHealth = RealQuotaHealthDiagnostic(
                        kind: .waitingForFirstRequest,
                        isUsingCachedSnapshot: true
                    )
                    AppLogger.snapshot.info("Restored account-bound real snapshot: weekly=\(stored.weeklyQuotaPercent)% fiveHour=\(stored.fiveHourQuotaPercent)%")
                } else {
                    snapshot = .notConnected
                    status = .noSnapshot
                    lastSuccessAt = nil
                    lastAttemptAt = nil
                    failureCount = 0
                    consecutiveFailures = 0
                    realQuotaHealth = RealQuotaHealthDiagnostic(
                        kind: .waitingForFirstRequest,
                        isUsingCachedSnapshot: false
                    )
                    AppLogger.snapshot.info("Discarded persisted real snapshot because its account session could not be verified")
                }
            } else {
                snapshot = stored
                lastSuccessAt = persistedState.lastSuccessAt
                lastAttemptAt = persistedState.lastAttemptAt
                failureCount = persistedState.failureCount
                consecutiveFailures = failureCount
                status = normalizedRestoredStatus(
                    persistedStatus: persistedState.status,
                    snapshot: stored,
                    lastSuccessAt: lastSuccessAt,
                    referenceDate: now()
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

        let referenceDate = now()
        commitState(at: referenceDate)
        scheduleTemporalCheck(referenceDate: referenceDate)
    }

#if DEBUG
    convenience init<T: QuotaRefreshing>(
        snapshotStore: SnapshotStore,
        refreshService: T,
        staleAfterInterval: TimeInterval = QuotaTemporalSemantics.defaultStaleAfterInterval,
        now: @escaping () -> Date = { .now },
        sleep: @escaping @Sendable (UInt64) async throws -> Void = { nanoseconds in
            try await Task.sleep(nanoseconds: nanoseconds)
        },
        initialNetworkReachability: Bool? = true
    ) {
        self.init(
            snapshotStore: snapshotStore,
            refreshService: refreshService,
            staleAfterInterval: staleAfterInterval,
            now: now,
            sleep: sleep,
            initialNetworkReachability: initialNetworkReachability,
            accountBoundaryProvider: { nil },
            allowsUnboundSnapshotsForTesting: true
        )
    }
#endif

    deinit {
        activeRefresh?.resumeWaiters()
        pendingRefresh?.resumeWaiters()
    }

    // MARK: - Formatters

    var formattedRefreshedAt: String {
        StatusPopoverFormatting.shortTimestamp(for: snapshot.refreshedAt)
    }

    var displayStatus: QuotaRefreshStatus {
        resolvedDisplayStatus(for: status, at: now())
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
        guard !isShutdown else { return }
        if let onRefreshRequested {
            onRefreshRequested(trigger)
        } else {
            enqueueRefresh(trigger: trigger)
        }
    }

    func refreshNow(trigger: RefreshTrigger) async {
        guard !isShutdown else { return }
        await withCheckedContinuation { continuation in
            enqueueRefresh(trigger: trigger, waiter: continuation)
        }
    }

    /// Updates physical network availability without treating an offline period
    /// as another failed server request. An in-flight result is invalidated so a
    /// response from the old path cannot overwrite the offline state or a later
    /// recovery refresh.
    func updateNetworkReachability(_ isReachable: Bool) {
        guard !isShutdown else { return }
        guard networkIsReachable != isReachable else { return }
        networkIsReachable = isReachable
        guard !isReachable else { return }

        taskResources.refreshTask?.cancel()
        pendingRefresh?.resumeWaiters()
        pendingRefresh = nil
        if var activeRefresh {
            activeRefresh.isInvalidated = true
            activeRefresh.resumeWaiters()
            self.activeRefresh = activeRefresh
        }

        let currentBoundary = accountBoundaryProvider()
        lastObservedAccountBoundary = currentBoundary
        _ = discardCachedSnapshotIfAccountBoundaryIsUnverified(
            currentBoundary: currentBoundary
        )
        if let real = latestRealSnapshot {
            snapshot = real
        } else {
            snapshot = .notConnected
        }
        status = .networkFailed
        lastErrorSummary = "网络连接不可用"
        realQuotaHealth = RealQuotaHealthDiagnostic(
            kind: .networkUnavailable,
            isUsingCachedSnapshot: latestRealSnapshot != nil
        )
        let referenceDate = now()
        commitState(at: referenceDate)
        scheduleTemporalCheck(referenceDate: referenceDate)
        AppLogger.refresh.info("Network unavailable; paused real refresh requests")
    }

    func accountBoundaryDidChange() {
        guard !isShutdown else { return }
        let currentBoundary = accountBoundaryProvider()
        guard currentBoundary != lastObservedAccountBoundary else { return }
        lastObservedAccountBoundary = currentBoundary

        if discardCachedSnapshotIfAccountBoundaryIsUnverified(
            currentBoundary: currentBoundary
        ) {
            status = .noSnapshot
            lastErrorSummary = "Codex 账号或登录会话已变化"
            realQuotaHealth = RealQuotaHealthDiagnostic(
                kind: .waitingForFirstRequest,
                isUsingCachedSnapshot: false
            )
            let referenceDate = now()
            commitState(at: referenceDate)
            scheduleTemporalCheck(referenceDate: referenceDate)
            AppLogger.snapshot.info("Invalidated cached quota after the Codex account boundary changed")
        }

        if networkIsReachable == true {
            refresh(trigger: .accountBoundaryChanged)
        }
    }

    private func enqueueRefresh(
        trigger: RefreshTrigger,
        waiter: CheckedContinuation<Void, Never>? = nil
    ) {
        guard !isShutdown else {
            waiter?.resume()
            return
        }

        guard networkIsReachable == true else {
            waiter?.resume()
            AppLogger.refresh.info("Skipped \(self.triggerName(for: trigger), privacy: .public) refresh while network is unavailable or unresolved")
            return
        }

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
        guard !isShutdown else {
            waiters.forEach { $0.resume() }
            return
        }

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

    /// Enters an irreversible terminal state, cancels managed work, and publishes
    /// one final settled presentation for persistence and Widget consumers.
    func shutdown() {
        guard !isShutdown else { return }
        isShutdown = true

        taskResources.refreshTask?.cancel()
        taskResources.cancelFreshnessTask()

        pendingRefresh?.resumeWaiters()
        pendingRefresh = nil
        if var activeRefresh {
            activeRefresh.isInvalidated = true
            activeRefresh.resumeWaiters()
            self.activeRefresh = activeRefresh
        }

        let currentBoundary = accountBoundaryProvider()
        lastObservedAccountBoundary = currentBoundary
        let referenceDate = now()
        let invalidatedSnapshot = discardCachedSnapshotIfAccountBoundaryIsUnverified(
            currentBoundary: currentBoundary
        )
        if invalidatedSnapshot {
            status = .noSnapshot
            lastErrorSummary = nil
            realQuotaHealth = RealQuotaHealthDiagnostic(
                kind: .waitingForFirstRequest,
                isUsingCachedSnapshot: false
            )
        } else if status == .refreshing {
            if let real = latestRealSnapshot {
                snapshot = real
            }
            status = resolvedDisplayStatus(for: lastSettledStatus, at: referenceDate)
            realQuotaHealth = RealQuotaHealthDiagnostic(
                kind: .waitingForFirstRequest,
                isUsingCachedSnapshot: latestRealSnapshot != nil
            )
            lastErrorSummary = nil
        }

        commitState(at: referenceDate)
    }

    private func markQueuedRefresh() {
        enterRefreshingState(attemptedAt: nil)
    }

    private func beginRefresh(trigger: RefreshTrigger) -> QuotaSnapshot {
        let triggerName = triggerName(for: trigger)
        let currentBoundary = accountBoundaryProvider()
        lastObservedAccountBoundary = currentBoundary
        _ = discardCachedSnapshotIfAccountBoundaryIsUnverified(
            currentBoundary: currentBoundary
        )
        let baselineSnapshot = latestRealSnapshot ?? snapshot
        enterRefreshingState(attemptedAt: now())
        AppLogger.refresh.info("Starting \(triggerName, privacy: .public) refresh (baseline source=\(baselineSnapshot.dataSource.rawValue, privacy: .public))")
        return baselineSnapshot
    }

    @discardableResult
    private func discardCachedSnapshotIfAccountBoundaryIsUnverified(
        currentBoundary: QuotaAccountBoundary?,
        force: Bool = false
    ) -> Bool {
        guard let cachedSnapshot = latestRealSnapshot
                ?? (snapshot.dataSource == .real ? snapshot : nil) else {
            return false
        }

        if !force {
            // Unbound snapshots can only enter AppState through test doubles or
            // mock services. Production real snapshots are rejected before this
            // point unless the provider attached a verified account boundary.
            if cachedSnapshot.accountBoundary == nil {
                if allowsUnboundSnapshotsForTesting {
                    return false
                }
            } else if cachedSnapshot.accountBoundary?.matches(currentBoundary) == true {
                return false
            }
        }

        latestRealSnapshot = nil
        snapshot = .notConnected
        lastSuccessAt = nil
        return true
    }

    private func finishManagedRefresh(_ result: Result<QuotaSnapshot, Error>, refreshID: UUID) {
        guard var completedRefresh = activeRefresh,
              completedRefresh.id == refreshID else {
            return
        }

        taskResources.refreshTask = nil

        if isShutdown {
            activeRefresh = nil
            completedRefresh.resumeWaiters()
            pendingRefresh?.resumeWaiters()
            pendingRefresh = nil
            AppLogger.refresh.info("Discarded a refresh result received after shutdown")
            return
        }

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
        guard !isShutdown else {
            waiters.forEach { $0.resume() }
            pendingRefresh?.resumeWaiters()
            pendingRefresh = nil
            return
        }

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
        let referenceDate = now()
        switch result {
        case .success(let refreshed):
            if refreshed.dataSource == .real {
                if let refreshedBoundary = refreshed.accountBoundary {
                    let currentBoundary = accountBoundaryProvider()
                    lastObservedAccountBoundary = currentBoundary
                    guard refreshedBoundary.matches(currentBoundary) else {
                        let boundaryError: RealQuotaError = currentBoundary == nil
                            ? .accountIdentityUnavailable
                            : .accountChangedDuringRefresh
                        applyRefreshFailure(boundaryError, referenceDate: referenceDate)
                        return
                    }

                    if let cachedBoundary = latestRealSnapshot?.accountBoundary,
                       !refreshedBoundary.matches(cachedBoundary) {
                        latestRealSnapshot = nil
                    }
                } else if !allowsUnboundSnapshotsForTesting {
                    applyRefreshFailure(
                        RealQuotaError.accountIdentityUnavailable,
                        referenceDate: referenceDate
                    )
                    return
                }
                if let latestRealSnapshot, refreshed.refreshedAt < latestRealSnapshot.refreshedAt {
                    snapshot = latestRealSnapshot
                    status = isDataStale(at: referenceDate) ? .stale : .success
                    realQuotaHealth = RealQuotaHealthDiagnostic(kind: .requestSucceeded, isUsingCachedSnapshot: true)
                    commitState(at: referenceDate)
                    scheduleTemporalCheck(referenceDate: referenceDate)
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
                commitState(at: referenceDate)
                scheduleTemporalCheck(referenceDate: referenceDate)
                AppLogger.refresh.info("Real refresh succeeded: weekly=\(refreshed.weeklyQuotaPercent)% fiveHour=\(refreshed.fiveHourQuotaPercent)%")
            } else if let latestRealSnapshot {
                snapshot = latestRealSnapshot
                status = resolvedDisplayStatus(for: lastSettledStatus, at: referenceDate)
                realQuotaHealth = RealQuotaHealthDiagnostic(
                    kind: .waitingForFirstRequest,
                    isUsingCachedSnapshot: true
                )
                commitState(at: referenceDate)
                scheduleTemporalCheck(referenceDate: referenceDate)
                AppLogger.refresh.info("Ignored mock refresh because a real snapshot is already cached")
            } else {
                snapshot = refreshed
                status = .demoMode
                lastErrorSummary = nil
                realQuotaHealth = RealQuotaHealthDiagnostic(kind: .waitingForFirstRequest, isUsingCachedSnapshot: false)
                commitState(at: referenceDate)
                scheduleTemporalCheck(referenceDate: referenceDate)
                AppLogger.refresh.info("Mock refresh succeeded")
            }
        case .failure(let error):
            applyRefreshFailure(error, referenceDate: referenceDate)
        }
    }

    private func applyRefreshFailure(_ error: Error, referenceDate: Date) {
        consecutiveFailures += 1
        failureCount = consecutiveFailures
        let classifiedStatus = classifyError(error)
        var forceInvalidation = classifiedStatus == .authRequired
        if let realError = error as? RealQuotaError {
            switch realError {
            case .authenticationRequired, .chatGPTAccountRequired,
                 .accountIdentityUnavailable, .accountChangedDuringRefresh:
                forceInvalidation = true
            default:
                break
            }
        }

        let currentBoundary = accountBoundaryProvider()
        lastObservedAccountBoundary = currentBoundary
        _ = discardCachedSnapshotIfAccountBoundaryIsUnverified(
            currentBoundary: currentBoundary,
            force: forceInvalidation
        )

        lastErrorSummary = safeErrorMessage(from: error)
        status = classifiedStatus
        if let real = latestRealSnapshot {
            snapshot = real
        } else if snapshot.dataSource == .real {
            snapshot = .notConnected
        }
        realQuotaHealth = healthDiagnostic(for: error)
        setBackoffInterval(backoffFor(consecutiveFailures: consecutiveFailures))
        commitState(at: referenceDate)
        scheduleTemporalCheck(referenceDate: referenceDate)
        AppLogger.refresh.error("Refresh failed (consecutive=\(self.consecutiveFailures)) status=\(classifiedStatus.rawValue, privacy: .public) backoff=\(self.backoffInterval)s")
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
        case .codexNotExecutable:
            return "codex 文件不可执行"
        case .spawnFailed:
            return "Codex app-server 启动失败"
        case .codexIncompatible:
            return "Codex 版本不兼容"
        case .handshakeFailed:
            return "Codex 握手失败"
        case .requestTimedOut:
            return "请求超时"
        case .processExited:
            return "Codex 提前退出"
        case .transportFailed:
            return "Codex 通信失败"
        case .authenticationRequired:
            return "需要重新登录 Codex"
        case .chatGPTAccountRequired:
            return "需要使用 ChatGPT 账号登录 Codex"
        case .accountIdentityUnavailable:
            return "无法确认当前 Codex 账号与登录会话"
        case .accountChangedDuringRefresh:
            return "Codex 账号或登录会话在刷新期间发生变化"
        case .rpcRejected:
            return "RPC 请求失败"
        case .responseInvalid, .noUsableRateLimits:
            return "响应不可解析"
        case .unsupportedServerRequest:
            return "Codex 协议不兼容"
        case .processCleanupFailed:
            return "Codex 进程清理失败"
        }
    }

    /// Re-evaluates wall-clock projections after clock, time-zone, locale, or
    /// calendar changes. Typed refresh failures remain authoritative; only a
    /// successful state can transition to stale here.
    func reconcileTemporalState() {
        guard !isShutdown else { return }
        let referenceDate = now()
        if status == .success, isDataStale(at: referenceDate) {
            status = .stale
            lastErrorSummary = nil
        }
        commitState(reason: .temporalReconciliation, at: referenceDate)
        scheduleTemporalCheck(referenceDate: referenceDate)
    }

    private func scheduleTemporalCheck(referenceDate: Date) {
        taskResources.cancelFreshnessTask()

        guard !isShutdown,
              snapshot.dataSource == .real,
              let schedule = temporalSchedule(after: referenceDate) else {
            return
        }

        let delay = schedule.fireAt.timeIntervalSince(referenceDate)
        let nanoseconds = Self.nanoseconds(for: delay)
        let sleep = self.sleep
        let generation = taskResources.nextFreshnessGeneration()
        taskResources.freshnessTask = Task { @MainActor [weak self] in
            do {
                try await sleep(nanoseconds)
            } catch {
                return
            }

            guard let self,
                  self.taskResources.isCurrentFreshnessTask(generation) else {
                return
            }
            self.taskResources.clearFreshnessTask(for: generation)
            self.handleTemporalSchedule(schedule)
        }
    }

    private func temporalSchedule(after referenceDate: Date) -> TemporalSchedule? {
        let transitions = QuotaTemporalSemantics.upcomingTransitions(
            snapshot: snapshot,
            status: status,
            lastSuccessAt: lastSuccessAt,
            now: referenceDate,
            staleAfterInterval: staleAfterInterval
        )
        guard let fireAt = transitions.first?.date else {
            return nil
        }

        return TemporalSchedule(
            fireAt: fireAt,
            refreshDeadlines: transitions
                .filter(\.requiresRefresh)
                .map(\.date)
        )
    }

    private func handleTemporalSchedule(_ schedule: TemporalSchedule) {
        guard !isShutdown else { return }
        let referenceDate = now()

        if status == .success, isDataStale(at: referenceDate) {
            status = .stale
            lastErrorSummary = nil
            AppLogger.refresh.info("Marked data stale after \(self.staleAfterInterval, format: .fixed(precision: 0)) seconds without a successful refresh")
        }

        // Task.sleep is monotonic; the wall clock may have moved in either
        // direction while it was suspended. Publish current projections and
        // always derive the next task from the new wall-clock value.
        commitState(reason: .temporalReconciliation, at: referenceDate)
        scheduleTemporalCheck(referenceDate: referenceDate)

        let crossedRefreshBoundary = schedule.refreshDeadlines.contains {
            !QuotaTemporalSemantics.isPending(deadline: $0, at: referenceDate)
        }
        if crossedRefreshBoundary {
            refresh(trigger: .temporalBoundary)
        }
    }

    static func nanoseconds(for delay: TimeInterval) -> UInt64 {
        guard delay > 0 else { return 1 }

        // Keep the conversion strictly below UInt64's floating-point rounding
        // edge. `Double(UInt64.max)` rounds to 2^64 and traps when converted
        // back to UInt64.
        let maximumWholeSeconds = UInt64.max / 1_000_000_000
        let maximumNanoseconds = maximumWholeSeconds * 1_000_000_000
        guard delay.isFinite,
              delay < Double(maximumWholeSeconds) else {
            return maximumNanoseconds
        }

        return max(1, UInt64((delay * 1_000_000_000).rounded(.down)))
    }

    private func commitState(
        reason: AppStateEvent.UpdateReason = .stateChange,
        at referenceDate: Date? = nil
    ) {
        let referenceDate = referenceDate ?? now()
        let resolvedStatus = resolvedDisplayStatus(for: status, at: referenceDate)
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
            effectiveFiveHourResetAt: effectiveFiveHourResetAt,
            savedAt: referenceDate,
            updateReason: reason
        )
        snapshotStore.saveState(event.persistedState)
        stateEvent = event
        onRefreshSchedulingStateChanged?(refreshSchedulingState)
    }

    private func enterRefreshingState(attemptedAt: Date?) {
        status = .refreshing
        if let attemptedAt {
            lastAttemptAt = attemptedAt
        }
        realQuotaHealth = RealQuotaHealthDiagnostic(
            kind: .requestInProgress,
            isUsingCachedSnapshot: latestRealSnapshot != nil
        )
        let referenceDate = now()
        commitState(at: referenceDate)
        scheduleTemporalCheck(referenceDate: referenceDate)
    }

    private func resolvedDisplayStatus(
        for status: QuotaRefreshStatus,
        at referenceDate: Date
    ) -> QuotaRefreshStatus {
        if status == .success, isDataStale(at: referenceDate) {
            return .stale
        }

        return status
    }

    private func normalizedRestoredStatus(
        persistedStatus: QuotaRefreshStatus,
        snapshot: QuotaSnapshot,
        lastSuccessAt: Date?,
        referenceDate: Date
    ) -> QuotaRefreshStatus {
        if snapshot.dataSource == .real {
            switch persistedStatus {
            case .networkFailed, .authRequired, .parseFailed:
                return persistedStatus
            case .idle, .refreshing, .success, .stale, .noSnapshot, .demoMode:
                guard let lastSuccessAt else { return .stale }
                return QuotaTemporalSemantics.freshness(
                    lastSuccessAt: lastSuccessAt,
                    now: referenceDate,
                    staleAfterInterval: staleAfterInterval
                ).isFresh ? .success : .stale
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
        case .networkRestored: return "network-restored"
        case .networkChanged: return "network-changed"
        case .temporalBoundary: return "temporal-boundary"
        case .systemClockChange: return "system-clock-change"
        case .accountBoundaryChanged: return "account-boundary-changed"
        }
    }

    private func isDataStale(at referenceDate: Date) -> Bool {
        guard snapshot.dataSource == .real, let lastSuccessAt else {
            return false
        }

        return !QuotaTemporalSemantics.freshness(
            lastSuccessAt: lastSuccessAt,
            now: referenceDate,
            staleAfterInterval: staleAfterInterval
        ).isFresh
    }

}

private struct TemporalSchedule {
    let fireAt: Date
    let refreshDeadlines: [Date]
}

private final class AppStateTaskResources {
    var freshnessTask: Task<Void, Never>?
    var refreshTask: Task<Void, Never>?
    private var freshnessGeneration: UInt = 0

    func cancelFreshnessTask() {
        freshnessGeneration &+= 1
        freshnessTask?.cancel()
        freshnessTask = nil
    }

    func nextFreshnessGeneration() -> UInt {
        freshnessGeneration &+= 1
        return freshnessGeneration
    }

    func isCurrentFreshnessTask(_ generation: UInt) -> Bool {
        freshnessGeneration == generation
    }

    func clearFreshnessTask(for generation: UInt) {
        guard isCurrentFreshnessTask(generation) else { return }
        freshnessTask = nil
    }

    deinit {
        cancelFreshnessTask()
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
