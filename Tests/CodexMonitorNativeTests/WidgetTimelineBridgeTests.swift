import XCTest
@testable import CodexMonitorNative

@MainActor
final class WidgetTimelineBridgeTests: XCTestCase {
    func testRestoredStaleSnapshotWritesStaleStateForWidget() {
        let defaults = UserDefaults(suiteName: "CodexMonitorNativeTests.widgetStale.\(UUID().uuidString)")!
        let store = SnapshotStore(defaults: defaults, key: "snapshot")
        let now = Date()
        let resetAt = now.addingTimeInterval(60 * 60)
        let staleSnapshot = QuotaSnapshot(
            weeklyQuotaPercent: 72,
            fiveHourQuotaPercent: 69,
            fiveHourResetAt: resetAt,
            refreshedAt: now.addingTimeInterval(-(21 * 60)),
            dataSource: .real
        )
        store.saveSnapshot(staleSnapshot)

        let appState = AppState(snapshotStore: store, refreshService: WidgetBridgeMockRefreshService(snapshot: staleSnapshot))

        var savedStates: [WidgetDisplayState] = []
        let bridge = WidgetTimelineBridge(
            appState: appState,
            saveState: { savedStates.append($0) },
            reloadTimelines: {}
        )

        XCTAssertEqual(savedStates.last?.snapshot, staleSnapshot)
        XCTAssertEqual(savedStates.last?.status, .stale)
        XCTAssertEqual(savedStates.last?.lastSuccessAt, staleSnapshot.refreshedAt)
        XCTAssertEqual(savedStates.last?.effectiveFiveHourResetAt, resetAt)
        _ = bridge
    }

    func testManualRefreshWritesFinalSuccessStateForWidget() async {
        let defaults = UserDefaults(suiteName: "CodexMonitorNativeTests.widgetSuccess.\(UUID().uuidString)")!
        let store = SnapshotStore(defaults: defaults, key: "snapshot")
        let now = Date()
        let initial = QuotaSnapshot(
            weeklyQuotaPercent: 72,
            fiveHourQuotaPercent: 69,
            fiveHourResetAt: now.addingTimeInterval(60 * 60),
            refreshedAt: now.addingTimeInterval(-60),
            dataSource: .real
        )
        store.saveSnapshot(initial)

        let resetAt = now.addingTimeInterval(2 * 60 * 60)
        let refreshed = QuotaSnapshot(
            weeklyQuotaPercent: 81,
            fiveHourQuotaPercent: 63,
            fiveHourResetAt: resetAt,
            refreshedAt: now,
            dataSource: .real
        )
        let appState = AppState(snapshotStore: store, refreshService: WidgetBridgeMockRefreshService(snapshot: refreshed))

        var savedStates: [WidgetDisplayState] = []
        var reloadCount = 0
        let finalStateSaved = expectation(description: "Widget bridge saved the final success state")
        let bridge = WidgetTimelineBridge(
            appState: appState,
            saveState: {
                savedStates.append($0)
                if $0.snapshot == refreshed, $0.status == .success {
                    finalStateSaved.fulfill()
                }
            },
            reloadTimelines: { reloadCount += 1 }
        )

        await appState.refreshNow(trigger: .manual)
        await fulfillment(of: [finalStateSaved], timeout: 1)

        XCTAssertEqual(savedStates.last?.snapshot, refreshed)
        XCTAssertEqual(savedStates.last?.status, .success)
        XCTAssertEqual(savedStates.last?.lastSuccessAt, refreshed.refreshedAt)
        XCTAssertEqual(savedStates.last?.lastAttemptAt, appState.lastAttemptAt)
        XCTAssertEqual(savedStates.last?.effectiveFiveHourResetAt, resetAt)
        XCTAssertGreaterThan(reloadCount, 0)
        _ = bridge
    }

    func testRefreshInProgressWritesCachedSnapshotAndRefreshingStatusForWidget() async {
        let defaults = UserDefaults(suiteName: "CodexMonitorNativeTests.widgetRefreshing.\(UUID().uuidString)")!
        let store = SnapshotStore(defaults: defaults, key: "snapshot")
        let now = Date()
        let resetAt = now.addingTimeInterval(75 * 60)
        let initial = QuotaSnapshot(
            weeklyQuotaPercent: 72,
            fiveHourQuotaPercent: 69,
            fiveHourResetAt: resetAt,
            refreshedAt: now.addingTimeInterval(-60),
            dataSource: .real
        )
        store.saveSnapshot(initial)

        let refreshed = QuotaSnapshot(
            weeklyQuotaPercent: 81,
            fiveHourQuotaPercent: 63,
            fiveHourResetAt: now.addingTimeInterval(2 * 60 * 60),
            refreshedAt: now,
            dataSource: .real
        )
        let service = WidgetBridgeBlockingRefreshService(snapshot: refreshed)
        let appState = AppState(snapshotStore: store, refreshService: service)

        var savedStates: [WidgetDisplayState] = []
        let refreshingStateSaved = expectation(description: "Widget bridge saved refreshing state with cached data")
        let bridge = WidgetTimelineBridge(
            appState: appState,
            saveState: {
                savedStates.append($0)
                if $0.snapshot == initial, $0.status == .refreshing, $0.lastAttemptAt != nil {
                    refreshingStateSaved.fulfill()
                }
            },
            reloadTimelines: {}
        )

        let refreshTask = Task {
            await appState.refreshNow(trigger: .manual)
        }

        await fulfillment(of: [refreshingStateSaved], timeout: 1)

        XCTAssertEqual(savedStates.last?.snapshot, initial)
        XCTAssertEqual(savedStates.last?.status, .refreshing)
        XCTAssertEqual(savedStates.last?.lastSuccessAt, initial.refreshedAt)
        XCTAssertEqual(savedStates.last?.effectiveFiveHourResetAt, resetAt)

        await service.release()
        await refreshTask.value
        _ = bridge
    }

