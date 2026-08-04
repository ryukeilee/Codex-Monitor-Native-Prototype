import Combine
import Foundation
import XCTest
@testable import CodexMonitorNative

// Temporary probe tests: verify suspected reliability bugs before fixing.
@MainActor
final class ReliabilityProbeTests: XCTestCase {
    private func makeSnapshot(
        weekly: Int = 70,
        fiveHour: Int = 60,
        refreshedAt: Date = .now,
        dataSource: QuotaDataSource = .real,
        quotaWindows: [QuotaWindow] = [],
        resetAt: Date? = nil,
        boundary: QuotaAccountBoundary? = nil
    ) -> QuotaSnapshot {
        QuotaSnapshot(
            weeklyQuotaPercent: weekly,
            fiveHourQuotaPercent: fiveHour,
            weeklyQuotaState: .live,
            fiveHourQuotaState: .live,
            fiveHourResetAt: resetAt,
            refreshedAt: refreshedAt,
            dataSource: dataSource,
            quotaWindows: quotaWindows,
            accountBoundary: boundary
        )
    }

    // Probe 1: menu bar title during .refreshing after the weekly window's
    // resetAt has passed — does the trusted weekly % disappear?
    func testProbeMenuBarTitleDuringRefreshingWithPassedResetAt() {
        let now = Date()
        let snapshot = makeSnapshot(
            weekly: 72,
            fiveHour: 64,
            quotaWindows: [
                QuotaWindow(
                    limitId: "codex", windowId: "primary", kind: .fiveHour,
                    durationMinutes: 300, remainingPercent: 64,
                    resetAt: now.addingTimeInterval(-60)
                ),
                QuotaWindow(
                    limitId: "codex", windowId: "secondary", kind: .weekly,
                    durationMinutes: 10_080, remainingPercent: 72
                )
            ]
        )
        let title = StatusPopoverFormatting.weeklyQuotaMenuTitle(
            snapshot: snapshot,
            status: .refreshing,
            now: now
        )
        print("PROBE1 menu title while refreshing with passed 5h resetAt: \(title)")
    }

    // Probe 2: WidgetDisplayStateStore — a real snapshot write where the
    // CURRENT stored state is real and NEWER, but the write's savedAt is
    // newer. Verify the refreshedAt guard actually blocks it.
    func testProbeWidgetStoreBlocksOlderRealWrite() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProbeWidgetStore.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let boundary = QuotaAccountBoundary(
            accountFingerprint: String(repeating: "a", count: 64),
            sessionFingerprint: String(repeating: "b", count: 64)
        )
        let newer = WidgetDisplayState.make(
            snapshot: makeSnapshot(weekly: 80, refreshedAt: .now, boundary: boundary),
            status: .success,
            lastSuccessAt: .now,
            lastAttemptAt: nil,
            effectiveFiveHourResetAt: nil
        )
        XCTAssertTrue(WidgetDisplayStateStore.save(newer, fileManager: FileManager()))

