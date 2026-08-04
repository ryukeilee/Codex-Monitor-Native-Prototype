import Foundation
import XCTest
@testable import CodexMonitorNative

@MainActor
final class RefreshConsistencyRegressionTests: XCTestCase {
    func testPersistFailureDoesNotPublishUnpersistedRefreshAndRecoversAfterStorageReturns() async throws {
        let suiteName = "CodexMonitorNativeTests.persistenceFailure.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SnapshotStore(defaults: defaults, key: "snapshot")
        let persistedState = PersistedAppState(
            snapshot: QuotaSnapshot.notConnected,
            status: .noSnapshot,
            lastSuccessAt: nil,
            lastAttemptAt: nil,
            failureCount: 0
        )
        let currentEnvelope = try PersistenceEnvelope(value: persistedState, revision: 1)
        var futureObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(currentEnvelope)) as? [String: Any]
        )
        futureObject["formatVersion"] = PersistenceEnvelope.currentFormatVersion + 1
        defaults.set(try JSONSerialization.data(withJSONObject: futureObject), forKey: "snapshot")

        let refreshed = makeSnapshot(weekly: 88, fiveHour: 77, refreshedAt: .now)
        let service = ConsistencySequenceRefreshService(results: [.success(refreshed), .success(refreshed)])
        let appState = AppState(
            snapshotStore: store,
            refreshService: service,
            accountBoundaryProvider: { .testDefault }
        )

        await appState.refreshNow(trigger: .manual)

        XCTAssertEqual(appState.snapshot, .notConnected)
        XCTAssertEqual(appState.stateEvent.persistedState.snapshot, .notConnected)
        XCTAssertEqual(appState.stateEvent.persistedState.status, .noSnapshot)
        XCTAssertNil(store.loadState())

        defaults.removeObject(forKey: "snapshot")
        await appState.refreshNow(trigger: .manual)

        XCTAssertEqual(appState.snapshot, refreshed)
        XCTAssertEqual(store.loadState()?.snapshot, refreshed)
        XCTAssertEqual(store.loadState(), appState.stateEvent.persistedState)
    }

    func testStagedSuccessSurvivesTrailingRefreshingCommitFailure() async throws {
        let suiteName = "CodexMonitorNativeTests.stagedCommitFailure.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SnapshotStore(defaults: defaults, key: "snapshot")
        let initial = makeSnapshot(weekly: 70, fiveHour: 60, refreshedAt: Date(timeIntervalSince1970: 100))
        store.saveSnapshot(initial)
        let activeSuccess = makeSnapshot(weekly: 84, fiveHour: 73, refreshedAt: Date(timeIntervalSince1970: 101))
        let service = ConsistencyQueueingRefreshService(results: [
            .success(activeSuccess),
            .failure(MockRefreshError.simulatedFailure)
        ])
        let appState = AppState(
            snapshotStore: store,
            refreshService: service,
            accountBoundaryProvider: { .testDefault }
        )

        let refreshTask = Task { await appState.refreshNow(trigger: .manual) }
        await service.waitForCall(1)
        appState.refresh(trigger: .wake)

        var futureObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(defaults.data(forKey: "snapshot"))) as? [String: Any]
        )
        futureObject["formatVersion"] = PersistenceEnvelope.currentFormatVersion + 1
        defaults.set(try JSONSerialization.data(withJSONObject: futureObject), forKey: "snapshot")

        await service.release(call: 1)
        await service.waitForCall(2)
        defaults.removeObject(forKey: "snapshot")
        await service.release(call: 2)
        await refreshTask.value

        XCTAssertEqual(appState.snapshot, activeSuccess)
        XCTAssertEqual(appState.status, .networkFailed)
        XCTAssertEqual(store.loadState()?.snapshot, activeSuccess)
    }

    func testActiveSuccessRemainsTrustedWhenCoalescedTrailingRefreshFails() async {
        let suiteName = "CodexMonitorNativeTests.trailingFailureRecovery.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SnapshotStore(defaults: defaults, key: "snapshot")
        let initial = makeSnapshot(weekly: 70, fiveHour: 60, refreshedAt: Date(timeIntervalSince1970: 100))
        store.saveSnapshot(initial)
        let activeSuccess = makeSnapshot(weekly: 84, fiveHour: 73, refreshedAt: Date(timeIntervalSince1970: 101))
        let service = ConsistencyQueueingRefreshService(results: [
            .success(activeSuccess),
            .failure(MockRefreshError.simulatedFailure)
        ])
        let appState = AppState(
            snapshotStore: store,
            refreshService: service,
            accountBoundaryProvider: { .testDefault }
        )

        let refreshTask = Task { await appState.refreshNow(trigger: .manual) }
        await service.waitForCall(1)
        appState.refresh(trigger: .wake)
        await service.release(call: 1)
        await service.waitForCall(2)
        await service.release(call: 2)
        await refreshTask.value

        XCTAssertEqual(appState.snapshot, activeSuccess)
        XCTAssertEqual(appState.status, .networkFailed)
        XCTAssertEqual(store.loadState()?.snapshot, activeSuccess)
        XCTAssertEqual(store.loadState()?.status, .networkFailed)
    }

    func testStartupCleanupPreservesWidgetBackupForRecovery() throws {
        let groupURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexMonitorNativeTests.widgetCleanupRecovery.\(UUID().uuidString)", isDirectory: true)
        let fileManager = ConsistencyWidgetFileManager(groupURL: groupURL)
        defer { try? FileManager.default.removeItem(at: groupURL) }
        let now = Date(timeIntervalSince1970: 400)
        let state = WidgetDisplayState.make(
            snapshot: makeSnapshot(weekly: 79, fiveHour: 68, refreshedAt: now),
            status: .success,
            lastSuccessAt: now,
            lastAttemptAt: nil,
            effectiveFiveHourResetAt: nil,
            savedAt: now
        )
        XCTAssertTrue(WidgetDisplayStateStore.save(state, fileManager: fileManager))
        XCTAssertTrue(WidgetDisplayStateStore.save(state, fileManager: fileManager))
        let stateURL = WidgetDisplayStateStore.stateURL(fileManager: fileManager)
        try Data("truncated".utf8).write(to: stateURL, options: .atomic)

        WidgetDisplayStateStore.cleanCache(fileManager: fileManager)

        XCTAssertTrue(FileManager.default.fileExists(atPath: stateURL.appendingPathExtension("backup").path))
        XCTAssertEqual(WidgetDisplayStateStore.load(fileManager: fileManager), state)
    }

    func testClockRollbackRefreshAcceptsNewSnapshotAcrossAllConsumers() async throws {
        let suiteName = "CodexMonitorNativeTests.clockRollbackRefresh.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SnapshotStore(defaults: defaults, key: "snapshot")
        let initialDate = Date(timeIntervalSince1970: 1_000)
        var currentDate = initialDate
        let initial = makeSnapshot(weekly: 70, fiveHour: 60, refreshedAt: initialDate)
        store.saveSnapshot(initial)
        let refreshedDate = Date(timeIntervalSince1970: 500)
        let refreshed = makeSnapshot(weekly: 91, fiveHour: 82, refreshedAt: refreshedDate)
        let fileManager = ConsistencyWidgetFileManager(
            groupURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("CodexMonitorNativeTests.clockRollbackWidget.\(UUID().uuidString)", isDirectory: true)
        )
        defer { try? FileManager.default.removeItem(at: fileManager.groupURL) }
        let appState = AppState(
            snapshotStore: store,
            refreshService: ConsistencySequenceRefreshService(results: [.success(refreshed)]),
            staleAfterInterval: 60,
            now: { currentDate },
            accountBoundaryProvider: { .testDefault }
        )
        var widgetStates: [WidgetDisplayState] = []
        let bridge = WidgetTimelineBridge(
            appState: appState,
            saveState: { state in
                widgetStates.append(state)
                return WidgetDisplayStateStore.save(state, fileManager: fileManager)
            },
            reloadTimelines: {}
        )

        currentDate = refreshedDate
        appState.reconcileTemporalState()
        await appState.refreshNow(trigger: .systemClockChange)

        XCTAssertEqual(appState.snapshot, refreshed)
        XCTAssertEqual(store.loadState()?.snapshot, refreshed)
        XCTAssertEqual(WidgetDisplayStateStore.load(fileManager: fileManager).snapshot, refreshed)
        XCTAssertEqual(WidgetDisplayStateStore.load(fileManager: fileManager), appState.presentationSnapshot)
        XCTAssertEqual(widgetStates.last?.snapshot, refreshed)
        let widgetData = try Data(contentsOf: WidgetDisplayStateStore.stateURL(fileManager: fileManager))
        let widgetObject = try XCTUnwrap(JSONSerialization.jsonObject(with: widgetData) as? [String: Any])
        XCTAssertNil(widgetObject["allowsOlderRealSnapshot"])

        appState.shutdown()
        let restarted = AppState(
            snapshotStore: store,
            refreshService: ConsistencySequenceRefreshService(results: []),
            staleAfterInterval: 60,
            now: { currentDate },
            accountBoundaryProvider: { .testDefault }
        )
        XCTAssertEqual(restarted.snapshot, refreshed)
        XCTAssertEqual(restarted.stateEvent.persistedState.snapshot, refreshed)
        restarted.shutdown()
        _ = bridge
    }

    func testCoalescedClockRollbackRefreshCarriesRollbackAllowanceToTrailingRequest() async {
        let suiteName = "CodexMonitorNativeTests.coalescedClockRollback.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SnapshotStore(defaults: defaults, key: "snapshot")
        let initialDate = Date(timeIntervalSince1970: 1_000)
        var currentDate = initialDate
        let initial = makeSnapshot(weekly: 70, fiveHour: 60, refreshedAt: initialDate)
        store.saveSnapshot(initial)
        let refreshed = makeSnapshot(weekly: 92, fiveHour: 83, refreshedAt: Date(timeIntervalSince1970: 500))
        let fileManager = ConsistencyWidgetFileManager(
            groupURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("CodexMonitorNativeTests.coalescedClockRollbackWidget.\(UUID().uuidString)", isDirectory: true)
        )
        defer { try? FileManager.default.removeItem(at: fileManager.groupURL) }
        let service = ConsistencyQueueingRefreshService(results: [
            .success(refreshed),
            .failure(MockRefreshError.simulatedFailure)
        ])
        let appState = AppState(
            snapshotStore: store,
            refreshService: service,
            staleAfterInterval: 60,
            now: { currentDate },
            accountBoundaryProvider: { .testDefault }
        )
        let bridge = WidgetTimelineBridge(
            appState: appState,
            saveState: { WidgetDisplayStateStore.save($0, fileManager: fileManager) },
            reloadTimelines: {}
        )

        currentDate = Date(timeIntervalSince1970: 500)
        appState.reconcileTemporalState()
        let refreshTask = Task { await appState.refreshNow(trigger: .systemClockChange) }
        await service.waitForCall(1)
        appState.refresh(trigger: .wake)
        await service.release(call: 1)
        await service.waitForCall(2)
        await service.release(call: 2)
        await refreshTask.value

        XCTAssertEqual(appState.snapshot, refreshed)
        XCTAssertEqual(appState.status, .networkFailed)
        XCTAssertEqual(store.loadState()?.snapshot, refreshed)
        XCTAssertEqual(WidgetDisplayStateStore.load(fileManager: fileManager).snapshot, refreshed)
        appState.shutdown()
        _ = bridge
    }

    func testSchedulerReplaysRecoveryTriggerCoalescedDuringFailedRefresh() async {
        let base = Date(timeIntervalSince1970: 5_000)
        let clock = ConsistencyManualRefreshSchedulerClock(now: base)
        let gate = ConsistencyRefreshGate()
        let scheduler = RefreshScheduler(clock: clock) { trigger in
            await gate.perform(trigger)
        }
        let snapshot = makeSnapshot(refreshedAt: base)

        scheduler.start()
        scheduler.updateSchedule(with: RefreshSchedulingState(
            snapshot: snapshot,
            status: .success,
            lastSuccessAt: base,
            lastAttemptAt: nil,
            failureCount: 0,
            backoffInterval: 300
        ))
        scheduler.requestRefresh(.scheduled)
        await gate.waitForCall(1)

        scheduler.updateSchedule(with: RefreshSchedulingState(
            snapshot: snapshot,
            status: .networkFailed,
            lastSuccessAt: base,
            lastAttemptAt: base,
            failureCount: 1,
            backoffInterval: 300
        ))
        scheduler.requestRefresh(.manual)
        gate.releaseNext()
        await gate.waitForCompletion(1)

        for _ in 0..<100 {
            if gate.callCount() >= 2 { break }
            await Task.yield()
        }
        let triggers = gate.triggers()
        XCTAssertEqual(triggers, [.scheduled, .manual])

        if gate.callCount() >= 2 {
            gate.releaseNext()
            await gate.waitForCompletion(2)
        }
        scheduler.stop()
    }

    func testPausedSchedulerDefersBypassRetryUntilResume() async {
        let base = Date(timeIntervalSince1970: 5_000)
        let clock = ConsistencyManualRefreshSchedulerClock(now: base)
        let gate = ConsistencyRefreshGate()
        let scheduler = RefreshScheduler(clock: clock) { trigger in
            await gate.perform(trigger)
        }
        let snapshot = makeSnapshot(refreshedAt: base)

        scheduler.start()
        scheduler.updateSchedule(with: RefreshSchedulingState(
            snapshot: snapshot,
            status: .success,
            lastSuccessAt: base,
            lastAttemptAt: nil,
            failureCount: 0,
            backoffInterval: 300
        ))
        scheduler.requestRefresh(.scheduled)
        await gate.waitForCall(1)

        // The active refresh fails and a bypass trigger (manual) is coalesced
        // into it, then the scheduler pauses while the refresh is in flight.
        scheduler.updateSchedule(with: RefreshSchedulingState(
            snapshot: snapshot,
            status: .networkFailed,
            lastSuccessAt: base,
            lastAttemptAt: base,
            failureCount: 1,
            backoffInterval: 300
        ))
        scheduler.requestRefresh(.manual)
        scheduler.pause(for: .networkUnavailable)

        gate.releaseNext()
        await gate.waitForCompletion(1)
        for _ in 0..<100 {
            if gate.callCount() > 1 { break }
            await Task.yield()
        }
        XCTAssertEqual(
            gate.callCount(), 1,
            "paused scheduler must not immediately retry a coalesced bypass trigger"
        )

        // Resuming recreates the cadence deadline; it must not fire the retry
        // before that deadline.
        scheduler.resume(for: .networkUnavailable)
        for _ in 0..<100 {
            if gate.callCount() > 1 { break }
            await Task.yield()
        }
        XCTAssertEqual(
            gate.callCount(), 1,
            "resume must not fire the deferred retry before its deadline"
        )

        // Past the failure-backoff deadline the pending bypass intent fires.
        clock.advance(to: base.addingTimeInterval(300))
        await gate.waitForCall(2)
        XCTAssertEqual(gate.triggers(), [.scheduled, .manual])

        gate.releaseNext()
        await gate.waitForCompletion(2)
        scheduler.stop()
    }

    func testStopResetsCoalescedTriggerCount() async {
        let base = Date(timeIntervalSince1970: 6_500)
        let clock = ConsistencyManualRefreshSchedulerClock(now: base)
        let gate = ConsistencyRefreshGate()
        let scheduler = RefreshScheduler(clock: clock) { trigger in
            await gate.perform(trigger)
        }
        let snapshot = makeSnapshot(refreshedAt: base)

        scheduler.start()
        scheduler.updateSchedule(with: RefreshSchedulingState(
            snapshot: snapshot,
            status: .success,
            lastSuccessAt: base,
            lastAttemptAt: nil,
            failureCount: 0,
            backoffInterval: 300
        ))
        scheduler.requestRefresh(.scheduled)
        await gate.waitForCall(1)

        scheduler.requestRefresh(.wake)
        scheduler.requestRefresh(.networkRestored)
        XCTAssertEqual(scheduler.coalescedTriggerCount, 2)

        scheduler.stop()
        XCTAssertEqual(scheduler.coalescedTriggerCount, 0)

        gate.releaseNext()
        await gate.waitForCompletion(1)
    }

    func testFailedAutomaticTrailingTriggerRetriesAfterBackoffDeadline() async {
        let base = Date(timeIntervalSince1970: 8_000)
        let clock = ConsistencyManualRefreshSchedulerClock(now: base)
        let gate = ConsistencyRefreshGate()
        let scheduler = RefreshScheduler(clock: clock) { trigger in
            await gate.perform(trigger)
        }
        let snapshot = makeSnapshot(refreshedAt: base)

        scheduler.start()
        scheduler.updateSchedule(with: RefreshSchedulingState(
            snapshot: snapshot,
            status: .success,
            lastSuccessAt: base,
            lastAttemptAt: nil,
            failureCount: 0,
            backoffInterval: 300
        ))
        scheduler.requestRefresh(.scheduled)
        await gate.waitForCall(1)

        // The active refresh fails and an automatic (non-bypass) trigger is
        // coalesced into it: the retry must wait for the failure backoff
        // deadline instead of firing immediately.
        scheduler.updateSchedule(with: RefreshSchedulingState(
            snapshot: snapshot,
            status: .networkFailed,
            lastSuccessAt: base,
            lastAttemptAt: base,
            failureCount: 1,
            backoffInterval: 300
        ))
        scheduler.requestRefresh(.networkChanged)
        gate.releaseNext()
        await gate.waitForCompletion(1)
        for _ in 0..<100 {
            if gate.callCount() > 1 { break }
            await Task.yield()
        }
        XCTAssertEqual(
            gate.callCount(), 1,
            "non-bypass trailing trigger must not retry before the backoff deadline"
        )

        clock.advance(to: base.addingTimeInterval(300))
        await gate.waitForCall(2)
        XCTAssertEqual(gate.triggers(), [.scheduled, .networkChanged])

        gate.releaseNext()
        await gate.waitForCompletion(2)
        scheduler.stop()
    }

    func testRefreshTriggerPriorityPreservesManualIntentOverScheduledWork() {
        XCTAssertGreaterThan(
            AppState.RefreshTrigger.manual.coalescingPriority,
            AppState.RefreshTrigger.scheduled.coalescingPriority
        )
    }

    func testSchedulerDoesNotCompareSuccessfulSnapshotAcrossStoppedRuns() async {
        let base = Date(timeIntervalSince1970: 6_000)
        let clock = ConsistencyManualRefreshSchedulerClock(now: base)
        let scheduler = RefreshScheduler(clock: clock) { _ in }
        let first = makeSnapshot(weekly: 90, fiveHour: 85, refreshedAt: base)
        let second = makeSnapshot(weekly: 20, fiveHour: 15, refreshedAt: base.addingTimeInterval(1))

        scheduler.start()
        scheduler.updateSchedule(with: RefreshSchedulingState(
            snapshot: first,
            status: .success,
            lastSuccessAt: base,
            lastAttemptAt: nil,
            failureCount: 0,
            backoffInterval: 300
        ))
        scheduler.stop()
        scheduler.start()
        scheduler.updateSchedule(with: RefreshSchedulingState(
            snapshot: second,
            status: .success,
            lastSuccessAt: second.refreshedAt,
            lastAttemptAt: nil,
            failureCount: 0,
            backoffInterval: 300
        ))

        XCTAssertEqual(scheduler.nextReason, .stable)
        XCTAssertEqual(scheduler.nextFireAt, base.addingTimeInterval(AdaptiveRefreshCadencePolicy.stableInterval))
        scheduler.stop()
    }

    func testEmptyRealRefreshConvergesAcrossPersistenceAndWidgetPresentation() async {
        let suiteName = "CodexMonitorNativeTests.emptyRefresh.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SnapshotStore(defaults: defaults, key: "snapshot")
        let empty = QuotaSnapshot(
            weeklyQuotaPercent: 0,
            fiveHourQuotaPercent: 0,
            weeklyQuotaState: .unavailable,
            fiveHourQuotaState: .unavailable,
            refreshedAt: Date(timeIntervalSince1970: 300),
            dataSource: .real,
            quotaWindows: [],
            accountBoundary: .testDefault
        )
        let appState = AppState(
            snapshotStore: store,
            refreshService: ConsistencySequenceRefreshService(results: [.success(empty)]),
            accountBoundaryProvider: { .testDefault }
        )
        var widgetStates: [WidgetDisplayState] = []
        let bridge = WidgetTimelineBridge(
            appState: appState,
            saveState: { widgetStates.append($0); return true },
            reloadTimelines: {}
        )

        await appState.refreshNow(trigger: .manual)

        XCTAssertEqual(store.loadState(), appState.stateEvent.persistedState)
        XCTAssertEqual(widgetStates.last, appState.presentationSnapshot)
        XCTAssertTrue(StatusPopoverFormatting.quotaWindowDisplayItems(
            snapshot: empty,
            status: appState.presentationSnapshot.status
        ).isEmpty)
        _ = bridge
    }

    private func makeSnapshot(
        weekly: Int = 70,
        fiveHour: Int = 60,
        refreshedAt: Date,
        dataSource: QuotaDataSource = .real
    ) -> QuotaSnapshot {
        QuotaSnapshot(
            weeklyQuotaPercent: weekly,
            fiveHourQuotaPercent: fiveHour,
            refreshedAt: refreshedAt,
            dataSource: dataSource,
            accountBoundary: dataSource == .real ? .testDefault : nil
        )
    }
}

