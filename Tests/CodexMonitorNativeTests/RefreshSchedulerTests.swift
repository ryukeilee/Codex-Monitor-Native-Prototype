import XCTest
@testable import CodexMonitorNative

@MainActor
final class RefreshSchedulerTests: XCTestCase {
    func testStableSnapshotSchedulesBeyondLegacyFiveMinutes() async {
        let base = Date(timeIntervalSince1970: 1_000)
        let clock = ManualRefreshSchedulerClock(now: base)
        let recorder = RefreshActionRecorder()
        let scheduler = RefreshScheduler(clock: clock) { trigger in
            await recorder.record(trigger)
        }
        let snapshot = quotaSnapshot(refreshedAt: base)

        scheduler.start()
        scheduler.updateSchedule(with: schedulingState(snapshot: snapshot, at: base))

        XCTAssertEqual(
            scheduler.nextFireAt,
            base.addingTimeInterval(AdaptiveRefreshCadencePolicy.stableInterval)
        )
        XCTAssertEqual(scheduler.nextReason, .stable)

        clock.advance(to: base.addingTimeInterval(5 * 60))
        let callCountBeforeStableDeadline = await recorder.callCount()
        XCTAssertEqual(callCountBeforeStableDeadline, 0)

        clock.advance(to: base.addingTimeInterval(AdaptiveRefreshCadencePolicy.stableInterval))
        await recorder.waitForCall(1)
        let stableTriggers = await recorder.triggers()
        XCTAssertEqual(stableTriggers, [.scheduled])
        scheduler.stop()
    }

    func testRapidQuotaChangeUsesShortCadence() {
        let base = Date(timeIntervalSince1970: 2_000)
        let previous = quotaSnapshot(weekly: 80, fiveHour: 75, refreshedAt: base)
        let current = quotaSnapshot(
            weekly: 65,
            fiveHour: 58,
            refreshedAt: base.addingTimeInterval(1)
        )
        let policy = AdaptiveRefreshCadencePolicy()

        let decision = policy.nextDecision(
            for: schedulingState(snapshot: current, at: current.refreshedAt),
            previousSuccessfulSnapshot: previous,
            now: current.refreshedAt
        )

        XCTAssertEqual(
            decision,
            RefreshScheduleDecision(
                fireAt: current.refreshedAt.addingTimeInterval(
                    AdaptiveRefreshCadencePolicy.rapidChangeInterval
                ),
                reason: .rapidQuotaChange
            )
        )
    }

    func testAccountBoundaryChangeDoesNotCompareNewSnapshotWithPriorAccount() async {
        let base = Date(timeIntervalSince1970: 2_500)
        let clock = ManualRefreshSchedulerClock(now: base)
        let recorder = RefreshActionRecorder()
        let scheduler = RefreshScheduler(clock: clock) { trigger in
            await recorder.record(trigger)
        }

        scheduler.start()
        scheduler.updateSchedule(with: schedulingState(
            snapshot: quotaSnapshot(weekly: 90, fiveHour: 85, refreshedAt: base),
            at: base
        ))
        scheduler.requestRefresh(.accountBoundaryChanged)
        await recorder.waitForCall(1)
        await waitForSchedulerToBecomeIdle(scheduler)

        let newAccountSnapshot = quotaSnapshot(
            weekly: 20,
            fiveHour: 15,
            refreshedAt: base.addingTimeInterval(1)
        )
        clock.advance(to: newAccountSnapshot.refreshedAt)
        scheduler.updateSchedule(with: schedulingState(
            snapshot: newAccountSnapshot,
            at: newAccountSnapshot.refreshedAt
        ))

        XCTAssertEqual(scheduler.nextReason, .stable)
        XCTAssertEqual(
            scheduler.nextFireAt,
            newAccountSnapshot.refreshedAt.addingTimeInterval(
                AdaptiveRefreshCadencePolicy.stableInterval
            )
        )
        scheduler.stop()
    }

    func testKnownResetBoundaryOverridesStableCadenceAndRefreshesPromptly() async {
        let base = Date(timeIntervalSince1970: 3_000)
        let resetAt = base.addingTimeInterval(60)
        let clock = ManualRefreshSchedulerClock(now: base)
        let recorder = RefreshActionRecorder()
        let scheduler = RefreshScheduler(clock: clock) { trigger in
            await recorder.record(trigger)
        }
        let snapshot = quotaSnapshot(refreshedAt: base, fiveHourResetAt: resetAt)

        scheduler.start()
        scheduler.updateSchedule(with: schedulingState(snapshot: snapshot, at: base))

        XCTAssertEqual(scheduler.nextFireAt, resetAt)
        XCTAssertEqual(scheduler.nextReason, .resetBoundary)

        clock.advance(to: resetAt.addingTimeInterval(-1))
        let callCountBeforeReset = await recorder.callCount()
        XCTAssertEqual(callCountBeforeReset, 0)

        clock.advance(to: resetAt)
        await recorder.waitForCall(1)
        let resetTriggers = await recorder.triggers()
        XCTAssertEqual(resetTriggers, [.temporalBoundary])
        scheduler.stop()
    }

