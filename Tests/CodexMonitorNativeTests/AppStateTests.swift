import Combine
import XCTest
@testable import CodexMonitorNative

@MainActor
final class AppStateTests: XCTestCase {
    func testRepeatedRefreshCyclesConvergeManagedTaskResources() async {
        let suiteName = "CodexMonitorNativeTests.refreshLifecycle.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let snapshot = QuotaSnapshot(
            weeklyQuotaPercent: 80,
            fiveHourQuotaPercent: 60,
            refreshedAt: .now,
            dataSource: .real
        )
        let appState = AppState(
            snapshotStore: SnapshotStore(defaults: defaults, key: "snapshot"),
            refreshService: MockRefreshService(snapshot: snapshot)
        )

        for _ in 0..<500 {
            await appState.refreshNow(trigger: .scheduled)
            XCTAssertFalse(appState.hasManagedRefreshTask)
        }

        XCTAssertEqual(appState.status, .success)
        XCTAssertTrue(appState.hasScheduledFreshnessTask)

        appState.shutdown()
        XCTAssertFalse(appState.hasManagedRefreshTask)
        XCTAssertFalse(appState.hasScheduledFreshnessTask)
    }

    private func assertCallCount(_ expected: Int, for service: QueueingResultRefreshService, file: StaticString = #filePath, line: UInt = #line) async {
        let actual = await service.callCount()
        XCTAssertEqual(actual, expected, file: file, line: line)
    }

    private func assertMaxConcurrentCalls(_ expected: Int, for service: QueueingResultRefreshService, file: StaticString = #filePath, line: UInt = #line) async {
        let actual = await service.maxConcurrentCalls()
        XCTAssertEqual(actual, expected, file: file, line: line)
    }

    func testStateEventPublishesOneCoherentValuePerRefreshPhase() async {
        let defaults = UserDefaults(suiteName: "CodexMonitorNativeTests.presentationSnapshot.\(UUID().uuidString)")!
        let store = SnapshotStore(defaults: defaults, key: "snapshot")
        let initial = QuotaSnapshot(
            weeklyQuotaPercent: 72,
            fiveHourQuotaPercent: 61,
            refreshedAt: .now.addingTimeInterval(-60),
            dataSource: .real
        )
        let refreshed = QuotaSnapshot(
            weeklyQuotaPercent: 83,
            fiveHourQuotaPercent: 74,
            refreshedAt: .now,
            dataSource: .real
        )
        store.saveSnapshot(initial)
        let appState = AppState(
            snapshotStore: store,
            refreshService: MockRefreshService(snapshot: refreshed)
        )
        var emittedEvents: [AppStateEvent] = []
        let cancellable = appState.$stateEvent
            .dropFirst()
            .sink { event in
                XCTAssertEqual(store.loadState(), event.persistedState)
                XCTAssertEqual(event.persistedState.snapshot, event.presentationSnapshot.snapshot)
                XCTAssertEqual(event.persistedState.status, event.presentationSnapshot.status)
                XCTAssertEqual(event.persistedState.lastSuccessAt, event.presentationSnapshot.lastSuccessAt)
                XCTAssertEqual(event.persistedState.lastAttemptAt, event.presentationSnapshot.lastAttemptAt)
                XCTAssertEqual(event.persistedState.savedAt, event.presentationSnapshot.savedAt)
                emittedEvents.append(event)
            }

        await appState.refreshNow(trigger: .manual)

        XCTAssertEqual(emittedEvents.count, 2)
        XCTAssertEqual(emittedEvents[0].persistedState.snapshot, initial)
        XCTAssertEqual(emittedEvents[0].persistedState.status, .refreshing)
        XCTAssertNotNil(emittedEvents[0].persistedState.lastAttemptAt)
        XCTAssertEqual(emittedEvents[1].persistedState.snapshot, refreshed)
        XCTAssertEqual(emittedEvents[1].persistedState.status, .success)
        XCTAssertEqual(emittedEvents[1].persistedState.lastSuccessAt, refreshed.refreshedAt)
        XCTAssertEqual(emittedEvents[1], appState.stateEvent)
        XCTAssertTrue(emittedEvents[1].presentationSnapshot.isEquivalent(to: appState.presentationSnapshot))
        _ = cancellable
    }

    func testTriggerStormUsesOnePhysicalSlotAndOnlyTrailingResultCommits() async {
        let defaults = UserDefaults(suiteName: "CodexMonitorNativeTests.singleFlightStorm.\(UUID().uuidString)")!
        let store = SnapshotStore(defaults: defaults, key: "snapshot")
        let initial = QuotaSnapshot(
            weeklyQuotaPercent: 70,
            fiveHourQuotaPercent: 60,
            refreshedAt: .now,
            dataSource: .real
        )
        store.saveSnapshot(initial)
        let activeSnapshot = QuotaSnapshot(
            weeklyQuotaPercent: 10,
            fiveHourQuotaPercent: 20,
            refreshedAt: .now.addingTimeInterval(1),
            dataSource: .real
        )
        let trailingSnapshot = QuotaSnapshot(
            weeklyQuotaPercent: 90,
            fiveHourQuotaPercent: 80,
            refreshedAt: .now.addingTimeInterval(2),
            dataSource: .real
        )
        let service = QueueingResultRefreshService(results: [.success(activeSnapshot), .success(trailingSnapshot)])
        let appState = AppState(snapshotStore: store, refreshService: service)

        appState.refresh(trigger: .manual)
        await service.waitForCall(1)
        for trigger in [AppState.RefreshTrigger.scheduled, .wake, .manual, .scheduled, .wake] {
            appState.refresh(trigger: trigger)
        }
        await assertCallCount(1, for: service)
        await assertMaxConcurrentCalls(1, for: service)

        await service.release(call: 1)
        await service.waitForCall(2)
        XCTAssertEqual(appState.status, .refreshing)
        XCTAssertEqual(appState.snapshot, initial)
        XCTAssertEqual(store.loadState()?.snapshot, initial)
        XCTAssertEqual(store.loadState()?.status, .refreshing)

        await service.release(call: 2)
        await service.waitForCompletion(2)
        await Task.yield()

        await assertCallCount(2, for: service)
        await assertMaxConcurrentCalls(1, for: service)
        XCTAssertEqual(appState.snapshot, trailingSnapshot)
        XCTAssertEqual(appState.status, .success)
        XCTAssertEqual(store.loadState()?.snapshot, trailingSnapshot)
    }

    func testStormDuringTrailingRefreshConvergesToOneAdditionalTrailingRequest() async {
        let defaults = UserDefaults(suiteName: "CodexMonitorNativeTests.trailingStorm.\(UUID().uuidString)")!
        let store = SnapshotStore(defaults: defaults, key: "snapshot")
        let initial = QuotaSnapshot(
            weeklyQuotaPercent: 70,
            fiveHourQuotaPercent: 60,
            refreshedAt: .now,
            dataSource: .real
        )
        let firstResult = QuotaSnapshot(
            weeklyQuotaPercent: 10,
            fiveHourQuotaPercent: 20,
            refreshedAt: .now.addingTimeInterval(1),
            dataSource: .real
        )
        let secondResult = QuotaSnapshot(
            weeklyQuotaPercent: 40,
            fiveHourQuotaPercent: 50,
            refreshedAt: .now.addingTimeInterval(2),
            dataSource: .real
        )
        let finalResult = QuotaSnapshot(
            weeklyQuotaPercent: 90,
            fiveHourQuotaPercent: 80,
            refreshedAt: .now.addingTimeInterval(3),
            dataSource: .real
        )
        store.saveSnapshot(initial)
        let service = QueueingResultRefreshService(results: [
            .success(firstResult),
            .success(secondResult),
            .success(finalResult)
        ])
        let appState = AppState(snapshotStore: store, refreshService: service)

        let refreshNowTask = Task { await appState.refreshNow(trigger: .manual) }
        await service.waitForCall(1)
        appState.refresh(trigger: .scheduled)
        await service.release(call: 1)
        await service.waitForCall(2)

        for trigger in [AppState.RefreshTrigger.wake, .scheduled, .manual, .wake] {
            appState.refresh(trigger: trigger)
        }
        await assertCallCount(2, for: service)
        XCTAssertEqual(appState.snapshot, initial)

        await service.release(call: 2)
        await service.waitForCall(3)
        await assertCallCount(3, for: service)
        XCTAssertEqual(appState.snapshot, initial)
        XCTAssertEqual(appState.status, .refreshing)

        await service.release(call: 3)
        await refreshNowTask.value

        await assertMaxConcurrentCalls(1, for: service)
        XCTAssertEqual(appState.snapshot, finalResult)
        XCTAssertEqual(appState.status, .success)
        XCTAssertEqual(store.loadState()?.snapshot, finalResult)
    }

    func testRefreshNowWaitsForTheWholeCoalescedStorm() async {
        let defaults = UserDefaults(suiteName: "CodexMonitorNativeTests.refreshNowStorm.\(UUID().uuidString)")!
        let initial = QuotaSnapshot(weeklyQuotaPercent: 70, fiveHourQuotaPercent: 60, refreshedAt: .now, dataSource: .real)
        let trailingSnapshot = QuotaSnapshot(weeklyQuotaPercent: 90, fiveHourQuotaPercent: 80, refreshedAt: .now.addingTimeInterval(1), dataSource: .real)
        let service = QueueingResultRefreshService(results: [
            .success(QuotaSnapshot(weeklyQuotaPercent: 10, fiveHourQuotaPercent: 20, refreshedAt: .now, dataSource: .real)),
            .success(trailingSnapshot)
        ])
        let store = SnapshotStore(defaults: defaults, key: "snapshot")
        store.saveSnapshot(initial)
        let appState = AppState(snapshotStore: store, refreshService: service)
        let completionProbe = RefreshCompletionProbe()

        let refreshNowTask = Task {
            await appState.refreshNow(trigger: .manual)
            await completionProbe.markCompleted()
        }
        await service.waitForCall(1)
        appState.refresh(trigger: .wake)

        XCTAssertEqual(appState.status, .refreshing)
        await assertCallCount(1, for: service)
        await service.release(call: 1)
        await service.waitForCall(2)
        XCTAssertEqual(appState.status, .refreshing)
        XCTAssertEqual(appState.snapshot, initial)
        let completedBeforeTrailingResult = await completionProbe.isCompleted()
        XCTAssertFalse(completedBeforeTrailingResult)

        await service.release(call: 2)
        await refreshNowTask.value

        let completedAfterTrailingResult = await completionProbe.isCompleted()
        XCTAssertTrue(completedAfterTrailingResult)
        await assertMaxConcurrentCalls(1, for: service)
        XCTAssertEqual(appState.snapshot, trailingSnapshot)
        XCTAssertEqual(appState.status, .success)
    }
    func testManagedRefreshDoesNotRetainAppStateWhenProviderNeverFinishes() async {
        let defaults = UserDefaults(suiteName: "CodexMonitorNativeTests.release.\(UUID().uuidString)")!
        let service = BlockingRefreshService(snapshot: QuotaSnapshot(
            weeklyQuotaPercent: 80, fiveHourQuotaPercent: 60, refreshedAt: .now, dataSource: .real
        ))
        var appState: AppState? = AppState(
            snapshotStore: SnapshotStore(defaults: defaults, key: "snapshot"),
            refreshService: service
        )
        weak var weakAppState = appState

        appState?.refresh(trigger: .manual)
        await service.waitForStart()
        appState = nil

        XCTAssertNil(weakAppState)
    }

    func testShutdownResumesRefreshNowBeforeCancellationIgnoringProviderReturns() async {
        let defaults = UserDefaults(suiteName: "CodexMonitorNativeTests.shutdownWaiter.\(UUID().uuidString)")!
        let service = BlockingRefreshService(snapshot: QuotaSnapshot(
            weeklyQuotaPercent: 80,
            fiveHourQuotaPercent: 60,
            refreshedAt: .now,
            dataSource: .real
        ))
        let appState = AppState(
            snapshotStore: SnapshotStore(defaults: defaults, key: "snapshot"),
            refreshService: service
        )

        let refreshNowTask = Task { await appState.refreshNow(trigger: .manual) }
        await service.waitForStart()

        appState.shutdown()
        await refreshNowTask.value

        XCTAssertNotEqual(appState.status, .refreshing)
        XCTAssertEqual(appState.snapshot, .notConnected)

        await service.release()
        await Task.yield()
    }

    func testShutdownSettlesUIButQueuesNewRequestUntilCancellationIgnoringProviderReturns() async {
        let defaults = UserDefaults(suiteName: "CodexMonitorNativeTests.shutdown.\(UUID().uuidString)")!
        let oldSnapshot = QuotaSnapshot(weeklyQuotaPercent: 10, fiveHourQuotaPercent: 20, refreshedAt: .now, dataSource: .real)
        let refreshed = QuotaSnapshot(weeklyQuotaPercent: 80, fiveHourQuotaPercent: 60, refreshedAt: .now.addingTimeInterval(1), dataSource: .real)
        let service = QueueingResultRefreshService(results: [.success(oldSnapshot), .success(refreshed)])
        let store = SnapshotStore(defaults: defaults, key: "snapshot")
        let appState = AppState(snapshotStore: store, refreshService: service)

        appState.refresh(trigger: .manual)
        await service.waitForCall(1)
        appState.shutdown()
        XCTAssertNotEqual(appState.status, .refreshing)

        appState.refresh(trigger: .wake)
        await assertCallCount(1, for: service)
        await assertMaxConcurrentCalls(1, for: service)

        await service.release(call: 1)
        await service.waitForCall(2)
        await assertMaxConcurrentCalls(1, for: service)
        XCTAssertEqual(appState.snapshot, .notConnected)
        XCTAssertEqual(appState.status, .refreshing)
        XCTAssertEqual(store.loadState()?.snapshot, .notConnected)
        XCTAssertEqual(store.loadState()?.status, .refreshing)
        await service.release(call: 2)
        await service.waitForCompletion(2)
        await Task.yield()

        XCTAssertEqual(appState.snapshot, refreshed)
        XCTAssertEqual(appState.status, .success)
        XCTAssertEqual(store.loadState()?.snapshot, refreshed)
    }
    func testMixedTriggerEntrypointsCollapseToOneTrailingRefresh() async {
        let defaults = UserDefaults(suiteName: "CodexMonitorNativeTests.mixedSingleFlight.\(UUID().uuidString)")!
        let store = SnapshotStore(defaults: defaults, key: "snapshot")
        let base = Date.now
        let initial = QuotaSnapshot(weeklyQuotaPercent: 70, fiveHourQuotaPercent: 60, refreshedAt: base, dataSource: .real)
        let latest = QuotaSnapshot(weeklyQuotaPercent: 80, fiveHourQuotaPercent: 90, refreshedAt: base.addingTimeInterval(2), dataSource: .real)
        store.saveSnapshot(initial)
        let service = QueueingResultRefreshService(results: [
            .success(QuotaSnapshot(weeklyQuotaPercent: 10, fiveHourQuotaPercent: 20, refreshedAt: base.addingTimeInterval(1), dataSource: .real)),
            .success(latest)
        ])
        let appState = AppState(snapshotStore: store, refreshService: service)

        appState.refresh(trigger: .manual)
        await service.waitForCall(1)
        appState.refresh(trigger: .scheduled)
        appState.refresh(trigger: .wake)
        appState.refresh(trigger: .manual)

        await service.release(call: 1)
        await service.waitForCall(2)
        await service.release(call: 2)
        await service.waitForCompletion(2)
        await Task.yield()

        await assertCallCount(2, for: service)
        await assertMaxConcurrentCalls(1, for: service)
        XCTAssertEqual(appState.snapshot, latest)
        XCTAssertEqual(appState.status, .success)
        XCTAssertEqual(store.loadState()?.snapshot, latest)
    }
    func testSuccessfulRealRefreshUpdatesSnapshotAndPersistsIt() async {
        let defaults = UserDefaults(suiteName: "CodexMonitorNativeTests.success.\(UUID().uuidString)")!
        let store = SnapshotStore(defaults: defaults, key: "snapshot")
        let initial = QuotaSnapshot(
            weeklyQuotaPercent: 72, fiveHourQuotaPercent: 69, refreshedAt: .distantPast,
            dataSource: .real
        )
        store.saveSnapshot(initial)

        let refreshed = QuotaSnapshot(
            weeklyQuotaPercent: 75, fiveHourQuotaPercent: 63, refreshedAt: .now,
            dataSource: .real
        )
        let appState = AppState(snapshotStore: store, refreshService: MockRefreshService(snapshot: refreshed))

        await appState.refreshNow(trigger: .manual)

        XCTAssertEqual(appState.snapshot, refreshed)
        XCTAssertEqual(appState.status, .success)
        XCTAssertEqual(appState.dataSource, .real)
        XCTAssertEqual(appState.failureCount, 0)
        XCTAssertEqual(appState.realQuotaHealth, RealQuotaHealthDiagnostic(kind: .requestSucceeded, isUsingCachedSnapshot: false))
        XCTAssertEqual(store.loadSnapshot(), refreshed)
    }

    func testRestoredRealSnapshotMarksStaleDataImmediately() {
        let defaults = UserDefaults(suiteName: "CodexMonitorNativeTests.stale.\(UUID().uuidString)")!
        let store = SnapshotStore(defaults: defaults, key: "snapshot")
        let staleSnapshot = QuotaSnapshot(
            weeklyQuotaPercent: 72, fiveHourQuotaPercent: 69, refreshedAt: .distantPast,
            dataSource: .real
        )
        store.saveSnapshot(staleSnapshot)

        let appState = AppState(snapshotStore: store, refreshService: MockRefreshService(snapshot: staleSnapshot))

        XCTAssertEqual(appState.status, .stale)
        XCTAssertTrue(appState.isDataStale)
        XCTAssertEqual(store.loadState()?.status, .stale)
    }

    func testFreshnessTaskClearsAfterMarkingSnapshotStale() async {
        let suiteName = "CodexMonitorNativeTests.freshnessTaskCompletes.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SnapshotStore(defaults: defaults, key: "snapshot")
        let snapshot = QuotaSnapshot(
            weeklyQuotaPercent: 72,
            fiveHourQuotaPercent: 69,
            refreshedAt: .now,
            dataSource: .real
        )
        store.saveSnapshot(snapshot)
        let appState = AppState(
            snapshotStore: store,
            refreshService: MockRefreshService(snapshot: snapshot),
            staleAfterInterval: 0.2
        )

        XCTAssertEqual(appState.status, .success)
        XCTAssertTrue(appState.hasScheduledFreshnessTask)

        try? await Task.sleep(nanoseconds: 300_000_000)
        await Task.yield()

        XCTAssertEqual(appState.status, .stale)
        XCTAssertFalse(appState.hasScheduledFreshnessTask)
    }

    func testFailedRefreshReleasesCancelledFreshnessTask() async {
        let suiteName = "CodexMonitorNativeTests.freshnessTaskFailure.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SnapshotStore(defaults: defaults, key: "snapshot")
        let snapshot = QuotaSnapshot(
            weeklyQuotaPercent: 72,
            fiveHourQuotaPercent: 69,
            refreshedAt: .now,
            dataSource: .real
        )
        store.saveSnapshot(snapshot)
        let appState = AppState(
            snapshotStore: store,
            refreshService: MockRefreshService(snapshot: nil),
            staleAfterInterval: 60
        )

        XCTAssertTrue(appState.hasScheduledFreshnessTask)

        await appState.refreshNow(trigger: .manual)

        XCTAssertEqual(appState.status, .networkFailed)
        XCTAssertFalse(appState.hasScheduledFreshnessTask)
    }

    func testFailedRefreshKeepsLastSuccessfulSnapshot() async {
        let defaults = UserDefaults(suiteName: "CodexMonitorNativeTests.failure.\(UUID().uuidString)")!
        let store = SnapshotStore(defaults: defaults, key: "snapshot")
        let resetAt = Date.now.addingTimeInterval(90 * 60)
        let initial = QuotaSnapshot(
            weeklyQuotaPercent: 72, fiveHourQuotaPercent: 69, fiveHourResetAt: resetAt, refreshedAt: .distantPast,
            dataSource: .real
        )
        store.saveSnapshot(initial)

        let appState = AppState(snapshotStore: store, refreshService: MockRefreshService(snapshot: nil))

        await appState.refreshNow(trigger: .manual)

        XCTAssertEqual(appState.snapshot, initial)
        XCTAssertEqual(appState.status, .networkFailed)
        XCTAssertEqual(appState.dataSource, .real)
        XCTAssertEqual(appState.failureCount, 1)
        XCTAssertTrue(appState.isUsingCachedSnapshot)
        XCTAssertEqual(appState.realQuotaHealth, RealQuotaHealthDiagnostic(kind: .rpcRejected, isUsingCachedSnapshot: true))
        XCTAssertEqual(appState.effectiveFiveHourResetAt, resetAt)
        XCTAssertEqual(store.loadSnapshot(), initial)
    }

    func testFailedRefreshWithoutCachedSnapshotReportsNoCachedData() async {
        let defaults = UserDefaults(suiteName: "CodexMonitorNativeTests.failure.noCache.\(UUID().uuidString)")!
        let store = SnapshotStore(defaults: defaults, key: "snapshot")
        let appState = AppState(snapshotStore: store, refreshService: MockRefreshService(snapshot: nil))

        await appState.refreshNow(trigger: .manual)

        XCTAssertEqual(appState.snapshot, .notConnected)
        XCTAssertEqual(appState.status, .networkFailed)
        XCTAssertFalse(appState.isUsingCachedSnapshot)
        XCTAssertEqual(appState.realQuotaHealth, RealQuotaHealthDiagnostic(kind: .rpcRejected, isUsingCachedSnapshot: false))
    }

    func testFailedRefreshWithoutCachedSnapshotRestoresPersistedNetworkFailure() async {
        let defaults = UserDefaults(suiteName: "CodexMonitorNativeTests.failure.noCache.restore.\(UUID().uuidString)")!
        let store = SnapshotStore(defaults: defaults, key: "snapshot")
        let failed = AppState(snapshotStore: store, refreshService: MockRefreshService(snapshot: nil))

        await failed.refreshNow(trigger: .manual)

        XCTAssertEqual(store.loadState()?.snapshot, .notConnected)
        XCTAssertEqual(store.loadState()?.status, .networkFailed)

        let restored = AppState(
            snapshotStore: SnapshotStore(defaults: defaults, key: "snapshot"),
            refreshService: MockRefreshService(snapshot: nil)
        )

        XCTAssertEqual(restored.snapshot, .notConnected)
        XCTAssertEqual(restored.status, .networkFailed)
    }

    func testRefreshInProgressKeepsCachedQuotaAndRecoveryTimeVisible() async {
        let defaults = UserDefaults(suiteName: "CodexMonitorNativeTests.refreshing.\(UUID().uuidString)")!
        let store = SnapshotStore(defaults: defaults, key: "snapshot")
        let resetAt = Date.now.addingTimeInterval(2 * 60 * 60)
        let initial = QuotaSnapshot(
            weeklyQuotaPercent: 72, fiveHourQuotaPercent: 69, fiveHourResetAt: resetAt, refreshedAt: .now,
            dataSource: .real
        )
        store.saveSnapshot(initial)

        let refreshed = QuotaSnapshot(
            weeklyQuotaPercent: 81, fiveHourQuotaPercent: 63, fiveHourResetAt: Date.now.addingTimeInterval(4 * 60 * 60), refreshedAt: .now,
            dataSource: .real
        )
        let service = BlockingRefreshService(snapshot: refreshed)
        let appState = AppState(snapshotStore: store, refreshService: service)

        let task = Task {
            await appState.refreshNow(trigger: .manual)
        }
        await service.waitForStart()

        XCTAssertEqual(appState.status, .refreshing)
        XCTAssertEqual(appState.snapshot, initial)
        XCTAssertEqual(appState.effectiveFiveHourResetAt, resetAt)

        await service.release()
        await task.value
    }

    func testAuthFailureShowsLoginRequiredAndPreservesCachedSnapshot() async {
        let defaults = UserDefaults(suiteName: "CodexMonitorNativeTests.auth.\(UUID().uuidString)")!
        let store = SnapshotStore(defaults: defaults, key: "snapshot")
        let initial = QuotaSnapshot(
            weeklyQuotaPercent: 72, fiveHourQuotaPercent: 69, refreshedAt: .distantPast,
            dataSource: .real
        )
        store.saveSnapshot(initial)

        let appState = AppState(
            snapshotStore: store,
            refreshService: MockRefreshService(error: RealQuotaError.authenticationRequired)
        )

        await appState.refreshNow(trigger: .manual)

        XCTAssertEqual(appState.snapshot, initial)
        XCTAssertEqual(appState.status, .authRequired)
        XCTAssertEqual(appState.realQuotaHealth, RealQuotaHealthDiagnostic(kind: .loginRequired, isUsingCachedSnapshot: true))
        XCTAssertEqual(appState.lastErrorSummary, "需要重新登录 Codex")
    }

    func testParseFailureShowsResponseInvalidAndPreservesCachedSnapshot() async {
        let defaults = UserDefaults(suiteName: "CodexMonitorNativeTests.parse.\(UUID().uuidString)")!
        let store = SnapshotStore(defaults: defaults, key: "snapshot")
        let initial = QuotaSnapshot(
            weeklyQuotaPercent: 72, fiveHourQuotaPercent: 69, refreshedAt: .distantPast,
            dataSource: .real
        )
        store.saveSnapshot(initial)

        let appState = AppState(
            snapshotStore: store,
            refreshService: MockRefreshService(error: RealQuotaError.responseInvalid)
        )

        await appState.refreshNow(trigger: .manual)

        XCTAssertEqual(appState.snapshot, initial)
        XCTAssertEqual(appState.status, .parseFailed)
        XCTAssertEqual(appState.realQuotaHealth, RealQuotaHealthDiagnostic(kind: .responseInvalid, isUsingCachedSnapshot: true))
        XCTAssertEqual(appState.lastErrorSummary, "响应不可解析")
    }

    func testCodexNotFoundKeepsCachedSnapshotVisible() async {
        let defaults = UserDefaults(suiteName: "CodexMonitorNativeTests.codexMissing.\(UUID().uuidString)")!
        let store = SnapshotStore(defaults: defaults, key: "snapshot")
        let initial = QuotaSnapshot(
            weeklyQuotaPercent: 72, fiveHourQuotaPercent: 69, refreshedAt: .distantPast,
            dataSource: .real
        )
        store.saveSnapshot(initial)

        let appState = AppState(
            snapshotStore: store,
            refreshService: MockRefreshService(error: RealQuotaError.codexNotFound)
        )

        await appState.refreshNow(trigger: .manual)

        XCTAssertEqual(appState.snapshot, initial)
        XCTAssertEqual(appState.status, .networkFailed)
        XCTAssertEqual(appState.realQuotaHealth, RealQuotaHealthDiagnostic(kind: .executableMissing, isUsingCachedSnapshot: true))
        XCTAssertEqual(appState.lastErrorSummary, "未找到 codex 可执行文件")
    }

    func testRestoredRealSnapshotWaitsForFirstRequestWhileShowingCachedData() {
        let defaults = UserDefaults(suiteName: "CodexMonitorNativeTests.cachedHealth.\(UUID().uuidString)")!
        let store = SnapshotStore(defaults: defaults, key: "snapshot")
        let snapshot = QuotaSnapshot(
            weeklyQuotaPercent: 64, fiveHourQuotaPercent: 52, refreshedAt: .now,
            dataSource: .real
        )
        store.saveSnapshot(snapshot)

        let appState = AppState(snapshotStore: store, refreshService: MockRefreshService(snapshot: snapshot))

        XCTAssertEqual(appState.realQuotaHealth, RealQuotaHealthDiagnostic(kind: .waitingForFirstRequest, isUsingCachedSnapshot: true))
    }

    func testSnapshotStoreRestoresLatestSuccessfulSnapshotAcrossInstances() {
        let defaults = UserDefaults(suiteName: "CodexMonitorNativeTests.restore.\(UUID().uuidString)")!
        let store = SnapshotStore(defaults: defaults, key: "snapshot")
        let snapshot = QuotaSnapshot(
            weeklyQuotaPercent: 64, fiveHourQuotaPercent: 52, refreshedAt: .now,
            dataSource: .real
        )
        store.saveSnapshot(snapshot)

        let restoredState = AppState(snapshotStore: store, refreshService: MockRefreshService(snapshot: snapshot))

        XCTAssertEqual(restoredState.snapshot, snapshot)
        XCTAssertEqual(restoredState.status, .success)
        XCTAssertEqual(restoredState.dataSource, .real)
    }

    func testMockSnapshotShowsDemoMode() {
        let defaults = UserDefaults(suiteName: "CodexMonitorNativeTests.mock.\(UUID().uuidString)")!
        let store = SnapshotStore(defaults: defaults, key: "snapshot")
        let mockSnapshot = QuotaSnapshot(
            weeklyQuotaPercent: 72, fiveHourQuotaPercent: 69, refreshedAt: .distantPast,
            dataSource: .mock
        )
        store.saveSnapshot(mockSnapshot)

        let appState = AppState(snapshotStore: store, refreshService: MockRefreshService(snapshot: mockSnapshot))

        XCTAssertEqual(appState.dataSource, .mock)
        XCTAssertEqual(appState.status, .demoMode)
    }

    func testLegacySnapshotWithoutSchemaVersionIsTreatedAsMock() {
        let defaults = UserDefaults(suiteName: "CodexMonitorNativeTests.legacy.\(UUID().uuidString)")!
        let legacyJSON = """
        {"weeklyQuotaPercent":80,"fiveHourQuotaPercent":55,"refreshedAt":720575940.0}
        """
        defaults.set(Data(legacyJSON.utf8), forKey: "snapshot")

        let store = SnapshotStore(defaults: defaults, key: "snapshot")
        let loaded = store.loadSnapshot()

        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.dataSource, .mock)
        XCTAssertEqual(loaded?.schemaVersion, 1)
    }

    func testSnapshotStorePreservesQuotaFieldStatesAcrossPersistence() {
        let defaults = UserDefaults(suiteName: "CodexMonitorNativeTests.fieldStatePersistence.\(UUID().uuidString)")!
        let snapshot = QuotaSnapshot(
            weeklyQuotaPercent: 80,
            fiveHourQuotaPercent: 60,
            weeklyQuotaState: .cached,
            fiveHourQuotaState: .unavailable,
            refreshedAt: Date(timeIntervalSince1970: 100),
            dataSource: .real
        )
        let store = SnapshotStore(defaults: defaults, key: "snapshot")

        store.saveSnapshot(snapshot)

        XCTAssertEqual(store.loadSnapshot(), snapshot)
        XCTAssertEqual(store.loadSnapshot()?.weeklyQuotaState, .cached)
        XCTAssertEqual(store.loadSnapshot()?.fiveHourQuotaState, .unavailable)
    }

    func testSchemaV3RealSnapshotMigratesResetBanksAndClampsToThreeEntries() {
        let defaults = UserDefaults(suiteName: "CodexMonitorNativeTests.migrate.v3.\(UUID().uuidString)")!
        let refreshedAt = Date(timeIntervalSince1970: 1_718_000_000)
        let resetAt = refreshedAt.addingTimeInterval(90 * 60)
        let legacyJSON = """
        {"weeklyQuotaPercent":80,"fiveHourQuotaPercent":55,"fiveHourResetAt":\(resetAt.timeIntervalSince1970),"refreshedAt":\(refreshedAt.timeIntervalSince1970),"dataSource":"real","errorMessage":null,"schemaVersion":3,"resetBanks":[{"limitId":"d","windowId":"primary","displayName":"d.primary","remainingPercent":10,"resetAt":\(refreshedAt.addingTimeInterval(4 * 60 * 60).timeIntervalSince1970),"rawResetFields":[]},{"limitId":"b","windowId":"primary","displayName":"b.primary","remainingPercent":20,"resetAt":\(refreshedAt.addingTimeInterval(2 * 60 * 60).timeIntervalSince1970),"rawResetFields":[]},{"limitId":"c","windowId":"primary","displayName":"c.primary","remainingPercent":30,"resetAt":\(refreshedAt.addingTimeInterval(3 * 60 * 60).timeIntervalSince1970),"rawResetFields":[]},{"limitId":"a","windowId":"primary","displayName":"a.primary","remainingPercent":40,"resetAt":\(refreshedAt.addingTimeInterval(60 * 60).timeIntervalSince1970),"rawResetFields":[]}]}
        """
        defaults.set(Data(legacyJSON.utf8), forKey: "snapshot")

        let store = SnapshotStore(defaults: defaults, key: "snapshot")
        let loaded = store.loadSnapshot()

        XCTAssertEqual(loaded?.schemaVersion, QuotaSnapshot.currentSchemaVersion)
        XCTAssertEqual(loaded?.weeklyQuotaState, .live)
        XCTAssertEqual(loaded?.fiveHourQuotaState, .live)
        XCTAssertEqual(loaded?.resetBanks.count, 3)
        XCTAssertEqual(loaded?.resetBanks.map(\.id), ["a.primary", "b.primary", "c.primary"])
    }

    func testSchemaV3RealSnapshotWithoutResetCreditsStillShowsUnknownResetCreditTiming() {
        let defaults = UserDefaults(suiteName: "CodexMonitorNativeTests.migrate.synth.\(UUID().uuidString)")!
        let refreshedAt = Date(timeIntervalSince1970: 1_718_000_000)
        let resetAt = refreshedAt.addingTimeInterval(90 * 60)
        let legacyJSON = """
        {"weeklyQuotaPercent":80,"fiveHourQuotaPercent":55,"fiveHourResetAt":\(resetAt.timeIntervalSince1970),"refreshedAt":\(refreshedAt.timeIntervalSince1970),"dataSource":"real","errorMessage":null,"schemaVersion":3}
        """
        defaults.set(Data(legacyJSON.utf8), forKey: "snapshot")

        let store = SnapshotStore(defaults: defaults, key: "snapshot")
        let appState = AppState(snapshotStore: store, refreshService: MockRefreshService(snapshot: nil))
        let summary = StatusPopoverFormatting.resetCreditsSummary(
            snapshot: appState.snapshot,
            status: appState.displayStatus,
            now: refreshedAt,
            calendar: Calendar(identifier: .gregorian),
            locale: Locale(identifier: "en_US"),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        XCTAssertEqual(summary?.countLine, "重置次数未知")
        XCTAssertEqual(summary?.timingLine, "到期时间暂不可用")
    }

    func testSnapshotStoreRejectsCorruptedEnvelopeAndKeepsBackupSnapshot() {
        let defaults = UserDefaults(suiteName: "CodexMonitorNativeTests.corruptEnvelope.\(UUID().uuidString)")!
        let store = SnapshotStore(defaults: defaults, key: "snapshot")
        let first = QuotaSnapshot(weeklyQuotaPercent: 60, fiveHourQuotaPercent: 40, refreshedAt: Date(timeIntervalSince1970: 100), dataSource: .real)
        let second = QuotaSnapshot(weeklyQuotaPercent: 55, fiveHourQuotaPercent: 35, refreshedAt: Date(timeIntervalSince1970: 200), dataSource: .real)
        store.saveSnapshot(first)
        store.saveSnapshot(second)
        defaults.set(Data("truncated".utf8), forKey: "snapshot")

        XCTAssertEqual(store.loadSnapshot(), first)
        XCTAssertTrue(defaults.object(forKey: "snapshot.corrupt") != nil)
    }

    func testSnapshotStoreDoesNotLetOlderWriteReplaceNewerSnapshot() {
        let defaults = UserDefaults(suiteName: "CodexMonitorNativeTests.newestWins.\(UUID().uuidString)")!
        let store = SnapshotStore(defaults: defaults, key: "snapshot")
        let newer = QuotaSnapshot(weeklyQuotaPercent: 80, fiveHourQuotaPercent: 70, refreshedAt: Date(timeIntervalSince1970: 200), dataSource: .real)
        let older = QuotaSnapshot(weeklyQuotaPercent: 10, fiveHourQuotaPercent: 5, refreshedAt: Date(timeIntervalSince1970: 100), dataSource: .real)

        store.saveSnapshot(newer)
        store.saveSnapshot(older)

        XCTAssertEqual(store.loadSnapshot(), newer)
    }

    func testRefreshFailurePersistsStatusWithoutClearingLastRealSnapshot() async {
        let defaults = UserDefaults(suiteName: "CodexMonitorNativeTests.persistedStatus.\(UUID().uuidString)")!
        let snapshot = QuotaSnapshot(weeklyQuotaPercent: 82, fiveHourQuotaPercent: 73, refreshedAt: .now, dataSource: .real)
        let store = SnapshotStore(defaults: defaults, key: "snapshot")
        store.saveSnapshot(snapshot)

        let failed = AppState(snapshotStore: store, refreshService: MockRefreshService(snapshot: nil))
        await failed.refreshNow(trigger: .manual)

        let restored = AppState(snapshotStore: SnapshotStore(defaults: defaults, key: "snapshot"), refreshService: MockRefreshService(snapshot: snapshot))
        XCTAssertEqual(restored.snapshot, snapshot)
        XCTAssertEqual(restored.status, .networkFailed)
        XCTAssertEqual(restored.failureCount, 1)
    }

    func testMockRefreshDoesNotReplacePersistedRealSnapshot() async {
        let defaults = UserDefaults(suiteName: "CodexMonitorNativeTests.realThenMock.\(UUID().uuidString)")!
        let real = QuotaSnapshot(weeklyQuotaPercent: 88, fiveHourQuotaPercent: 77, refreshedAt: Date(timeIntervalSince1970: 200), dataSource: .real)
        let mock = QuotaSnapshot(weeklyQuotaPercent: 1, fiveHourQuotaPercent: 2, refreshedAt: Date(timeIntervalSince1970: 300), dataSource: .mock)
        let store = SnapshotStore(defaults: defaults, key: "snapshot")
        store.saveSnapshot(real)

        let appState = AppState(snapshotStore: store, refreshService: MockRefreshService(snapshot: mock))
        var widgetStates: [WidgetDisplayState] = []
        var reloadCount = 0
        let bridge = WidgetTimelineBridge(
            appState: appState,
            saveState: { widgetStates.append($0) },
            reloadTimelines: { reloadCount += 1 }
        )
        widgetStates.removeAll()
        reloadCount = 0

        await appState.refreshNow(trigger: .manual)

        XCTAssertEqual(appState.snapshot, real)
        XCTAssertEqual(appState.dataSource, .real)
        XCTAssertEqual(store.loadState(), appState.stateEvent.persistedState)
        XCTAssertEqual(appState.presentationSnapshot.snapshot, real)
        XCTAssertFalse(widgetStates.contains { $0.snapshot == mock })
        XCTAssertEqual(widgetStates.last?.snapshot, real)
        XCTAssertEqual(widgetStates.last?.status, appState.displayStatus)
        XCTAssertEqual(reloadCount, 1)

        let restored = AppState(snapshotStore: SnapshotStore(defaults: defaults, key: "snapshot"), refreshService: MockRefreshService(snapshot: real))
        XCTAssertEqual(restored.snapshot, real)
        XCTAssertEqual(restored.dataSource, .real)
        _ = bridge
    }

    func testOutOfOrderRealRefreshDoesNotReplaceNewerCachedSnapshot() async {
        let defaults = UserDefaults(suiteName: "CodexMonitorNativeTests.outOfOrder.\(UUID().uuidString)")!
        let newer = QuotaSnapshot(weeklyQuotaPercent: 90, fiveHourQuotaPercent: 80, refreshedAt: Date(timeIntervalSince1970: 200), dataSource: .real)
        let older = QuotaSnapshot(weeklyQuotaPercent: 10, fiveHourQuotaPercent: 20, refreshedAt: Date(timeIntervalSince1970: 100), dataSource: .real)
        let store = SnapshotStore(defaults: defaults, key: "snapshot")
        store.saveSnapshot(newer)

        let appState = AppState(
            snapshotStore: store,
            refreshService: MockRefreshService(snapshot: older),
            now: { Date(timeIntervalSince1970: 250) }
        )
        await appState.refreshNow(trigger: .manual)

        XCTAssertEqual(appState.snapshot, newer)
        XCTAssertNotEqual(appState.status, .refreshing)
        XCTAssertTrue(appState.hasScheduledFreshnessTask)
    }

    func testTemporalReconciliationMarksSuccessStaleAtExactBoundaryAndPersistsIt() {
        let defaults = UserDefaults(suiteName: "CodexMonitorNativeTests.clockForward.\(UUID().uuidString)")!
        let store = SnapshotStore(defaults: defaults, key: "snapshot")
        let refreshedAt = Date(timeIntervalSince1970: 1_000)
        var currentDate = refreshedAt.addingTimeInterval(59)
        let snapshot = QuotaSnapshot(
            weeklyQuotaPercent: 72,
            fiveHourQuotaPercent: 69,
            refreshedAt: refreshedAt,
            dataSource: .real
        )
        store.saveSnapshot(snapshot)
        let appState = AppState(
            snapshotStore: store,
            refreshService: MockRefreshService(snapshot: snapshot),
            staleAfterInterval: 60,
            now: { currentDate }
        )

        XCTAssertEqual(appState.status, .success)
        currentDate = refreshedAt.addingTimeInterval(60)

        appState.reconcileTemporalState()

        XCTAssertEqual(appState.status, .stale)
        XCTAssertEqual(appState.stateEvent.updateReason, .temporalReconciliation)
        XCTAssertEqual(store.loadState()?.status, .stale)
        XCTAssertFalse(appState.hasScheduledFreshnessTask)
    }

    func testClockRollbackKeepsFreshSnapshotAndRearmsTemporalCheck() {
        let defaults = UserDefaults(suiteName: "CodexMonitorNativeTests.clockRollback.\(UUID().uuidString)")!
        let store = SnapshotStore(defaults: defaults, key: "snapshot")
        let refreshedAt = Date(timeIntervalSince1970: 2_000)
        var currentDate = refreshedAt
        let snapshot = QuotaSnapshot(
            weeklyQuotaPercent: 72,
            fiveHourQuotaPercent: 69,
            refreshedAt: refreshedAt,
            dataSource: .real
        )
        store.saveSnapshot(snapshot)
        let appState = AppState(
            snapshotStore: store,
            refreshService: MockRefreshService(snapshot: snapshot),
            staleAfterInterval: 60,
            now: { currentDate }
        )

        currentDate = refreshedAt.addingTimeInterval(-3_600)
        appState.reconcileTemporalState()

        XCTAssertEqual(appState.status, .success)
        XCTAssertFalse(appState.isDataStale)
        XCTAssertTrue(appState.hasScheduledFreshnessTask)
        XCTAssertEqual(appState.stateEvent.updateReason, .temporalReconciliation)
    }

    func testFreshnessTaskWakeAfterClockRollbackRearmsUntilWallDeadline() async {
        let defaults = UserDefaults(suiteName: "CodexMonitorNativeTests.clockRollbackWake.\(UUID().uuidString)")!
        let store = SnapshotStore(defaults: defaults, key: "snapshot")
        let refreshedAt = Date(timeIntervalSince1970: 3_000)
        var currentDate = refreshedAt
        let snapshot = QuotaSnapshot(
            weeklyQuotaPercent: 72,
            fiveHourQuotaPercent: 69,
            refreshedAt: refreshedAt,
            dataSource: .real
        )
        store.saveSnapshot(snapshot)
        let sleeper = AppStateTemporalSequenceSleep()
        let appState = AppState(
            snapshotStore: store,
            refreshService: MockRefreshService(snapshot: snapshot),
            staleAfterInterval: 60,
            now: { currentDate },
            sleep: { nanoseconds in await sleeper.wait(nanoseconds: nanoseconds) }
        )

        await sleeper.waitForCall(1)
        currentDate = refreshedAt.addingTimeInterval(-3_600)
        await sleeper.release(call: 1)
        await sleeper.waitForCall(2)

        let firstDelay = await sleeper.delay(forCall: 1)
        let secondDelay = await sleeper.delay(forCall: 2)
        XCTAssertEqual(firstDelay, 60_000_000_000)
        XCTAssertEqual(secondDelay, 60_000_000_000)
        XCTAssertEqual(appState.status, .success)
        XCTAssertTrue(appState.hasScheduledFreshnessTask)

        currentDate = refreshedAt.addingTimeInterval(60)
        await sleeper.release(call: 2)
        for _ in 0..<100 where appState.status != .stale {
            await Task.yield()
        }

        XCTAssertEqual(appState.status, .stale)
        XCTAssertFalse(appState.hasScheduledFreshnessTask)
    }

    func testRestoredFreshnessUsesPersistedLastSuccessAsSingleAuthority() {
        let defaults = UserDefaults(suiteName: "CodexMonitorNativeTests.lastSuccessAuthority.\(UUID().uuidString)")!
        let store = SnapshotStore(defaults: defaults, key: "snapshot")
        let currentDate = Date(timeIntervalSince1970: 10_000)
        let snapshot = QuotaSnapshot(
            weeklyQuotaPercent: 72,
            fiveHourQuotaPercent: 69,
            refreshedAt: currentDate.addingTimeInterval(-1_000),
            dataSource: .real
        )
        store.saveState(
            PersistedAppState(
                snapshot: snapshot,
                status: .success,
                lastSuccessAt: currentDate.addingTimeInterval(-10),
                lastAttemptAt: nil,
                failureCount: 0,
                savedAt: currentDate
            )
        )

        let appState = AppState(
            snapshotStore: store,
            refreshService: MockRefreshService(snapshot: snapshot),
            staleAfterInterval: 60,
            now: { currentDate }
        )

        XCTAssertEqual(appState.status, .success)
        XCTAssertFalse(appState.isDataStale)
        XCTAssertTrue(appState.hasScheduledFreshnessTask)
    }

    func testQuotaResetBoundaryPublishesExpiredProjectionAndRequestsRefresh() async {
        let defaults = UserDefaults(suiteName: "CodexMonitorNativeTests.quotaResetBoundary.\(UUID().uuidString)")!
        let store = SnapshotStore(defaults: defaults, key: "snapshot")
        let baseDate = Date(timeIntervalSince1970: 20_000)
        let resetAt = baseDate.addingTimeInterval(10)
        var currentDate = baseDate
        let initial = QuotaSnapshot(
            weeklyQuotaPercent: 42,
            fiveHourQuotaPercent: 69,
            refreshedAt: baseDate,
            dataSource: .real,
            quotaWindows: [
                QuotaWindow(
                    limitId: "codex",
                    windowId: "secondary",
                    kind: .weekly,
                    durationMinutes: 10_080,
                    remainingPercent: 42,
                    resetAt: resetAt
                )
            ]
        )
        let refreshed = QuotaSnapshot(
            weeklyQuotaPercent: 100,
            fiveHourQuotaPercent: 69,
            refreshedAt: resetAt,
            dataSource: .real
        )
        store.saveSnapshot(initial)
        let refreshService = BlockingRefreshService(snapshot: refreshed)
        let sleepGate = AppStateTemporalSleepGate()
        let appState = AppState(
            snapshotStore: store,
            refreshService: refreshService,
            now: { currentDate },
            sleep: { nanoseconds in
                if nanoseconds <= 30_000_000_000 {
                    await sleepGate.wait()
                } else {
                    try await Task.sleep(nanoseconds: nanoseconds)
                }
            }
        )

        await sleepGate.waitUntilSleeping()
        currentDate = resetAt
        await sleepGate.release()
        await refreshService.waitForStart()

        XCTAssertEqual(appState.status, .refreshing)
        XCTAssertEqual(
            StatusPopoverFormatting.weeklyQuotaMenuTitle(
                snapshot: appState.snapshot,
                status: appState.status,
                now: currentDate
            ),
            "--%"
        )

        await refreshService.release()
        for _ in 0..<100 where appState.snapshot != refreshed {
            await Task.yield()
        }

        let refreshCount = await refreshService.callCount()
        XCTAssertEqual(refreshCount, 1)
        XCTAssertEqual(appState.snapshot, refreshed)
        XCTAssertEqual(appState.status, .success)
    }

    func testTemporalDelayConversionClampsExtremeAndInvalidValuesWithoutOverflow() {
        let maximumNanoseconds = (UInt64.max / 1_000_000_000) * 1_000_000_000

        XCTAssertEqual(AppState.nanoseconds(for: .greatestFiniteMagnitude), maximumNanoseconds)
        XCTAssertEqual(AppState.nanoseconds(for: .infinity), maximumNanoseconds)
        XCTAssertEqual(AppState.nanoseconds(for: .nan), 1)
        XCTAssertEqual(AppState.nanoseconds(for: 0), 1)
        XCTAssertEqual(AppState.nanoseconds(for: 0.25), 250_000_000)
    }

    func testEnvelopeWrappedOldSnapshotMigratesBeforeReturning() throws {
        let defaults = UserDefaults(suiteName: "CodexMonitorNativeTests.envelopeMigration.\(UUID().uuidString)")!
        let old = QuotaSnapshot(weeklyQuotaPercent: 80, fiveHourQuotaPercent: 60, fiveHourResetAt: Date(timeIntervalSince1970: 200), refreshedAt: Date(timeIntervalSince1970: 100), dataSource: .real, schemaVersion: 3)
        let state = PersistedAppState(snapshot: old, status: .success, lastSuccessAt: old.refreshedAt, lastAttemptAt: nil, failureCount: 0)
        let envelope = try PersistenceEnvelope(value: state, revision: 1)
        defaults.set(try JSONEncoder().encode(envelope), forKey: "snapshot")

        let loaded = SnapshotStore(defaults: defaults, key: "snapshot").loadSnapshot()

        XCTAssertEqual(loaded?.schemaVersion, QuotaSnapshot.currentSchemaVersion)
        XCTAssertEqual(loaded?.resetBanks.count, 2)
    }

    func testCorruptPrimaryRecoversAndMigratesOldBackupEnvelope() throws {
        let defaults = UserDefaults(suiteName: "CodexMonitorNativeTests.backupMigration.\(UUID().uuidString)")!
        let old = QuotaSnapshot(weeklyQuotaPercent: 80, fiveHourQuotaPercent: 60, fiveHourResetAt: Date(timeIntervalSince1970: 200), refreshedAt: Date(timeIntervalSince1970: 100), dataSource: .real, schemaVersion: 3)
        let state = PersistedAppState(snapshot: old, status: .success, lastSuccessAt: old.refreshedAt, lastAttemptAt: nil, failureCount: 0)
        let envelope = try PersistenceEnvelope(value: state, revision: 1)
        defaults.set(Data("corrupt".utf8), forKey: "snapshot")
        defaults.set(try JSONEncoder().encode(envelope), forKey: "snapshot.backup")

        let loaded = SnapshotStore(defaults: defaults, key: "snapshot").loadSnapshot()

        XCTAssertEqual(loaded?.schemaVersion, QuotaSnapshot.currentSchemaVersion)
        XCTAssertEqual(loaded?.resetBanks.count, 2)
    }

    func testCorruptPrimaryRecoversAndMigratesRawLegacyBackup() throws {
        let defaults = UserDefaults(suiteName: "CodexMonitorNativeTests.rawBackupMigration.\(UUID().uuidString)")!
        let legacy = QuotaSnapshot(
            weeklyQuotaPercent: 80,
            fiveHourQuotaPercent: 60,
            fiveHourResetAt: Date(timeIntervalSince1970: 200),
            refreshedAt: Date(timeIntervalSince1970: 100),
            dataSource: .real,
            schemaVersion: 3
        )
        defaults.set(Data("corrupt".utf8), forKey: "snapshot")
        defaults.set(try JSONEncoder().encode(legacy), forKey: "snapshot.backup")

        let store = SnapshotStore(defaults: defaults, key: "snapshot")
        let loaded = store.loadState()
        let primary = try XCTUnwrap(defaults.data(forKey: "snapshot"))
        let envelope = try JSONDecoder().decode(PersistenceEnvelope.self, from: primary)
        let persisted = try envelope.decode(PersistedAppState.self)

        XCTAssertEqual(loaded?.snapshot.schemaVersion, QuotaSnapshot.currentSchemaVersion)
        XCTAssertEqual(persisted.schemaVersion, PersistedAppState.currentSchemaVersion)
        XCTAssertEqual(persisted.snapshot.schemaVersion, QuotaSnapshot.currentSchemaVersion)
        XCTAssertNotNil(defaults.data(forKey: "snapshot.corrupt"))
    }

    func testRawRealSnapshotWithoutSchemaVersionMigratesToCurrentSchema() throws {
        let defaults = UserDefaults(suiteName: "CodexMonitorNativeTests.rawRealMissingSchema.\(UUID().uuidString)")!
        let real = QuotaSnapshot(
            weeklyQuotaPercent: 80,
            fiveHourQuotaPercent: 60,
            refreshedAt: Date(timeIntervalSince1970: 100),
            dataSource: .real
        )
        var rawObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(real)) as? [String: Any]
        )
        rawObject.removeValue(forKey: "schemaVersion")
        let rawData = try JSONSerialization.data(withJSONObject: rawObject)
        defaults.set(rawData, forKey: "snapshot")

        let loaded = SnapshotStore(defaults: defaults, key: "snapshot").loadState()

        XCTAssertEqual(loaded?.snapshot.dataSource, .real)
        XCTAssertEqual(loaded?.snapshot.schemaVersion, QuotaSnapshot.currentSchemaVersion)
        XCTAssertEqual(loaded?.schemaVersion, PersistedAppState.currentSchemaVersion)
        XCTAssertEqual(defaults.data(forKey: "snapshot.backup"), rawData)
    }

    func testFutureAppStateSchemaUsesCurrentBackupWithoutDowngradingPrimary() throws {
        let defaults = UserDefaults(suiteName: "CodexMonitorNativeTests.futureAppStateSchema.\(UUID().uuidString)")!
        let trusted = QuotaSnapshot(weeklyQuotaPercent: 70, fiveHourQuotaPercent: 60, refreshedAt: Date(timeIntervalSince1970: 100), dataSource: .real)
        let future = QuotaSnapshot(weeklyQuotaPercent: 10, fiveHourQuotaPercent: 20, refreshedAt: Date(timeIntervalSince1970: 200), dataSource: .real)
        let backup = try JSONEncoder().encode(PersistenceEnvelope(
            value: PersistedAppState(snapshot: trusted, status: .success, lastSuccessAt: trusted.refreshedAt, lastAttemptAt: nil, failureCount: 0),
            revision: 1
        ))
        let primary = try JSONEncoder().encode(PersistenceEnvelope(
            value: PersistedAppState(snapshot: future, status: .success, lastSuccessAt: future.refreshedAt, lastAttemptAt: nil, failureCount: 0, schemaVersion: PersistedAppState.currentSchemaVersion + 1),
            revision: 2
        ))
        defaults.set(primary, forKey: "snapshot")
        defaults.set(backup, forKey: "snapshot.backup")

        let loaded = SnapshotStore(defaults: defaults, key: "snapshot").loadSnapshot()

        XCTAssertEqual(loaded, trusted)
        XCTAssertEqual(defaults.data(forKey: "snapshot"), primary)
        XCTAssertNil(defaults.data(forKey: "snapshot.corrupt"))
    }

    func testFutureSnapshotSchemaUsesCurrentBackupWithoutDowngradingPrimary() throws {
        let defaults = UserDefaults(suiteName: "CodexMonitorNativeTests.futureSnapshotSchema.\(UUID().uuidString)")!
        let trusted = QuotaSnapshot(weeklyQuotaPercent: 70, fiveHourQuotaPercent: 60, refreshedAt: Date(timeIntervalSince1970: 100), dataSource: .real)
        let future = QuotaSnapshot(weeklyQuotaPercent: 10, fiveHourQuotaPercent: 20, refreshedAt: Date(timeIntervalSince1970: 200), dataSource: .real, schemaVersion: QuotaSnapshot.currentSchemaVersion + 1)
        let backup = try JSONEncoder().encode(PersistenceEnvelope(
            value: PersistedAppState(snapshot: trusted, status: .success, lastSuccessAt: trusted.refreshedAt, lastAttemptAt: nil, failureCount: 0),
            revision: 1
        ))
        let primary = try JSONEncoder().encode(PersistenceEnvelope(
            value: PersistedAppState(snapshot: future, status: .success, lastSuccessAt: future.refreshedAt, lastAttemptAt: nil, failureCount: 0),
            revision: 2
        ))
        defaults.set(primary, forKey: "snapshot")
        defaults.set(backup, forKey: "snapshot.backup")

        let loaded = SnapshotStore(defaults: defaults, key: "snapshot").loadSnapshot()

        XCTAssertEqual(loaded, trusted)
        XCTAssertEqual(defaults.data(forKey: "snapshot"), primary)
        XCTAssertNil(defaults.data(forKey: "snapshot.corrupt"))
    }

    func testRawFutureSnapshotUsesBackupWithoutDowngradingPrimary() throws {
        let defaults = UserDefaults(suiteName: "CodexMonitorNativeTests.rawFutureSnapshot.\(UUID().uuidString)")!
        let trusted = QuotaSnapshot(weeklyQuotaPercent: 70, fiveHourQuotaPercent: 60, refreshedAt: Date(timeIntervalSince1970: 100), dataSource: .real)
        let future = QuotaSnapshot(weeklyQuotaPercent: 90, fiveHourQuotaPercent: 80, refreshedAt: Date(timeIntervalSince1970: 300), dataSource: .real, schemaVersion: QuotaSnapshot.currentSchemaVersion + 1)
        let primary = try JSONEncoder().encode(future)
        let backup = try JSONEncoder().encode(PersistenceEnvelope(
            value: PersistedAppState(snapshot: trusted, status: .success, lastSuccessAt: trusted.refreshedAt, lastAttemptAt: nil, failureCount: 0),
            revision: 1
        ))
        defaults.set(primary, forKey: "snapshot")
        defaults.set(backup, forKey: "snapshot.backup")
        let store = SnapshotStore(defaults: defaults, key: "snapshot")

        store.saveSnapshot(trusted)
        XCTAssertEqual(defaults.data(forKey: "snapshot"), primary)
        XCTAssertEqual(store.loadSnapshot(), trusted)
        XCTAssertEqual(defaults.data(forKey: "snapshot"), primary)
        XCTAssertNil(defaults.data(forKey: "snapshot.corrupt"))
    }

    func testSavePreservesStructurallyDecodedFutureSchemaEnvelope() throws {
        let defaults = UserDefaults(suiteName: "CodexMonitorNativeTests.futureSchemaSave.\(UUID().uuidString)")!
        let future = QuotaSnapshot(weeklyQuotaPercent: 70, fiveHourQuotaPercent: 60, refreshedAt: Date(timeIntervalSince1970: 100), dataSource: .real)
        let primary = try JSONEncoder().encode(PersistenceEnvelope(
            value: PersistedAppState(snapshot: future, status: .success, lastSuccessAt: future.refreshedAt, lastAttemptAt: nil, failureCount: 0, schemaVersion: PersistedAppState.currentSchemaVersion + 1),
            revision: 1
        ))
        defaults.set(primary, forKey: "snapshot")

        SnapshotStore(defaults: defaults, key: "snapshot").saveSnapshot(
            QuotaSnapshot(weeklyQuotaPercent: 10, fiveHourQuotaPercent: 20, refreshedAt: Date(timeIntervalSince1970: 200), dataSource: .real)
        )

        XCTAssertEqual(defaults.data(forKey: "snapshot"), primary)
    }

    func testSavePreservesFutureEnvelopeFormat() throws {
        let defaults = UserDefaults(suiteName: "CodexMonitorNativeTests.futureEnvelopeSave.\(UUID().uuidString)")!
        let snapshot = QuotaSnapshot(weeklyQuotaPercent: 70, fiveHourQuotaPercent: 60, refreshedAt: Date(timeIntervalSince1970: 100), dataSource: .real)
        let envelope = try PersistenceEnvelope(
            value: PersistedAppState(snapshot: snapshot, status: .success, lastSuccessAt: snapshot.refreshedAt, lastAttemptAt: nil, failureCount: 0),
            revision: 1
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(envelope)) as? [String: Any]
        )
        object["formatVersion"] = PersistenceEnvelope.currentFormatVersion + 1
        let primary = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        defaults.set(primary, forKey: "snapshot")

        SnapshotStore(defaults: defaults, key: "snapshot").saveSnapshot(
            QuotaSnapshot(weeklyQuotaPercent: 10, fiveHourQuotaPercent: 20, refreshedAt: Date(timeIntervalSince1970: 200), dataSource: .real)
        )

        XCTAssertEqual(defaults.data(forKey: "snapshot"), primary)
    }

    func testCorruptFutureEnvelopeFormatRecoversCurrentBackup() throws {
        let defaults = UserDefaults(suiteName: "CodexMonitorNativeTests.corruptFutureEnvelope.\(UUID().uuidString)")!
        let trusted = QuotaSnapshot(weeklyQuotaPercent: 70, fiveHourQuotaPercent: 60, refreshedAt: Date(timeIntervalSince1970: 100), dataSource: .real)
        let state = PersistedAppState(snapshot: trusted, status: .success, lastSuccessAt: trusted.refreshedAt, lastAttemptAt: nil, failureCount: 0)
        let backup = try JSONEncoder().encode(PersistenceEnvelope(value: state, revision: 1))
        var corruptObject = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(PersistenceEnvelope(value: state, revision: 2))
            ) as? [String: Any]
        )
        corruptObject["formatVersion"] = PersistenceEnvelope.currentFormatVersion + 1
        corruptObject["checksum"] = "invalid"
        let primary = try JSONSerialization.data(withJSONObject: corruptObject, options: [.sortedKeys])
        defaults.set(primary, forKey: "snapshot")
        defaults.set(backup, forKey: "snapshot.backup")

        XCTAssertEqual(SnapshotStore(defaults: defaults, key: "snapshot").loadSnapshot(), trusted)
        XCTAssertEqual(defaults.data(forKey: "snapshot"), backup)
        XCTAssertEqual(defaults.data(forKey: "snapshot.corrupt"), primary)
    }

    func testMaxRevisionDoesNotTrapOrOverwriteTrustedState() throws {
        let defaults = UserDefaults(suiteName: "CodexMonitorNativeTests.maxRevision.\(UUID().uuidString)")!
        let trusted = QuotaSnapshot(weeklyQuotaPercent: 70, fiveHourQuotaPercent: 60, refreshedAt: Date(timeIntervalSince1970: 100), dataSource: .real)
        let state = PersistedAppState(snapshot: trusted, status: .success, lastSuccessAt: trusted.refreshedAt, lastAttemptAt: nil, failureCount: 0)
        let envelope = try PersistenceEnvelope(value: state, revision: .max)
        defaults.set(try JSONEncoder().encode(envelope), forKey: "snapshot")

        SnapshotStore(defaults: defaults, key: "snapshot").saveSnapshot(QuotaSnapshot(weeklyQuotaPercent: 1, fiveHourQuotaPercent: 1, refreshedAt: Date(timeIntervalSince1970: 200), dataSource: .real))

        XCTAssertEqual(SnapshotStore(defaults: defaults, key: "snapshot").loadSnapshot(), trusted)
    }

    func testConsecutiveFailuresEscalateBackoff() async {
        let defaults = UserDefaults(suiteName: "CodexMonitorNativeTests.backoff.\(UUID().uuidString)")!
        let store = SnapshotStore(defaults: defaults, key: "snapshot")
        let initial = QuotaSnapshot(
            weeklyQuotaPercent: 72, fiveHourQuotaPercent: 69, refreshedAt: .distantPast,
            dataSource: .real
        )
        store.saveSnapshot(initial)

        let appState = AppState(snapshotStore: store, refreshService: MockRefreshService(snapshot: nil))

        // 1st failure → 5 min
        await appState.refreshNow(trigger: .manual)
        XCTAssertEqual(appState.backoffInterval, 300)
        XCTAssertEqual(appState.failureCount, 1)

        // 2nd failure → 10 min
        await appState.refreshNow(trigger: .manual)
        XCTAssertEqual(appState.backoffInterval, 600)
        XCTAssertEqual(appState.failureCount, 2)

        // 3rd failure → 15 min
        await appState.refreshNow(trigger: .manual)
        XCTAssertEqual(appState.backoffInterval, 900)
        XCTAssertEqual(appState.failureCount, 3)

        // 4th failure → still 15 min
        await appState.refreshNow(trigger: .manual)
        XCTAssertEqual(appState.backoffInterval, 900)
        XCTAssertEqual(appState.failureCount, 4)
    }

    func testSuccessResetsFailureCountAndBackoff() async {
        let defaults = UserDefaults(suiteName: "CodexMonitorNativeTests.reset.\(UUID().uuidString)")!
        let store = SnapshotStore(defaults: defaults, key: "snapshot")
        let initial = QuotaSnapshot(
            weeklyQuotaPercent: 72, fiveHourQuotaPercent: 69, refreshedAt: .distantPast,
            dataSource: .real
        )
        store.saveSnapshot(initial)

        let appState = AppState(snapshotStore: store, refreshService: MockRefreshService(snapshot: nil))

        // Fail twice
        await appState.refreshNow(trigger: .manual)
        await appState.refreshNow(trigger: .manual)
        XCTAssertEqual(appState.failureCount, 2)
        XCTAssertEqual(appState.backoffInterval, 600)

        // Succeed
        let refreshed = QuotaSnapshot(
            weeklyQuotaPercent: 80, fiveHourQuotaPercent: 70, refreshedAt: .now,
            dataSource: .real
        )
        let successState = AppState(snapshotStore: store, refreshService: MockRefreshService(snapshot: refreshed))
        await successState.refreshNow(trigger: .manual)

        XCTAssertEqual(successState.status, .success)
        XCTAssertEqual(successState.failureCount, 0)
        XCTAssertEqual(successState.backoffInterval, 300)
    }

    func testConcurrentRefreshNowCallsJoinTheSameCoalescedStorm() async {
        let defaults = UserDefaults(suiteName: "CodexMonitorNativeTests.concurrentSingleFlight.\(UUID().uuidString)")!
        let store = SnapshotStore(defaults: defaults, key: "snapshot")
        let initial = QuotaSnapshot(
            weeklyQuotaPercent: 72, fiveHourQuotaPercent: 69, refreshedAt: .distantPast,
            dataSource: .real
        )
        store.saveSnapshot(initial)

        let firstSnapshot = QuotaSnapshot(
            weeklyQuotaPercent: 81, fiveHourQuotaPercent: 74, refreshedAt: Date.now,
            dataSource: .real
        )
        let latestSnapshot = QuotaSnapshot(
            weeklyQuotaPercent: 91, fiveHourQuotaPercent: 84, refreshedAt: Date.now.addingTimeInterval(1),
            dataSource: .real
        )
        let service = QueueingResultRefreshService(results: [.success(firstSnapshot), .success(latestSnapshot)])
        let appState = AppState(snapshotStore: store, refreshService: service)

        let first = Task { await appState.refreshNow(trigger: .manual) }
        await service.waitForCall(1)
        let second = Task { await appState.refreshNow(trigger: .scheduled) }

        await assertCallCount(1, for: service)
        await service.release(call: 1)
        await service.waitForCall(2)
        XCTAssertEqual(appState.status, .refreshing)
        await service.release(call: 2)
        await first.value
        await second.value

        await assertCallCount(2, for: service)
        await assertMaxConcurrentCalls(1, for: service)
        XCTAssertEqual(appState.snapshot, latestSnapshot)
        XCTAssertEqual(store.loadState()?.snapshot, latestSnapshot)
    }

    func testActiveSuccessDoesNotCommitBeforeTrailingFailureSettles() async {
        let defaults = UserDefaults(suiteName: "CodexMonitorNativeTests.activeSuccessTrailingFailure.\(UUID().uuidString)")!
        let store = SnapshotStore(defaults: defaults, key: "snapshot")
        let initial = QuotaSnapshot(
            weeklyQuotaPercent: 70,
            fiveHourQuotaPercent: 60,
            refreshedAt: Date.now,
            dataSource: .real
        )
        store.saveSnapshot(initial)
        let olderSuccess = QuotaSnapshot(
            weeklyQuotaPercent: 80,
            fiveHourQuotaPercent: 70,
            refreshedAt: Date.now.addingTimeInterval(1),
            dataSource: .real
        )
        let service = QueueingResultRefreshService(results: [
            .success(olderSuccess),
            .failure(MockRefreshError.simulatedFailure)
        ])
        let appState = AppState(snapshotStore: store, refreshService: service)

        let refreshNowTask = Task { await appState.refreshNow(trigger: .manual) }
        await service.waitForCall(1)
        appState.refresh(trigger: .wake)
        await assertCallCount(1, for: service)

        await service.release(call: 1)
        await service.waitForCall(2)
        XCTAssertEqual(appState.snapshot, initial)
        XCTAssertEqual(appState.status, .refreshing)
        XCTAssertEqual(appState.failureCount, 0)
        XCTAssertEqual(store.loadState()?.snapshot, initial)
        XCTAssertEqual(store.loadState()?.status, .refreshing)

        await service.release(call: 2)
        await refreshNowTask.value

        XCTAssertEqual(appState.snapshot, initial)
        XCTAssertEqual(appState.status, .networkFailed)
        XCTAssertEqual(appState.failureCount, 1)
        XCTAssertEqual(appState.backoffInterval, 300)
        XCTAssertEqual(store.loadState()?.snapshot, initial)
        XCTAssertEqual(store.loadState()?.status, .networkFailed)
        await assertMaxConcurrentCalls(1, for: service)
    }

    func testActiveFailureDoesNotCommitBeforeTrailingSuccessSettles() async {
        let defaults = UserDefaults(suiteName: "CodexMonitorNativeTests.activeFailureTrailingSuccess.\(UUID().uuidString)")!
        let store = SnapshotStore(defaults: defaults, key: "snapshot")
        let initial = QuotaSnapshot(
            weeklyQuotaPercent: 70,
            fiveHourQuotaPercent: 60,
            refreshedAt: Date.now,
            dataSource: .real
        )
        store.saveSnapshot(initial)
        let latestSuccess = QuotaSnapshot(
            weeklyQuotaPercent: 90,
            fiveHourQuotaPercent: 80,
            refreshedAt: Date.now.addingTimeInterval(1),
            dataSource: .real
        )
        let service = QueueingResultRefreshService(results: [
            .failure(MockRefreshError.simulatedFailure),
            .success(latestSuccess)
        ])
        let appState = AppState(snapshotStore: store, refreshService: service)

        let refreshNowTask = Task { await appState.refreshNow(trigger: .manual) }
        await service.waitForCall(1)
        appState.refresh(trigger: .scheduled)
        await assertCallCount(1, for: service)

        await service.release(call: 1)
        await service.waitForCall(2)
        XCTAssertEqual(appState.snapshot, initial)
        XCTAssertEqual(appState.status, .refreshing)
        XCTAssertEqual(appState.failureCount, 0)
        XCTAssertEqual(store.loadState()?.snapshot, initial)
        XCTAssertEqual(store.loadState()?.status, .refreshing)

        await service.release(call: 2)
        await refreshNowTask.value

        XCTAssertEqual(appState.snapshot, latestSuccess)
        XCTAssertEqual(appState.status, .success)
        XCTAssertEqual(appState.failureCount, 0)
        XCTAssertEqual(appState.backoffInterval, 300)
        XCTAssertEqual(store.loadState()?.snapshot, latestSuccess)
        XCTAssertEqual(store.loadState()?.status, .success)
        await assertMaxConcurrentCalls(1, for: service)
    }

    func testPersistenceAndWidgetPublishOnlyFinalSettledResultFromStorm() async {
        let defaults = UserDefaults(suiteName: "CodexMonitorNativeTests.widgetSingleFlight.\(UUID().uuidString)")!
        let store = SnapshotStore(defaults: defaults, key: "snapshot")
        let initial = QuotaSnapshot(
            weeklyQuotaPercent: 70,
            fiveHourQuotaPercent: 60,
            refreshedAt: Date.now,
            dataSource: .real
        )
        store.saveSnapshot(initial)
        let olderSuccess = QuotaSnapshot(
            weeklyQuotaPercent: 80,
            fiveHourQuotaPercent: 70,
            refreshedAt: Date.now,
            dataSource: .real
        )
        let latestSuccess = QuotaSnapshot(
            weeklyQuotaPercent: 90,
            fiveHourQuotaPercent: 80,
            refreshedAt: Date.now.addingTimeInterval(1),
            dataSource: .real
        )
        let service = QueueingResultRefreshService(results: [
            .success(olderSuccess),
            .success(latestSuccess)
        ])
        let appState = AppState(snapshotStore: store, refreshService: service)
        var savedStates: [WidgetDisplayState] = []
        var reloadCount = 0
        let bridge = WidgetTimelineBridge(
            appState: appState,
            saveState: { savedStates.append($0) },
            reloadTimelines: { reloadCount += 1 }
        )
        savedStates.removeAll()
        reloadCount = 0

        let refreshNowTask = Task { await appState.refreshNow(trigger: .manual) }
        await service.waitForCall(1)
        appState.refresh(trigger: .wake)
        await assertCallCount(1, for: service)

        await service.release(call: 1)
        await service.waitForCall(2)

        XCTAssertEqual(store.loadState()?.snapshot, initial)
        XCTAssertEqual(store.loadState()?.status, .refreshing)
        XCTAssertFalse(savedStates.contains { $0.snapshot == olderSuccess && $0.status == .success })
        XCTAssertEqual(reloadCount, 0)

        await service.release(call: 2)
        await refreshNowTask.value
        await Task.yield()

        XCTAssertEqual(store.loadState()?.snapshot, latestSuccess)
        XCTAssertEqual(store.loadState()?.status, .success)
        XCTAssertEqual(savedStates.last?.snapshot, latestSuccess)
        XCTAssertEqual(savedStates.last?.status, .success)
        XCTAssertEqual(reloadCount, 1)
        XCTAssertFalse(savedStates.contains { $0.snapshot == olderSuccess && $0.status == .success })
        XCTAssertEqual(savedStates.filter { $0.status != .refreshing }.map(\.snapshot), [latestSuccess])
        await assertMaxConcurrentCalls(1, for: service)
        _ = bridge
    }

    func testSuccessNotifiesSchedulerWhenBackoffResetsToDefault() async {
        let defaults = UserDefaults(suiteName: "CodexMonitorNativeTests.backoffResetNotify.\(UUID().uuidString)")!
        let store = SnapshotStore(defaults: defaults, key: "snapshot")
        let initial = QuotaSnapshot(
            weeklyQuotaPercent: 72, fiveHourQuotaPercent: 69, refreshedAt: .distantPast,
            dataSource: .real
        )
        store.saveSnapshot(initial)

        let refreshed = QuotaSnapshot(
            weeklyQuotaPercent: 81, fiveHourQuotaPercent: 74, refreshedAt: .now,
            dataSource: .real
        )
        let service = SequenceRefreshService(results: [
            .failure(MockRefreshError.simulatedFailure),
            .failure(MockRefreshError.simulatedFailure),
            .success(refreshed)
        ])
        let appState = AppState(snapshotStore: store, refreshService: service)
        var intervals: [TimeInterval] = []
        appState.onBackoffChanged = { intervals.append($0) }

        await appState.refreshNow(trigger: .manual)
        await appState.refreshNow(trigger: .manual)
        await appState.refreshNow(trigger: .manual)

        XCTAssertEqual(intervals, [600, 300])
        XCTAssertEqual(appState.backoffInterval, 300)
    }
}

