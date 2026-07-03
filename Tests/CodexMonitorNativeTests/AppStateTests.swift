import XCTest
@testable import CodexMonitorNative

@MainActor
final class AppStateTests: XCTestCase {
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
        XCTAssertEqual(appState.realQuotaHealth, RealQuotaHealthDiagnostic(kind: .rpcRejected, isUsingCachedSnapshot: true))
        XCTAssertEqual(appState.effectiveFiveHourResetAt, resetAt)
        XCTAssertEqual(store.loadSnapshot(), initial)
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
        await Task.yield()

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

        XCTAssertEqual(summary?.countLine, "剩余重置次数未知（未暴露）")
        XCTAssertEqual(summary?.timingLine, "到期时间暂不可用")
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
        await Task.yield()

        let second = Task {
            await appState.refreshNow(trigger: .manual)
        }

        await Task.yield()
        let callCount = await service.callCount()
        XCTAssertEqual(callCount, 1)

        await service.release()
        await first.value
        await second.value
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
    private var callCountValue = 0

    init(snapshot: QuotaSnapshot) {
        self.snapshot = snapshot
    }

    func refresh(basedOn currentSnapshot: QuotaSnapshot) async throws -> QuotaSnapshot {
        callCountValue += 1
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
        return snapshot
    }

    func callCount() -> Int {
        callCountValue
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
