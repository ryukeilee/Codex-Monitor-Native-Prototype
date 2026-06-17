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
        XCTAssertEqual(appState.status, .normal)
        XCTAssertEqual(appState.dataSource, .real)
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
        XCTAssertEqual(appState.status, .failed)
        XCTAssertEqual(appState.dataSource, .real)
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
        XCTAssertEqual(restoredState.status, .normal)
        XCTAssertEqual(restoredState.dataSource, .real)
    }

    func testMockSnapshotShowsNotConnected() {
        let defaults = UserDefaults(suiteName: "CodexMonitorNativeTests.mock.\(UUID().uuidString)")!
        let store = SnapshotStore(defaults: defaults, key: "snapshot")
        let mockSnapshot = QuotaSnapshot(
            weeklyQuotaPercent: 72, fiveHourQuotaPercent: 69, refreshedAt: .distantPast,
            dataSource: .mock
        )
        store.saveSnapshot(mockSnapshot)

        let appState = AppState(snapshotStore: store, refreshService: MockRefreshService(snapshot: mockSnapshot))

        XCTAssertEqual(appState.dataSource, .mock)
        XCTAssertEqual(appState.status, .notConnected)
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
