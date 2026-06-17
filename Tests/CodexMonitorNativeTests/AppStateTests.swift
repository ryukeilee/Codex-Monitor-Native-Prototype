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
        XCTAssertEqual(store.loadSnapshot(), refreshed)
    }

    func testFailedRefreshKeepsLastSuccessfulSnapshot() async {
        let defaults = UserDefaults(suiteName: "CodexMonitorNativeTests.failure.\(UUID().uuidString)")!
        let store = SnapshotStore(defaults: defaults, key: "snapshot")
        let initial = QuotaSnapshot(
            weeklyQuotaPercent: 72, fiveHourQuotaPercent: 69, refreshedAt: .distantPast,
            dataSource: .real
        )
        store.saveSnapshot(initial)

        let appState = AppState(snapshotStore: store, refreshService: MockRefreshService(snapshot: nil))

        await appState.refreshNow(trigger: .manual)

        XCTAssertEqual(appState.snapshot, initial)
        XCTAssertEqual(appState.status, .networkFailed)
        XCTAssertEqual(appState.dataSource, .real)
        XCTAssertEqual(appState.failureCount, 1)
        XCTAssertEqual(store.loadSnapshot(), initial)
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
}

private struct MockRefreshService: QuotaRefreshing {
    let snapshot: QuotaSnapshot?

    func refresh(basedOn currentSnapshot: QuotaSnapshot) async throws -> QuotaSnapshot {
        guard let snapshot else {
            throw MockRefreshError.simulatedFailure
        }
        return snapshot
    }
}