private struct MockRefreshService: QuotaRefreshing {
    let snapshot: QuotaSnapshot?
    let error: Error?

    init(snapshot: QuotaSnapshot? = nil, error: Error? = nil) {
        self.snapshot = snapshot
        self.error = error
    }

    func refresh(basedOn currentSnapshot: QuotaSnapshot) async throws -> QuotaSnapshot {
        if let error {
            throw error
        }
        guard let snapshot else {
            throw MockRefreshError.simulatedFailure
        }
        return snapshot
    }
}

private actor BlockingRefreshService: QuotaRefreshing {
    let snapshot: QuotaSnapshot
    private var continuation: CheckedContinuation<Void, Never>?
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var callCountValue = 0

    init(snapshot: QuotaSnapshot) {
        self.snapshot = snapshot
    }

    func refresh(basedOn currentSnapshot: QuotaSnapshot) async throws -> QuotaSnapshot {
        callCountValue += 1
        startContinuation?.resume()
        startContinuation = nil
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
        return snapshot
    }

    func callCount() -> Int {
        callCountValue
    }

    func waitForStart() async {
        if callCountValue > 0 { return }
        await withCheckedContinuation { startContinuation = $0 }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private actor AppStateTemporalSleepGate {
    private var sleeper: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?

    func wait() async {
        started?.resume()
        started = nil
        await withCheckedContinuation { sleeper = $0 }
    }

    func waitUntilSleeping() async {
        if sleeper != nil { return }
        await withCheckedContinuation { started = $0 }
    }

    func release() {
        sleeper?.resume()
        sleeper = nil
    }
}

private actor AppStateTemporalSequenceSleep {
    private var delays: [UInt64] = []
    private var continuations: [Int: CheckedContinuation<Void, Never>] = [:]
    private var callWaiters: [Int: CheckedContinuation<Void, Never>] = [:]

    func wait(nanoseconds: UInt64) async {
        delays.append(nanoseconds)
        let call = delays.count
        callWaiters.removeValue(forKey: call)?.resume()
        await withCheckedContinuation { continuations[call] = $0 }
    }

    func waitForCall(_ call: Int) async {
        if delays.count >= call { return }
        await withCheckedContinuation { callWaiters[call] = $0 }
    }

    func delay(forCall call: Int) -> UInt64? {
        guard delays.indices.contains(call - 1) else { return nil }
        return delays[call - 1]
    }

    func release(call: Int) {
        continuations.removeValue(forKey: call)?.resume()
    }
}

private actor RefreshCompletionProbe {
    private var completed = false

    func markCompleted() {
        completed = true
    }

    func isCompleted() -> Bool {
        completed
    }
}

private actor QueueingResultRefreshService: QuotaRefreshing {
    private let results: [Result<QuotaSnapshot, Error>]
    private var continuations: [Int: CheckedContinuation<Void, Never>] = [:]
    private var pendingReleases: Set<Int> = []
    private var callCountValue = 0
    private var activeCallCount = 0
    private var maxConcurrentCallCount = 0
    private var completedCallCount = 0
    private var waiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private var completionWaiters: [Int: CheckedContinuation<Void, Never>] = [:]

    init(results: [Result<QuotaSnapshot, Error>]) {
        self.results = results
    }

    func refresh(basedOn _: QuotaSnapshot) async throws -> QuotaSnapshot {
        callCountValue += 1
        let call = callCountValue
        activeCallCount += 1
        maxConcurrentCallCount = max(maxConcurrentCallCount, activeCallCount)
        defer {
            activeCallCount -= 1
            completedCallCount += 1
            completionWaiters.removeValue(forKey: completedCallCount)?.resume()
        }
        waiters.removeValue(forKey: call)?.resume()
        await withCheckedContinuation { continuation in
            if pendingReleases.remove(call) != nil {
                continuation.resume()
            } else {
                continuations[call] = continuation
            }
        }
        return try results[call - 1].get()
    }

    func waitForCall(_ count: Int) async {
        if callCountValue >= count { return }
        await withCheckedContinuation { waiters[count] = $0 }
    }

    func waitForCompletion(_ count: Int) async {
        if completedCallCount >= count { return }
        await withCheckedContinuation { completionWaiters[count] = $0 }
    }

    func callCount() -> Int {
        callCountValue
    }

    func maxConcurrentCalls() -> Int {
        maxConcurrentCallCount
    }

    func release(call: Int) {
        if let continuation = continuations.removeValue(forKey: call) {
            continuation.resume()
        } else {
            pendingReleases.insert(call)
        }
    }
}

private actor SequenceRefreshService: QuotaRefreshing {
    private var results: [Result<QuotaSnapshot, Error>]

    init(results: [Result<QuotaSnapshot, Error>]) {
        self.results = results
    }

    func refresh(basedOn currentSnapshot: QuotaSnapshot) async throws -> QuotaSnapshot {
        guard !results.isEmpty else {
            throw MockRefreshError.simulatedFailure
        }

        let result = results.removeFirst()
        return try result.get()
    }
}