    func testManualTimerWakeNetworkAndLoginTriggersCoalesceToOnePhysicalRequest() async {
        let base = Date(timeIntervalSince1970: 4_000)
        let clock = ManualRefreshSchedulerClock(now: base)
        let gate = RefreshActionGate()
        let scheduler = RefreshScheduler(clock: clock) { trigger in
            await gate.perform(trigger)
        }

        scheduler.start()
        scheduler.requestRefresh(.manual)
        await gate.waitForCall(1)

        for trigger in [
            AppState.RefreshTrigger.scheduled,
            .wake,
            .networkRestored,
            .accountBoundaryChanged,
            .manual
        ] {
            scheduler.requestRefresh(trigger)
        }

        let coalescedCallCount = await gate.callCount()
        let coalescedMaximumConcurrency = await gate.maximumConcurrentCalls()
        XCTAssertEqual(coalescedCallCount, 1)
        XCTAssertEqual(coalescedMaximumConcurrency, 1)
        XCTAssertEqual(scheduler.coalescedTriggerCount, 5)

        await gate.releaseNext()
        await waitForSchedulerToBecomeIdle(scheduler)

        let finalCoalescedCallCount = await gate.callCount()
        let finalCoalescedMaximumConcurrency = await gate.maximumConcurrentCalls()
        XCTAssertEqual(finalCoalescedCallCount, 1)
        XCTAssertEqual(finalCoalescedMaximumConcurrency, 1)
        scheduler.stop()
    }

    func testAppStateIngressRoutesMixedTriggersToOneRealQuotaRequest() async {
        let base = Date.now
        let clock = ManualRefreshSchedulerClock(now: base)
        let suiteName = "CodexMonitorNativeTests.adaptiveIngress.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let refreshed = quotaSnapshot(refreshedAt: base.addingTimeInterval(1))
        let service = SchedulerBlockingRefreshService(snapshot: refreshed)
        let state = AppState(
            snapshotStore: SnapshotStore(defaults: defaults, key: "snapshot"),
            refreshService: service
        )
        let scheduler = RefreshScheduler(clock: clock) { [weak state] trigger in
            guard let state else { return }
            await state.refreshNow(trigger: trigger)
        }
        state.onRefreshSchedulingStateChanged = { [weak scheduler] schedulingState in
            scheduler?.updateSchedule(with: schedulingState)
        }
        state.onRefreshRequested = { [weak scheduler] trigger in
            scheduler?.requestRefresh(trigger)
        }
        scheduler.updateSchedule(with: state.refreshSchedulingState)
        scheduler.start()

        state.refresh(trigger: .manual)
        await service.waitForCall(1)
        for trigger in [
            AppState.RefreshTrigger.scheduled,
            .wake,
            .networkRestored,
            .accountBoundaryChanged,
            .manual
        ] {
            state.refresh(trigger: trigger)
        }

        let activeCallCount = await service.callCount()
        let activeMaximumConcurrency = await service.maximumConcurrentCalls()
        XCTAssertEqual(activeCallCount, 1)
        XCTAssertEqual(activeMaximumConcurrency, 1)

        await service.releaseNext()
        await waitForSchedulerToBecomeIdle(scheduler)

        let settledCallCount = await service.callCount()
        let settledMaximumConcurrency = await service.maximumConcurrentCalls()
        XCTAssertEqual(settledCallCount, 1)
        XCTAssertEqual(settledMaximumConcurrency, 1)
        XCTAssertEqual(state.snapshot, refreshed)
        XCTAssertEqual(state.status, .success)
        scheduler.stop()
    }