private actor ConsistencySequenceRefreshService: QuotaRefreshing {
    private var results: [Result<QuotaSnapshot, Error>]

    init(results: [Result<QuotaSnapshot, Error>]) {
        self.results = results
    }

    func refresh(basedOn _: QuotaSnapshot) async throws -> QuotaSnapshot {
        guard !results.isEmpty else { throw MockRefreshError.simulatedFailure }
        return try results.removeFirst().get()
    }
}

private actor ConsistencyQueueingRefreshService: QuotaRefreshing {
    private let results: [Result<QuotaSnapshot, Error>]
    private var callCountValue = 0
    private var continuations: [Int: CheckedContinuation<Void, Never>] = [:]
    private var pendingReleases: Set<Int> = []
    private var callWaiters: [Int: CheckedContinuation<Void, Never>] = [:]

    init(results: [Result<QuotaSnapshot, Error>]) {
        self.results = results
    }

    func refresh(basedOn _: QuotaSnapshot) async throws -> QuotaSnapshot {
        callCountValue += 1
        let call = callCountValue
        callWaiters.removeValue(forKey: call)?.resume()
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
        await withCheckedContinuation { callWaiters[count] = $0 }
    }

    func release(call: Int) {
        if let continuation = continuations.removeValue(forKey: call) {
            continuation.resume()
        } else {
            pendingReleases.insert(call)
        }
    }
}

