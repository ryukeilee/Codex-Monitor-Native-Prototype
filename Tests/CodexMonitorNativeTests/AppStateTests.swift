import XCTest
@testable import CodexMonitorNative

@MainActor
final class AppStateTests: XCTestCase {
    func testLateRefreshNowResultCannotOverwriteNewManagedRefreshAfterShutdown() async {
        let defaults = UserDefaults(suiteName: "CodexMonitorNativeTests.refreshNowOwnership.\(UUID().uuidString)")!
        let oldSnapshot = QuotaSnapshot(weeklyQuotaPercent: 10, fiveHourQuotaPercent: 20, refreshedAt: .now, dataSource: .real)
        let newSnapshot = QuotaSnapshot(weeklyQuotaPercent: 90, fiveHourQuotaPercent: 80, refreshedAt: .now, dataSource: .real)
        let service = QueueingSnapshotRefreshService(snapshots: [oldSnapshot, newSnapshot])
        let appState = AppState(snapshotStore: SnapshotStore(defaults: defaults, key: "snapshot"), refreshService: service)

        let oldTask = Task { await appState.refreshNow(trigger: .manual) }
        await service.waitForCall(1)
        appState.shutdown()
        appState.refresh(trigger: .wake)
        await service.waitForCall(2)
        await service.release(call: 2)
        await Task.yield()
        await service.release(call: 1)
        await oldTask.value
        for _ in 0..<3 { await Task.yield() }

        XCTAssertEqual(appState.snapshot, newSnapshot)
        XCTAssertEqual(appState.status, .success)
        XCTAssertEqual(appState.failureCount, 0)
        XCTAssertEqual(appState.backoffInterval, 300)
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

    func testShutdownSettlesRefreshAndAllowsANewRequestWhenProviderIgnoresCancellation() async {
        let defaults = UserDefaults(suiteName: "CodexMonitorNativeTests.shutdown.\(UUID().uuidString)")!
        let service = QueueingBlockingRefreshService(snapshot: QuotaSnapshot(
            weeklyQuotaPercent: 80, fiveHourQuotaPercent: 60, refreshedAt: .now, dataSource: .real
        ))
        let appState = AppState(snapshotStore: SnapshotStore(defaults: defaults, key: "snapshot"), refreshService: service)

        appState.refresh(trigger: .manual)
        await service.waitForCall(1)
        appState.shutdown()
        XCTAssertNotEqual(appState.status, .refreshing)

        appState.refresh(trigger: .wake)
        await service.waitForCall(2)
        await service.releaseNext()
        await service.releaseNext()
    }
    func testConcurrentRefreshEntrypointsStartOnlyOneRequest() async {
        let defaults = UserDefaults(suiteName: "CodexMonitorNativeTests.singleFlight.\(UUID().uuidString)")!
        let store = SnapshotStore(defaults: defaults, key: "snapshot")
        let service = BlockingRefreshService(snapshot: QuotaSnapshot(
            weeklyQuotaPercent: 80, fiveHourQuotaPercent: 60, refreshedAt: .now, dataSource: .real
        ))
        let appState = AppState(snapshotStore: store, refreshService: service)

        appState.refresh(trigger: .manual)
        appState.refresh(trigger: .scheduled)
        appState.refresh(trigger: .wake)
        await service.waitForStart()

        let callCount = await service.callCount()
        XCTAssertEqual(callCount, 1)
        XCTAssertEqual(appState.status, .refreshing)

        await service.release()
        for _ in 0..<3 { await Task.yield() }
        XCTAssertEqual(appState.status, .success)
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
            refreshService: MockRefreshService(error: RealQuotaError.rpcError("Unauthorized: please login"))
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
            refreshService: MockRefreshService(error: RealQuotaError.parseFailed("missing rateLimitsByLimitId"))
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
        await appState.refreshNow(trigger: .manual)

        let restored = AppState(snapshotStore: SnapshotStore(defaults: defaults, key: "snapshot"), refreshService: MockRefreshService(snapshot: real))
        XCTAssertEqual(restored.snapshot, real)
        XCTAssertEqual(restored.dataSource, .real)
    }

    func testOutOfOrderRealRefreshDoesNotReplaceNewerCachedSnapshot() async {
        let defaults = UserDefaults(suiteName: "CodexMonitorNativeTests.outOfOrder.\(UUID().uuidString)")!
        let newer = QuotaSnapshot(weeklyQuotaPercent: 90, fiveHourQuotaPercent: 80, refreshedAt: Date(timeIntervalSince1970: 200), dataSource: .real)
        let older = QuotaSnapshot(weeklyQuotaPercent: 10, fiveHourQuotaPercent: 20, refreshedAt: Date(timeIntervalSince1970: 100), dataSource: .real)
        let store = SnapshotStore(defaults: defaults, key: "snapshot")
        store.saveSnapshot(newer)

        let appState = AppState(snapshotStore: store, refreshService: MockRefreshService(snapshot: older))
        await appState.refreshNow(trigger: .manual)

        XCTAssertEqual(appState.snapshot, newer)
        XCTAssertNotEqual(appState.status, .refreshing)
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

    func testConcurrentRefreshRequestsDoNotStartTwice() async {
        let defaults = UserDefaults(suiteName: "CodexMonitorNativeTests.concurrent.\(UUID().uuidString)")!
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
        let service = BlockingRefreshService(snapshot: refreshed)
        let appState = AppState(snapshotStore: store, refreshService: service)

        let first = Task {
            await appState.refreshNow(trigger: .manual)
        }
        await service.waitForStart()

        let second = Task {
            await appState.refreshNow(trigger: .manual)
        }

        await service.waitForStart()
        let callCount = await service.callCount()
        XCTAssertEqual(callCount, 1)

        await service.release()
        await first.value
        await second.value
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

private actor QueueingBlockingRefreshService: QuotaRefreshing {
    let snapshot: QuotaSnapshot
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var callCountValue = 0
    private var waiters: [Int: CheckedContinuation<Void, Never>] = [:]

    init(snapshot: QuotaSnapshot) { self.snapshot = snapshot }

    func refresh(basedOn currentSnapshot: QuotaSnapshot) async throws -> QuotaSnapshot {
        callCountValue += 1
        waiters.removeValue(forKey: callCountValue)?.resume()
        await withCheckedContinuation { continuations.append($0) }
        return snapshot
    }

    func waitForCall(_ count: Int) async {
        if callCountValue >= count { return }
        await withCheckedContinuation { waiters[count] = $0 }
    }

    func releaseNext() {
        guard !continuations.isEmpty else { return }
        continuations.removeFirst().resume()
    }
}

private actor QueueingSnapshotRefreshService: QuotaRefreshing {
    private let snapshots: [QuotaSnapshot]
    private var continuations: [Int: CheckedContinuation<Void, Never>] = [:]
    private var callCountValue = 0
    private var waiters: [Int: CheckedContinuation<Void, Never>] = [:]

    init(snapshots: [QuotaSnapshot]) { self.snapshots = snapshots }

    func refresh(basedOn _: QuotaSnapshot) async throws -> QuotaSnapshot {
        callCountValue += 1
        let call = callCountValue
        waiters.removeValue(forKey: call)?.resume()
        await withCheckedContinuation { continuations[call] = $0 }
        return snapshots[call - 1]
    }

    func waitForCall(_ count: Int) async {
        if callCountValue >= count { return }
        await withCheckedContinuation { waiters[count] = $0 }
    }

    func release(call: Int) {
        continuations.removeValue(forKey: call)?.resume()
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
