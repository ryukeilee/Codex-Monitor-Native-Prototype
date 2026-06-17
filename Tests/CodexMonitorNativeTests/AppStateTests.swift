import XCTest
@testable import CodexMonitorNative

@MainActor
final class AppStateTests: XCTestCase {
    func testSuccessfulRefreshUpdatesSnapshotAndPersistsIt() async {
        let defaults = UserDefaults(suiteName: "CodexMonitorNativeTests.success.\(UUID().uuidString)")!
        let store = SnapshotStore(defaults: defaults, key: "snapshot")
        let initial = QuotaSnapshot(weeklyQuotaPercent: 72, fiveHourQuotaPercent: 69, refreshedAt: .distantPast)
        store.saveSnapshot(initial)

        let refreshed = QuotaSnapshot(weeklyQuotaPercent: 75, fiveHourQuotaPercent: 63, refreshedAt: .now)
        let appState = AppState(snapshotStore: store, refreshService: MockRefreshService(snapshot: refreshed))

        await appState.refreshNow(trigger: .manual)

        XCTAssertEqual(appState.snapshot, refreshed)
        XCTAssertEqual(appState.status, .normal)
        XCTAssertEqual(store.loadSnapshot(), refreshed)
    }

    func testFailedRefreshKeepsLastSuccessfulSnapshot() async {
        let defaults = UserDefaults(suiteName: "CodexMonitorNativeTests.failure.\(UUID().uuidString)")!
        let store = SnapshotStore(defaults: defaults, key: "snapshot")
        let initial = QuotaSnapshot(weeklyQuotaPercent: 72, fiveHourQuotaPercent: 69, refreshedAt: .distantPast)
        store.saveSnapshot(initial)

        let appState = AppState(snapshotStore: store, refreshService: MockRefreshService(snapshot: nil))

        await appState.refreshNow(trigger: .manual)

        XCTAssertEqual(appState.snapshot, initial)
        XCTAssertEqual(appState.status, .failed)
        XCTAssertEqual(store.loadSnapshot(), initial)
    }

    func testSnapshotStoreRestoresLatestSuccessfulSnapshotAcrossInstances() {
        let defaults = UserDefaults(suiteName: "CodexMonitorNativeTests.restore.\(UUID().uuidString)")!
        let store = SnapshotStore(defaults: defaults, key: "snapshot")
        let snapshot = QuotaSnapshot(weeklyQuotaPercent: 64, fiveHourQuotaPercent: 52, refreshedAt: .now)
        store.saveSnapshot(snapshot)

        let restoredState = AppState(snapshotStore: store, refreshService: MockRefreshService(snapshot: snapshot))

        XCTAssertEqual(restoredState.snapshot, snapshot)
    }
}

private struct MockRefreshService: QuotaRefreshing {
    let snapshot: QuotaSnapshot?

    func refresh(basedOn currentSnapshot: QuotaSnapshot) async throws -> QuotaSnapshot {
        guard let snapshot else {
            throw RefreshFailure.simulatedFailure
        }
        return snapshot
    }
}