private final class ConsistencyWidgetFileManager: FileManager {
    let groupURL: URL

    init(groupURL: URL) {
        self.groupURL = groupURL
        super.init()
    }

    override func containerURL(forSecurityApplicationGroupIdentifier groupIdentifier: String) -> URL? {
        groupURL
    }
}

@MainActor
private final class ConsistencyManualRefreshSchedulerClock: RefreshSchedulerClock {
    private(set) var now: Date
    private var scheduledAction: (() -> Void)?
    private var scheduledAt: Date?

    var hasScheduledAction: Bool { scheduledAction != nil }

    init(now: Date) {
        self.now = now
    }

    func schedule(at date: Date, action: @escaping @MainActor () -> Void) {
        scheduledAction = action
        scheduledAt = date
    }

    func cancelScheduledAction() {
        scheduledAction = nil
        scheduledAt = nil
    }

    func advance(to date: Date) {
        now = date
        if let scheduledAt, let action = scheduledAction, date >= scheduledAt {
            cancelScheduledAction()
            action()
        }
    }
}

@MainActor
private final class ConsistencyRefreshGate {
    private var recordedTriggers: [AppState.RefreshTrigger] = []
    private var callWaiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private var completionWaiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var completedCount = 0

    func perform(_ trigger: AppState.RefreshTrigger) async {
        recordedTriggers.append(trigger)
        callWaiters.removeValue(forKey: recordedTriggers.count)?.resume()
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
        completedCount += 1
        completionWaiters.removeValue(forKey: completedCount)?.resume()
    }

    func waitForCall(_ count: Int) async {
        if recordedTriggers.count >= count { return }
        await withCheckedContinuation { callWaiters[count] = $0 }
    }

    func releaseNext() {
        guard !releaseWaiters.isEmpty else { return }
        releaseWaiters.removeFirst().resume()
    }

    func waitForCompletion(_ count: Int) async {
        if completedCount >= count { return }
        await withCheckedContinuation { completionWaiters[count] = $0 }
    }

    func callCount() -> Int { recordedTriggers.count }
    func triggers() -> [AppState.RefreshTrigger] { recordedTriggers }
}