    func testFailedManualRefreshWritesCachedSnapshotAndFailureStatusForWidget() async {
        let defaults = UserDefaults(suiteName: "CodexMonitorNativeTests.widgetFailure.\(UUID().uuidString)")!
        let store = SnapshotStore(defaults: defaults, key: "snapshot")
        let now = Date()
        let resetAt = now.addingTimeInterval(90 * 60)
        let initial = QuotaSnapshot(
            weeklyQuotaPercent: 72,
            fiveHourQuotaPercent: 69,
            fiveHourResetAt: resetAt,
            refreshedAt: now.addingTimeInterval(-60),
            dataSource: .real
        )
        store.saveSnapshot(initial)

        let appState = AppState(
            snapshotStore: store,
            refreshService: WidgetBridgeFailingRefreshService(error: MockRefreshError.simulatedFailure)
        )

        var savedStates: [WidgetDisplayState] = []
        let finalStateSaved = expectation(description: "Widget bridge saved cached data with failure status")
        let bridge = WidgetTimelineBridge(
            appState: appState,
            saveState: {
                savedStates.append($0)
                if $0.snapshot == initial, $0.status == .networkFailed {
                    finalStateSaved.fulfill()
                }
            },
            reloadTimelines: {}
        )

        await appState.refreshNow(trigger: .manual)
        await fulfillment(of: [finalStateSaved], timeout: 1)

        XCTAssertEqual(savedStates.last?.snapshot, initial)
        XCTAssertEqual(savedStates.last?.status, .networkFailed)
        XCTAssertEqual(savedStates.last?.lastSuccessAt, initial.refreshedAt)
        XCTAssertEqual(savedStates.last?.lastAttemptAt, appState.lastAttemptAt)
        XCTAssertEqual(savedStates.last?.effectiveFiveHourResetAt, resetAt)
        _ = bridge
    }

    func testFailedWakeRefreshWritesCachedSnapshotAndRecoveryTimeForWidget() async {
        let defaults = UserDefaults(suiteName: "CodexMonitorNativeTests.widgetWakeFailure.\(UUID().uuidString)")!
        let store = SnapshotStore(defaults: defaults, key: "snapshot")
        let now = Date()
        let resetAt = now.addingTimeInterval(90 * 60)
        let initial = QuotaSnapshot(
            weeklyQuotaPercent: 72,
            fiveHourQuotaPercent: 69,
            fiveHourResetAt: resetAt,
            refreshedAt: now.addingTimeInterval(-60),
            dataSource: .real
        )
        store.saveSnapshot(initial)

        let appState = AppState(
            snapshotStore: store,
            refreshService: WidgetBridgeFailingRefreshService(error: MockRefreshError.simulatedFailure)
        )

        var savedStates: [WidgetDisplayState] = []
        let finalStateSaved = expectation(description: "Widget bridge preserved cached data after wake failure")
        let bridge = WidgetTimelineBridge(
            appState: appState,
            saveState: {
                savedStates.append($0)
                if $0.snapshot == initial, $0.status == .networkFailed {
                    finalStateSaved.fulfill()
                }
            },
            reloadTimelines: {}
        )

        await appState.refreshNow(trigger: .wake)
        await fulfillment(of: [finalStateSaved], timeout: 1)

        XCTAssertEqual(savedStates.last?.snapshot, initial)
        XCTAssertEqual(savedStates.last?.status, .networkFailed)
        XCTAssertEqual(savedStates.last?.lastSuccessAt, initial.refreshedAt)
        XCTAssertEqual(savedStates.last?.lastAttemptAt, appState.lastAttemptAt)
        XCTAssertEqual(savedStates.last?.effectiveFiveHourResetAt, resetAt)
        _ = bridge
    }
}

private struct WidgetBridgeMockRefreshService: QuotaRefreshing {
    let snapshot: QuotaSnapshot

    func refresh(basedOn currentSnapshot: QuotaSnapshot) async throws -> QuotaSnapshot {
        snapshot
    }
}

private struct WidgetBridgeFailingRefreshService: QuotaRefreshing {
    let error: Error

    func refresh(basedOn currentSnapshot: QuotaSnapshot) async throws -> QuotaSnapshot {
        throw error
    }
}

private actor WidgetBridgeBlockingRefreshService: QuotaRefreshing {
    let snapshot: QuotaSnapshot
    private var continuation: CheckedContinuation<Void, Never>?

    init(snapshot: QuotaSnapshot) {
        self.snapshot = snapshot
    }

    func refresh(basedOn currentSnapshot: QuotaSnapshot) async throws -> QuotaSnapshot {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
        return snapshot
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
