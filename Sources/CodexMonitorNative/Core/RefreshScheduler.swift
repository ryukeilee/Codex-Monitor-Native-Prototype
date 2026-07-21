import Foundation

/// The subset of AppState used to determine the next automatic refresh.
/// Keeping it as a value makes cadence policy independent from UI state and
/// lets tests advance a deterministic clock instead of waiting on a run loop.
struct RefreshSchedulingState: Equatable {
    let snapshot: QuotaSnapshot
    let status: QuotaRefreshStatus
    let lastSuccessAt: Date?
    let lastAttemptAt: Date?
    let failureCount: Int
    let backoffInterval: TimeInterval
}

enum RefreshScheduleReason: Equatable {
    case bootstrap
    case stable
    case rapidQuotaChange
    case resetBoundary
    case failureBackoff
}

struct RefreshScheduleDecision: Equatable {
    let fireAt: Date
    let reason: RefreshScheduleReason
}

/// Pure cadence rules for automatic requests. Manual requests intentionally
/// remain immediate, while every non-manual source respects failure backoff.
struct AdaptiveRefreshCadencePolicy {
    static let bootstrapInterval: TimeInterval = 5 * 60
    static let stableInterval: TimeInterval = 15 * 60
    static let rapidChangeInterval: TimeInterval = 2 * 60
    static let significantQuotaChange: Int = 10

    func nextDecision(
        for state: RefreshSchedulingState,
        previousSuccessfulSnapshot: QuotaSnapshot?,
        now: Date
    ) -> RefreshScheduleDecision {
        if state.failureCount > 0 {
            let attemptedAt = state.lastAttemptAt ?? now
            return RefreshScheduleDecision(
                fireAt: max(now, attemptedAt.addingTimeInterval(state.backoffInterval)),
                reason: .failureBackoff
            )
        }

        guard state.snapshot.dataSource == .real,
              state.lastSuccessAt != nil else {
            return RefreshScheduleDecision(
                fireAt: now.addingTimeInterval(Self.bootstrapInterval),
                reason: .bootstrap
            )
        }

        let rapidChange = Self.hasSignificantQuotaChange(
            from: previousSuccessfulSnapshot,
            to: state.snapshot
        )
        let interval = rapidChange ? Self.rapidChangeInterval : Self.stableInterval
        let cadenceDecision = RefreshScheduleDecision(
            fireAt: now.addingTimeInterval(interval),
            reason: rapidChange ? .rapidQuotaChange : .stable
        )

        guard let resetDeadline = nearestRefreshBoundary(for: state, now: now),
              resetDeadline <= cadenceDecision.fireAt else {
            return cadenceDecision
        }

        return RefreshScheduleDecision(
            fireAt: resetDeadline,
            reason: .resetBoundary
        )
    }

    private func nearestRefreshBoundary(
        for state: RefreshSchedulingState,
        now: Date
    ) -> Date? {
        QuotaTemporalSemantics.upcomingTransitions(
            snapshot: state.snapshot,
            status: state.status,
            lastSuccessAt: state.lastSuccessAt,
            now: now
        )
        .first(where: \.requiresRefresh)?
        .date
    }

    private static func hasSignificantQuotaChange(
        from previous: QuotaSnapshot?,
        to current: QuotaSnapshot
    ) -> Bool {
        guard let previous,
              previous.dataSource == .real,
              current.dataSource == .real else {
            return false
        }

        return abs(previous.weeklyQuotaPercent - current.weeklyQuotaPercent) >= significantQuotaChange
            || abs(previous.fiveHourQuotaPercent - current.fiveHourQuotaPercent) >= significantQuotaChange
    }
}

/// A one-shot clock. Production uses the main run loop; tests can retain a
/// scheduled action and advance an artificial wall clock explicitly.
@MainActor
protocol RefreshSchedulerClock: AnyObject {
    var now: Date { get }
    var hasScheduledAction: Bool { get }

    func schedule(at date: Date, action: @escaping @MainActor () -> Void)
    func cancelScheduledAction()
}

@MainActor
final class RunLoopRefreshSchedulerClock: RefreshSchedulerClock {
    private var timer: Timer?
    private var generation = 0

    var now: Date { .now }
    var hasScheduledAction: Bool { timer != nil }