    func testConsecutiveFailuresDoNotCreateDenseAutomaticRetryLoop() async {
        let base = Date(timeIntervalSince1970: 5_000)
        let clock = ManualRefreshSchedulerClock(now: base)
        let recorder = RefreshActionRecorder()
        let scheduler = RefreshScheduler(clock: clock) { trigger in
            await recorder.record(trigger)
        }
        let snapshot = quotaSnapshot(refreshedAt: base)

        scheduler.start()
        scheduler.updateSchedule(with: schedulingState(
            snapshot: snapshot,
            at: base,
            status: .networkFailed,
            lastSuccessAt: base,
            lastAttemptAt: base,
            failureCount: 1,
            backoffInterval: 5 * 60
        ))

        let firstRetry = base.addingTimeInterval(5 * 60)
        XCTAssertEqual(scheduler.nextFireAt, firstRetry)
        XCTAssertEqual(scheduler.nextReason, .failureBackoff)

        for trigger in [
            AppState.RefreshTrigger.scheduled,
            .wake,
            .networkRestored,
            .networkChanged,
            .accountBoundaryChanged
        ] {
            scheduler.requestRefresh(trigger)
        }
        let callCountInsideFirstBackoff = await recorder.callCount()
        XCTAssertEqual(callCountInsideFirstBackoff, 0)

        clock.advance(to: firstRetry.addingTimeInterval(-1))
        let callCountBeforeFirstRetry = await recorder.callCount()
        XCTAssertEqual(callCountBeforeFirstRetry, 0)

        clock.advance(to: firstRetry)
        await recorder.waitForCall(1)
        await waitForSchedulerToBecomeIdle(scheduler)

        scheduler.updateSchedule(with: schedulingState(
            snapshot: snapshot,
            at: firstRetry,
            status: .networkFailed,
            lastSuccessAt: base,
            lastAttemptAt: firstRetry,
            failureCount: 2,
            backoffInterval: 10 * 60
        ))
        let secondRetry = firstRetry.addingTimeInterval(10 * 60)
        XCTAssertEqual(scheduler.nextFireAt, secondRetry)

        scheduler.requestRefresh(.wake)
        scheduler.requestRefresh(.networkRestored)
        clock.advance(to: secondRetry.addingTimeInterval(-1))
        let callCountBeforeSecondRetry = await recorder.callCount()
        XCTAssertEqual(callCountBeforeSecondRetry, 1)

        clock.advance(to: secondRetry)
        await recorder.waitForCall(2)
        let finalBackoffCallCount = await recorder.callCount()
        XCTAssertEqual(finalBackoffCallCount, 2)
        scheduler.stop()
    }

    func testOverlappingPauseReasonsRequireIndependentRecovery() {
        let clock = ManualRefreshSchedulerClock(now: .now)
        let scheduler = RefreshScheduler(clock: clock) { _ in }

        scheduler.start()
        XCTAssertTrue(scheduler.hasScheduledTimer)

        scheduler.pause(for: .systemSleep)
        scheduler.pause(for: .networkUnavailable)
        XCTAssertTrue(scheduler.isPaused)
        XCTAssertFalse(scheduler.hasScheduledTimer)

        scheduler.resume(for: .systemSleep)
        XCTAssertTrue(scheduler.isPaused)
        XCTAssertFalse(scheduler.hasScheduledTimer)

        scheduler.resume(for: .networkUnavailable)
        XCTAssertFalse(scheduler.isPaused)
        XCTAssertTrue(scheduler.hasScheduledTimer)
        scheduler.stop()
    }

    func testOperationsAfterStopDoNotRecreateTimerOrDispatchRefresh() async {
        let clock = ManualRefreshSchedulerClock(now: .now)
        let recorder = RefreshActionRecorder()
        let scheduler = RefreshScheduler(clock: clock) { trigger in
            await recorder.record(trigger)
        }

        scheduler.start()
        scheduler.stop()
        scheduler.resume()
        scheduler.requestRefresh(.manual)
        clock.advance(to: clock.now.addingTimeInterval(24 * 60 * 60))

        XCTAssertFalse(scheduler.hasScheduledTimer)
        let callCountAfterStop = await recorder.callCount()
        XCTAssertEqual(callCountAfterStop, 0)
    }

    func testStopBeforeQueuedRefreshTaskBeginsPreventsStaleRefreshAction() async {
        let clock = ManualRefreshSchedulerClock(now: .now)
        let recorder = RefreshActionRecorder()
        let scheduler = RefreshScheduler(clock: clock) { trigger in
            await recorder.record(trigger)
        }

        scheduler.start()
        scheduler.requestRefresh(.manual)
        scheduler.stop()

        for _ in 0..<10 {
            await Task.yield()
        }

        let callCount = await recorder.callCount()
        XCTAssertEqual(callCount, 0)
        XCTAssertFalse(scheduler.isRefreshing)
        XCTAssertFalse(scheduler.hasActiveRefreshTask)
        XCTAssertFalse(scheduler.hasScheduledTimer)
    }