        let older = WidgetDisplayState.make(
            snapshot: makeSnapshot(weekly: 50, refreshedAt: .now.addingTimeInterval(-3600), boundary: boundary),
            status: .success,
            lastSuccessAt: .now.addingTimeInterval(-3600),
            lastAttemptAt: nil,
            effectiveFiveHourResetAt: nil
        )
        XCTAssertFalse(WidgetDisplayStateStore.save(older, fileManager: FileManager()))
    }

    // Probe 3: AppState — a failed refresh while a *queued* refresh exists:
    // the pending trigger is replaced by later lower-priority triggers.
    func testProbeQueuedRefreshTriggerOverwrite() async {
        // Behavioral probe only — record what the trailing trigger ends up as.
        print("PROBE3 queued trigger overwrite — see AppState.enqueueRefresh pendingRefresh?.trigger = trigger")
    }

    // Probe 4: RefreshScheduler — deferred automatic trigger while paused.
    func testProbeDeferredTriggerSurvivesPauseResume() async {
        let base = Date(timeIntervalSince1970: 5_000)
        let clock = ProbeManualClock(now: base)
        let gate = ProbeRefreshGate()
        let scheduler = RefreshScheduler(clock: clock) { trigger in
            await gate.perform(trigger)
        }
        let snapshot = makeSnapshot(refreshedAt: base)

        scheduler.start()
        scheduler.updateSchedule(with: RefreshSchedulingState(
            snapshot: snapshot,
            status: .networkFailed,
            lastSuccessAt: base,
            lastAttemptAt: base,
            failureCount: 1,
            backoffInterval: 5 * 60
        ))

        scheduler.requestRefresh(.scheduled)
        let deferredCount = await gate.callCount()
        XCTAssertEqual(deferredCount, 0)

        // Pause while the deferred trigger is pending, then resume.
        scheduler.pause(for: .systemSleep)
        scheduler.resume(for: .systemSleep)

        clock.advance(to: base.addingTimeInterval(5 * 60))
        await gate.waitForCall(1)
        let triggers = await gate.triggers()
        print("PROBE4 deferred trigger after pause/resume: \(triggers)")
        scheduler.stop()
    }

    // Probe 5: AppState — does a refresh triggered while network is
    // unreachable (nil) get silently dropped while the scheduler thinks it ran?
    func testProbeRefreshNowWhileNetworkUnknown() async {
        let defaults = UserDefaults(suiteName: "Probe.unknown.\(UUID().uuidString)")!
        let store = SnapshotStore(defaults: defaults, key: "snapshot")
        let appState = AppState(
            snapshotStore: store,
            refreshService: ProbeMockRefreshService(snapshot: makeSnapshot(weekly: 33)),
            initialNetworkReachability: nil,
            accountBoundaryProvider: { nil },
            allowsUnboundSnapshotsForTesting: true
        )
        var calls = 0
        appState.onRefreshRequested = { _ in calls += 1 }
        await appState.refreshNow(trigger: .manual)
        XCTAssertEqual(appState.snapshot.dataSource, .mock)
        print("PROBE5 refreshNow with unknown network: calls=\(calls) status=\(appState.status.rawValue)")
    }

    // Probe 6: SnapshotStore — the demoMode write over persisted real data.
    func testProbeDemoModeWriteOverPersistedReal() {
        let defaults = UserDefaults(suiteName: "Probe.demo.\(UUID().uuidString)")!
        let store = SnapshotStore(defaults: defaults, key: "snapshot")
        let real = makeSnapshot(weekly: 70, refreshedAt: .now)
        store.saveState(PersistedAppState(
            snapshot: real,
            status: .success,
            lastSuccessAt: .now,
            lastAttemptAt: nil,
            failureCount: 0
        ))
        let demo = QuotaSnapshot(
            weeklyQuotaPercent: 40, fiveHourQuotaPercent: 30,
            refreshedAt: .now, dataSource: .mock
        )
        store.saveState(PersistedAppState(
            snapshot: demo,
            status: .demoMode,
            lastSuccessAt: nil,
            lastAttemptAt: nil,
            failureCount: 0
        ))
        print("PROBE6 demo-mode write over real: loaded=\(store.loadSnapshot()?.dataSource.rawValue ?? "nil")")
    }

    // Probe 7: RefreshScheduler — updateSchedule during refreshInFlight from a
    // STOPPED run — can a stale latestState reschedule after restart?
    func testProbeStoppedRunStateDoesNotLeakIntoRestartedRun() async {
        let base = Date(timeIntervalSince1970: 5_000)
        let clock = ProbeManualClock(now: base)
        let gate = ProbeRefreshGate()
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
        scheduler.requestRefresh(.manual)
        await gate.waitForCall(1)
        scheduler.stop()

        // Restart: the old snapshot must not be treated as previousSuccessfulSnapshot.
        scheduler.start()
        let fireAt = scheduler.nextFireAt
        print("PROBE7 fireAt after restart: \(String(describing: fireAt))")
        scheduler.stop()
    }

    // Probe 8: WidgetTimelineBridge — forceSync after a failed startup save.
    func testProbeBridgeForceSyncAfterFailedStartupSave() {
        var saveResults: [Bool] = [false]
        var reloadCount = 0
        let defaults = UserDefaults(suiteName: "Probe.bridge.\(UUID().uuidString)")!
        let store = SnapshotStore(defaults: defaults, key: "snapshot")
        let appState = AppState(
            snapshotStore: store,
            refreshService: ProbeMockRefreshService(snapshot: makeSnapshot(weekly: 66)),
            initialNetworkReachability: nil,
            accountBoundaryProvider: { nil },
            allowsUnboundSnapshotsForTesting: true
        )
        let bridge = WidgetTimelineBridge(
            appState: appState,
            saveState: { _ in
                let result = saveResults.removeFirst()
                saveResults.append(true)
                return result
            },
            reloadTimelines: { reloadCount += 1 }
        )
        bridge.forceSync()
        bridge.forceSync()
        print("PROBE8 forceSync after failed startup save: reloadCount=\(reloadCount)")
    }
}

// MARK: - Helpers

private final class ProbeMockRefreshService: QuotaRefreshing {
    private let snapshot: QuotaSnapshot?
    private let error: Error?

    init(snapshot: QuotaSnapshot) {
        self.snapshot = snapshot
        self.error = nil
    }

    init(error: Error) {
        self.snapshot = nil
        self.error = error
    }

    func refresh(basedOn currentSnapshot: QuotaSnapshot) async throws -> QuotaSnapshot {
        if let error { throw error }
        return snapshot ?? currentSnapshot
    }
}

@MainActor
private final class ProbeManualClock: RefreshSchedulerClock {
    private var storedNow: Date
    private var scheduledAction: (() -> Void)?
    private var scheduledAt: Date?

    init(now: Date) {
        self.storedNow = now
    }

    var now: Date { storedNow }
    var hasScheduledAction: Bool { scheduledAction != nil }

    func schedule(at date: Date, action: @escaping @MainActor () -> Void) {
        scheduledAction = action
        scheduledAt = date
        if date <= storedNow {
            fire()
        }
    }

    func cancelScheduledAction() {
        scheduledAction = nil
        scheduledAt = nil
    }

    func advance(to date: Date) {
        storedNow = date
        if let scheduledAt, let action = scheduledAction, date >= scheduledAt {
            cancelScheduledAction()
            action()
        }
    }

    private func fire() {
        let action = scheduledAction
        cancelScheduledAction()
        action?()
    }
}

@MainActor
private final class ProbeRefreshGate {
    private var recordedTriggers: [AppState.RefreshTrigger] = []
    private var completedCount = 0
    private var activeCount = 0
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func perform(_ trigger: AppState.RefreshTrigger) async {
        activeCount += 1
        recordedTriggers.append(trigger)
        if let continuation = continuations.first {
            continuations.removeFirst()
            continuation.resume()
        }
        // Simulate an in-flight refresh that completes immediately.
        activeCount -= 1
        completedCount += 1
    }

    func callCount() async -> Int { recordedTriggers.count }

    func triggers() async -> [AppState.RefreshTrigger] { recordedTriggers }

    func waitForCall(_ count: Int) async {
        while recordedTriggers.count < count {
            await Task.yield()
        }
    }

    func releaseNext() async {}
    func waitForCompletion(_ count: Int) async {
        while completedCount < count {
            await Task.yield()
        }
    }
}