    func schedule(at date: Date, action: @escaping @MainActor () -> Void) {
        cancelScheduledAction()
        generation &+= 1
        let expectedGeneration = generation
        let timer = Timer(fire: date, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == expectedGeneration else { return }
                self.timer = nil
                action()
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func cancelScheduledAction() {
        generation &+= 1
        timer?.invalidate()
        timer = nil
    }

}

@MainActor
final class RefreshScheduler {
    enum PauseReason: Hashable {
        case unspecified
        case systemSleep
        case networkUnavailable
    }

    private let clock: any RefreshSchedulerClock
    private let policy: AdaptiveRefreshCadencePolicy
    private let onRefresh: @MainActor (AppState.RefreshTrigger) async -> Void
    private var pauseReasons: Set<PauseReason> = []
    private var isRunning = false
    private var latestState: RefreshSchedulingState?
    private var previousSuccessfulSnapshot: QuotaSnapshot?
    private var comparisonSnapshot: QuotaSnapshot?
    private var refreshInFlight = false
    private var refreshTask: Task<Void, Never>?
    private var refreshGeneration = 0
    private var scheduleChangedWhileRefreshing = false
    private var pendingAutomaticTrigger: AppState.RefreshTrigger?

    private(set) var nextFireAt: Date?
    private(set) var nextReason: RefreshScheduleReason?
    private(set) var coalescedTriggerCount = 0

    var isPaused: Bool { !pauseReasons.isEmpty }
    var isRefreshing: Bool { refreshInFlight }
    var hasActiveRefreshTask: Bool { refreshTask != nil }

    /// Exposed for lifecycle verification without leaking the concrete timer.
    var hasScheduledTimer: Bool { clock.hasScheduledAction }

    init(
        clock: any RefreshSchedulerClock = RunLoopRefreshSchedulerClock(),
        policy: AdaptiveRefreshCadencePolicy = AdaptiveRefreshCadencePolicy(),
        onRefresh: @escaping @MainActor (AppState.RefreshTrigger) async -> Void
    ) {
        self.clock = clock
        self.policy = policy
        self.onRefresh = onRefresh
    }

    func start() {
        stop()
        isRunning = true
        pauseReasons.removeAll()
        AppLogger.refresh.info("Starting adaptive refresh scheduler")
        scheduleNextRefreshIfPossible()
    }

    func stop() {
        if clock.hasScheduledAction || refreshTask != nil {
            AppLogger.refresh.info("Stopping refresh scheduler")
        }
        isRunning = false
        refreshGeneration &+= 1
        refreshTask?.cancel()
        refreshTask = nil
        refreshInFlight = false
        scheduleChangedWhileRefreshing = false
        pauseReasons.removeAll()
        pendingAutomaticTrigger = nil
        nextFireAt = nil
        nextReason = nil
        clock.cancelScheduledAction()
    }

    /// Replaces the former repeating interval update. AppState sends a new
    /// value after every meaningful refresh state transition.
    func updateSchedule(with state: RefreshSchedulingState) {
        latestState = state
        if state.status == .success, state.snapshot.dataSource == .real {
            comparisonSnapshot = previousSuccessfulSnapshot
            previousSuccessfulSnapshot = state.snapshot
        }

        guard !refreshInFlight else {
            scheduleChangedWhileRefreshing = true
            return
        }
        scheduleNextRefreshIfPossible()
    }

    /// All product refresh sources enter here. Automatic events inside a
    /// failed-request backoff window are retained as one intent until the
    /// deadline; duplicate events while a request is active are folded into it.
    func requestRefresh(_ trigger: AppState.RefreshTrigger) {
        guard isRunning, !isPaused else { return }

        if trigger == .accountBoundaryChanged {
            // A changed account/session must not influence the new owner's
            // cadence, even though AppState has already failed closed for the
            // persisted snapshot itself.
            previousSuccessfulSnapshot = nil
            comparisonSnapshot = nil
        }

        if refreshInFlight {
            coalescedTriggerCount += 1
            AppLogger.refresh.info("Coalesced \(self.triggerName(for: trigger), privacy: .public) refresh with active adaptive request")
            return
        }

        if !trigger.bypassesFailureBackoff,
           let failureDeadline = failureBackoffDeadline(),
           clock.now < failureDeadline {
            pendingAutomaticTrigger = preferredTrigger(
                pendingAutomaticTrigger,
                over: trigger
            )
            scheduleNextRefreshIfPossible()
            AppLogger.refresh.info("Deferred \(self.triggerName(for: trigger), privacy: .public) refresh until failure backoff ends")
            return
        }

        pendingAutomaticTrigger = nil
        startRefresh(trigger)
    }

    /// Pauses for one lifecycle reason. Overlapping reasons must each resume
    /// before the deadline is recreated.
    func pause(for reason: PauseReason = .unspecified) {
        guard isRunning, pauseReasons.insert(reason).inserted else { return }
        AppLogger.system.info("Refresh scheduler paused (reason=\(String(describing: reason), privacy: .public))")
        cancelScheduledRefresh()
    }

    /// Clears one pause reason and recomputes the deadline from the current
    /// clock rather than reviving an already stale Timer instance.
    func resume(for reason: PauseReason = .unspecified) {
        guard isRunning, pauseReasons.remove(reason) != nil else { return }
        guard !isPaused else { return }
        AppLogger.system.info("Refresh scheduler resumed")
        scheduleNextRefreshIfPossible()
    }

    private func scheduleNextRefreshIfPossible() {
        cancelScheduledRefresh()
        guard isRunning, !isPaused, !refreshInFlight else { return }

        let state = latestState ?? RefreshSchedulingState(
            snapshot: .notConnected,
            status: .noSnapshot,
            lastSuccessAt: nil,
            lastAttemptAt: nil,
            failureCount: 0,
            backoffInterval: AdaptiveRefreshCadencePolicy.bootstrapInterval
        )
        let decision = policy.nextDecision(
            for: state,
            previousSuccessfulSnapshot: comparisonSnapshot,
            now: clock.now
        )
        nextFireAt = decision.fireAt
        nextReason = decision.reason
        clock.schedule(at: decision.fireAt) { [weak self] in
            self?.scheduledDeadlineDidFire()
        }
    }

    private func scheduledDeadlineDidFire() {
        guard isRunning, !isPaused else { return }
        nextFireAt = nil
        let reason = nextReason
        nextReason = nil
        let trigger = pendingAutomaticTrigger
            ?? (reason == .resetBoundary ? .temporalBoundary : .scheduled)
        pendingAutomaticTrigger = nil
        requestRefresh(trigger)
    }

    private func startRefresh(_ trigger: AppState.RefreshTrigger) {
        cancelScheduledRefresh()
        refreshInFlight = true
        scheduleChangedWhileRefreshing = false
        refreshGeneration &+= 1
        let expectedGeneration = refreshGeneration
        let refreshAction = onRefresh
        AppLogger.refresh.info("Starting adaptive \(self.triggerName(for: trigger), privacy: .public) refresh")

        refreshTask = Task { @MainActor [weak self] in
            guard !Task.isCancelled,
                  let self,
                  self.isRunning,
                  self.refreshGeneration == expectedGeneration else {
                return
            }
            await refreshAction(trigger)
            guard !Task.isCancelled,
                  self.isRunning,
                  self.refreshGeneration == expectedGeneration else {
                return
            }
            refreshTask = nil
            refreshInFlight = false
            if scheduleChangedWhileRefreshing {
                scheduleChangedWhileRefreshing = false
                scheduleNextRefreshIfPossible()
            }
        }
    }

    private func cancelScheduledRefresh() {
        nextFireAt = nil
        nextReason = nil
        clock.cancelScheduledAction()
    }

    private func failureBackoffDeadline() -> Date? {
        guard let latestState,
              latestState.failureCount > 0 else {
            return nil
        }
        return (latestState.lastAttemptAt ?? clock.now)
            .addingTimeInterval(latestState.backoffInterval)
    }

    private func preferredTrigger(
        _ current: AppState.RefreshTrigger?,
        over candidate: AppState.RefreshTrigger
    ) -> AppState.RefreshTrigger {
        guard let current else { return candidate }
        return triggerPriority(candidate) > triggerPriority(current) ? candidate : current
    }

    private func triggerPriority(_ trigger: AppState.RefreshTrigger) -> Int {
        switch trigger {
        case .accountBoundaryChanged: return 5
        case .networkRestored: return 4
        case .wake: return 3
        case .temporalBoundary, .systemClockChange: return 2
        case .networkChanged, .scheduled: return 1
        case .manual: return 0
        }
    }

    private func triggerName(for trigger: AppState.RefreshTrigger) -> String {
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
}

private extension AppState.RefreshTrigger {
    var bypassesFailureBackoff: Bool {
        self == .manual
    }
}