    func testStopDuringRefreshCancelsTaskAndClearsRefreshState() async {
        let clock = ManualRefreshSchedulerClock(now: .now)
        let gate = RefreshActionGate()
        let scheduler = RefreshScheduler(clock: clock) { trigger in
            await gate.perform(trigger)
        }

        scheduler.start()
        scheduler.requestRefresh(.manual)
        await gate.waitForCall(1)

        XCTAssertTrue(scheduler.isRefreshing)
        XCTAssertTrue(scheduler.hasActiveRefreshTask)

        scheduler.stop()

        XCTAssertFalse(scheduler.isRefreshing)
        XCTAssertFalse(scheduler.hasActiveRefreshTask)
        XCTAssertFalse(scheduler.hasScheduledTimer)

        await gate.releaseNext()
        await gate.waitForCompletion(1)
        let cancellationStates = await gate.cancellationStates()
        XCTAssertEqual(cancellationStates, [true])
        XCTAssertFalse(scheduler.isRefreshing)
        XCTAssertFalse(scheduler.hasActiveRefreshTask)
        XCTAssertFalse(scheduler.hasScheduledTimer)
    }

    func testLateCompletionFromStoppedRunCannotMutateRestartedRun() async {
        let base = Date(timeIntervalSince1970: 6_000)
        let clock = ManualRefreshSchedulerClock(now: base)
        let gate = RefreshActionGate()
        let scheduler = RefreshScheduler(clock: clock) { trigger in
            await gate.perform(trigger)
        }

        scheduler.start()
        scheduler.requestRefresh(.manual)
        await gate.waitForCall(1)

        scheduler.stop()
        scheduler.start()
        scheduler.requestRefresh(.manual)

        for _ in 0..<100 {
            if await gate.callCount() >= 2 {
                break
            }
            await Task.yield()
        }
        let restartedCallCount = await gate.callCount()
        XCTAssertEqual(restartedCallCount, 2)
        guard restartedCallCount == 2 else {
            await gate.releaseNext()
            return
        }

        scheduler.updateSchedule(with: schedulingState(
            snapshot: quotaSnapshot(refreshedAt: base),
            at: base
        ))
        XCTAssertTrue(scheduler.isRefreshing)
        XCTAssertTrue(scheduler.hasActiveRefreshTask)
        XCTAssertFalse(scheduler.hasScheduledTimer)

        // The first action deliberately ignores cancellation until released.
        // Its stale completion must not clear or schedule the restarted run.
        await gate.releaseNext()
        await gate.waitForCompletion(1)

        XCTAssertTrue(scheduler.isRefreshing)
        XCTAssertTrue(scheduler.hasActiveRefreshTask)
        XCTAssertFalse(scheduler.hasScheduledTimer)

        await gate.releaseNext()
        await gate.waitForCompletion(2)
        await waitForSchedulerToBecomeIdle(scheduler)

        XCTAssertFalse(scheduler.hasActiveRefreshTask)
        XCTAssertTrue(scheduler.hasScheduledTimer)
        let triggers = await gate.triggers()
        XCTAssertEqual(triggers, [.manual, .manual])
        scheduler.stop()
    }

    private func quotaSnapshot(
        weekly: Int = 70,
        fiveHour: Int = 60,
        refreshedAt: Date,
        fiveHourResetAt: Date? = nil
    ) -> QuotaSnapshot {
        QuotaSnapshot(
            weeklyQuotaPercent: weekly,
            fiveHourQuotaPercent: fiveHour,
            fiveHourResetAt: fiveHourResetAt,
            refreshedAt: refreshedAt,
            dataSource: .real
        )
    }

    private func schedulingState(
        snapshot: QuotaSnapshot,
        at referenceDate: Date,
        status: QuotaRefreshStatus = .success,
        lastSuccessAt: Date? = nil,
        lastAttemptAt: Date? = nil,
        failureCount: Int = 0,
        backoffInterval: TimeInterval = 5 * 60
    ) -> RefreshSchedulingState {
        RefreshSchedulingState(
            snapshot: snapshot,
            status: status,
            lastSuccessAt: lastSuccessAt ?? referenceDate,
            lastAttemptAt: lastAttemptAt,
            failureCount: failureCount,
            backoffInterval: backoffInterval
        )
    }

    private func waitForSchedulerToBecomeIdle(
        _ scheduler: RefreshScheduler,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<100 {
            if !scheduler.isRefreshing {
                return
            }
            await Task.yield()
        }
        XCTFail("scheduler did not become idle", file: file, line: line)
    }
}

@MainActor
private final class ManualRefreshSchedulerClock: RefreshSchedulerClock {
    private struct ScheduledAction {
        let deadline: Date
        let action: @MainActor () -> Void
    }

    var now: Date
    private var scheduledAction: ScheduledAction?

    var hasScheduledAction: Bool { scheduledAction != nil }

    init(now: Date) {
        self.now = now
    }

    func schedule(at date: Date, action: @escaping @MainActor () -> Void) {
        scheduledAction = ScheduledAction(deadline: date, action: action)
    }

    func cancelScheduledAction() {
        scheduledAction = nil
    }

    func advance(to date: Date) {
        precondition(date >= now)
        now = date
        while let scheduledAction, scheduledAction.deadline <= now {
            self.scheduledAction = nil
            scheduledAction.action()
        }
    }
}

private actor RefreshActionRecorder {
    private var recordedTriggers: [AppState.RefreshTrigger] = []
    private var waiters: [Int: [CheckedContinuation<Void, Never>]] = [:]

    func record(_ trigger: AppState.RefreshTrigger) {
        recordedTriggers.append(trigger)
        let count = recordedTriggers.count
        let pending = waiters.removeValue(forKey: count) ?? []
        pending.forEach { $0.resume() }
    }

    func callCount() -> Int { recordedTriggers.count }
    func triggers() -> [AppState.RefreshTrigger] { recordedTriggers }

    func waitForCall(_ expectedCount: Int) async {
        guard recordedTriggers.count < expectedCount else { return }
        await withCheckedContinuation { continuation in
            waiters[expectedCount, default: []].append(continuation)
        }
    }
}

private actor RefreshActionGate {
    private var activeCalls = 0
    private var maximumActiveCalls = 0
    private var completedCalls = 0
    private var recordedTriggers: [AppState.RefreshTrigger] = []
    private var callWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private var completionWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var observedCancellationStates: [Bool] = []

    func perform(_ trigger: AppState.RefreshTrigger) async {
        activeCalls += 1
        maximumActiveCalls = max(maximumActiveCalls, activeCalls)
        recordedTriggers.append(trigger)
        let count = recordedTriggers.count
        let pending = callWaiters.removeValue(forKey: count) ?? []
        pending.forEach { $0.resume() }

        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
        observedCancellationStates.append(Task.isCancelled)
        activeCalls -= 1
        completedCalls += 1
        let completed = completionWaiters.removeValue(forKey: completedCalls) ?? []
        completed.forEach { $0.resume() }
    }

    func waitForCall(_ expectedCount: Int) async {
        guard recordedTriggers.count < expectedCount else { return }
        await withCheckedContinuation { continuation in
            callWaiters[expectedCount, default: []].append(continuation)
        }
    }

    func releaseNext() {
        guard !releaseWaiters.isEmpty else { return }
        releaseWaiters.removeFirst().resume()
    }

    func waitForCompletion(_ expectedCount: Int) async {
        guard completedCalls < expectedCount else { return }
        await withCheckedContinuation { continuation in
            completionWaiters[expectedCount, default: []].append(continuation)
        }
    }

    func callCount() -> Int { recordedTriggers.count }
    func maximumConcurrentCalls() -> Int { maximumActiveCalls }
    func triggers() -> [AppState.RefreshTrigger] { recordedTriggers }
    func cancellationStates() -> [Bool] { observedCancellationStates }
}

private actor SchedulerBlockingRefreshService: QuotaRefreshing {
    private let snapshot: QuotaSnapshot
    private var activeCalls = 0
    private var maximumActiveCalls = 0
    private var calls = 0
    private var callWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    init(snapshot: QuotaSnapshot) {
        self.snapshot = snapshot
    }

    func refresh(basedOn currentSnapshot: QuotaSnapshot) async throws -> QuotaSnapshot {
        activeCalls += 1
        maximumActiveCalls = max(maximumActiveCalls, activeCalls)
        calls += 1
        let pending = callWaiters.removeValue(forKey: calls) ?? []
        pending.forEach { $0.resume() }

        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
        activeCalls -= 1
        return snapshot
    }

    func waitForCall(_ expectedCount: Int) async {
        guard calls < expectedCount else { return }
        await withCheckedContinuation { continuation in
            callWaiters[expectedCount, default: []].append(continuation)
        }
    }

    func releaseNext() {
        guard !releaseWaiters.isEmpty else { return }
        releaseWaiters.removeFirst().resume()
    }

    func callCount() -> Int { calls }
    func maximumConcurrentCalls() -> Int { maximumActiveCalls }
}
