import XCTest
@testable import CodexMonitorNative

@MainActor
final class WidgetTimelineBridgeTests: XCTestCase {
    func testShutdownUsesSettledFreshCacheStateForWidget() async {
        let defaults = UserDefaults(suiteName: "CodexMonitorNativeTests.widgetShutdownCache.\(UUID().uuidString)")!
        let snapshot = QuotaSnapshot(weeklyQuotaPercent: 70, fiveHourQuotaPercent: 60, refreshedAt: .now, dataSource: .real)
        let store = SnapshotStore(defaults: defaults, key: "snapshot")
        store.saveSnapshot(snapshot)
        let service = WidgetBridgeBlockingRefreshService(snapshot: snapshot)
        let appState = AppState(snapshotStore: store, refreshService: service)
        var savedStates: [WidgetDisplayState] = []
        var reloadCount = 0
        let bridge = WidgetTimelineBridge(appState: appState, saveState: { savedStates.append($0) }, reloadTimelines: { reloadCount += 1 })
        savedStates.removeAll()
        reloadCount = 0

        appState.refresh(trigger: .manual)
        await service.waitForStart()
        appState.shutdown()
        bridge.shutdown()

        XCTAssertEqual(savedStates.last?.snapshot, snapshot)
        XCTAssertEqual(savedStates.last?.status, .success)
        XCTAssertEqual(reloadCount, 1)
    }

    func testShutdownUsesSettledNoSnapshotStateForWidgetWithoutCache() async {
        let defaults = UserDefaults(suiteName: "CodexMonitorNativeTests.widgetShutdownNoCache.\(UUID().uuidString)")!
        let service = WidgetBridgeBlockingRefreshService(snapshot: .notConnected)
        let appState = AppState(snapshotStore: SnapshotStore(defaults: defaults, key: "snapshot"), refreshService: service)
        var savedStates: [WidgetDisplayState] = []
        var reloadCount = 0
        let bridge = WidgetTimelineBridge(appState: appState, saveState: { savedStates.append($0) }, reloadTimelines: { reloadCount += 1 })
        savedStates.removeAll()
        reloadCount = 0

        appState.refresh(trigger: .manual)
        await service.waitForStart()
        appState.shutdown()
        bridge.shutdown()

        XCTAssertEqual(savedStates.last?.snapshot, .notConnected)
        XCTAssertEqual(savedStates.last?.status, appState.displayStatus)
        XCTAssertNotEqual(savedStates.last?.status, .refreshing)
        XCTAssertEqual(reloadCount, 1)
    }
    func testBridgeShutdownReplacesPersistedRefreshingStateAndReloadsWidget() async {
        let defaults = UserDefaults(suiteName: "CodexMonitorNativeTests.widgetBridgeDeinit.\(UUID().uuidString)")!
        let initial = QuotaSnapshot(weeklyQuotaPercent: 70, fiveHourQuotaPercent: 60, refreshedAt: .now, dataSource: .real)
        let store = SnapshotStore(defaults: defaults, key: "snapshot")
        store.saveSnapshot(initial)
        let service = WidgetBridgeBlockingRefreshService(snapshot: initial)
        let appState = AppState(snapshotStore: store, refreshService: service)
        var savedStates: [WidgetDisplayState] = []
        var reloadCount = 0
        var bridge: WidgetTimelineBridge? = WidgetTimelineBridge(
            appState: appState,
            saveState: { savedStates.append($0) },
            reloadTimelines: { reloadCount += 1 }
        )
        XCTAssertNotNil(bridge)
        savedStates.removeAll()
        reloadCount = 0

        appState.refresh(trigger: .manual)
        await service.waitForStart()
        for _ in 0..<3 { await Task.yield() }
        XCTAssertEqual(savedStates.last?.status, .refreshing)

        appState.shutdown()
        bridge?.shutdown()
        bridge = nil

        XCTAssertNotEqual(savedStates.last?.status, .refreshing)
        XCTAssertEqual(reloadCount, 1)
        appState.shutdown()
    }
    func testWidgetQuotaTextMatchesPopoverQuotaFormatting() {
        let now = Date()
        let snapshot = QuotaSnapshot(
            weeklyQuotaPercent: 71,
            fiveHourQuotaPercent: 64,
            fiveHourResetAt: now.addingTimeInterval(60 * 60),
            refreshedAt: now,
            dataSource: .real
        )
        let state = WidgetDisplayState.make(
            snapshot: snapshot,
            status: .success,
            lastSuccessAt: now,
            lastAttemptAt: now,
            effectiveFiveHourResetAt: snapshot.fiveHourResetAt,
            savedAt: now
        )

        XCTAssertEqual(
            state.fiveHourQuotaText,
            StatusPopoverFormatting.quotaValueText(for: .fiveHour, snapshot: snapshot, status: .success)
        )
        XCTAssertEqual(
            state.weeklyQuotaText,
            StatusPopoverFormatting.quotaValueText(for: .weekly, snapshot: snapshot, status: .success)
        )
        XCTAssertEqual(state.fiveHourQuotaText, "64%")
        XCTAssertEqual(state.weeklyQuotaText, "71%")
    }

    func testWidgetQuotaTextHidesHistoricalFields() {
        let now = Date()
        let snapshot = QuotaSnapshot(
            weeklyQuotaPercent: 71,
            fiveHourQuotaPercent: 64,
            weeklyQuotaState: .cached,
            fiveHourQuotaState: .unavailable,
            refreshedAt: now,
            dataSource: .real
        )
        let state = WidgetDisplayState.make(
            snapshot: snapshot,
            status: .success,
            lastSuccessAt: now,
            lastAttemptAt: now,
            effectiveFiveHourResetAt: nil,
            savedAt: now
        )

        XCTAssertEqual(state.fiveHourQuotaText, "--")
        XCTAssertEqual(state.weeklyQuotaText, "--")
    }

    func testWidgetQuotaDisplayDoesNotExposeHistoricalCache() {
        let snapshot = QuotaSnapshot(
            weeklyQuotaPercent: 71,
            fiveHourQuotaPercent: 64,
            weeklyQuotaState: .cached,
            refreshedAt: .now,
            dataSource: .real
        )
        let state = WidgetDisplayState.make(
            snapshot: snapshot,
            status: .success,
            lastSuccessAt: snapshot.refreshedAt,
            lastAttemptAt: snapshot.refreshedAt,
            effectiveFiveHourResetAt: nil,
            savedAt: snapshot.refreshedAt
        )

        XCTAssertEqual(state.weeklyQuotaDisplay.percentText, "--")
        XCTAssertNil(state.weeklyQuotaDisplay.historyCaption)
    }

    func testWidgetSelectionShowsOnlyMonthlyWindowAsPrimary() {
        let snapshot = QuotaSnapshot(
            weeklyQuotaPercent: 0,
            fiveHourQuotaPercent: 0,
            weeklyQuotaState: .unavailable,
            fiveHourQuotaState: .unavailable,
            refreshedAt: .now,
            dataSource: .real,
            quotaWindows: [
                QuotaWindow(
                    limitId: "codex",
                    windowId: "monthly",
                    kind: .monthly,
                    durationMinutes: 43_200,
                    remainingPercent: 58
                )
            ]
        )
        let state = WidgetDisplayState.make(
            snapshot: snapshot,
            status: .success,
            lastSuccessAt: snapshot.refreshedAt,
            lastAttemptAt: snapshot.refreshedAt,
            effectiveFiveHourResetAt: nil,
            savedAt: snapshot.refreshedAt
        )

        let selection = state.quotaSelection(capacity: 1, now: snapshot.refreshedAt)

        XCTAssertEqual(selection.primaryItem?.kind, .monthly)
        XCTAssertEqual(selection.primaryItem?.label, "月额度")
        XCTAssertEqual(selection.primaryItem?.percentText, "58%")
        XCTAssertEqual(selection.primaryItem?.trustedPercent, 58)
        XCTAssertEqual(selection.overflowCount, 0)
    }

    func testWidgetSelectionHidesOnlyUnknownWindow() {
        let snapshot = QuotaSnapshot(
            weeklyQuotaPercent: 0,
            fiveHourQuotaPercent: 0,
            weeklyQuotaState: .unavailable,
            fiveHourQuotaState: .unavailable,
            refreshedAt: .now,
            dataSource: .real,
            quotaWindows: [
                QuotaWindow(
                    limitId: "future",
                    windowId: "bank",
                    kind: .unknown,
                    durationMinutes: 720,
                    remainingPercent: 47
                )
            ]
        )
        let state = WidgetDisplayState.make(
            snapshot: snapshot,
            status: .success,
            lastSuccessAt: snapshot.refreshedAt,
            lastAttemptAt: snapshot.refreshedAt,
            effectiveFiveHourResetAt: nil,
            savedAt: snapshot.refreshedAt
        )

        let selection = state.quotaSelection(capacity: 1, now: snapshot.refreshedAt)

        XCTAssertNil(selection.primaryItem)
        XCTAssertEqual(selection.overflowCount, 0)
    }

    func testWidgetSelectionReportsOverflowAndUsesStablePrimaryOrder() {
        let snapshot = QuotaSnapshot(
            weeklyQuotaPercent: 0,
            fiveHourQuotaPercent: 0,
            weeklyQuotaState: .unavailable,
            fiveHourQuotaState: .unavailable,
            refreshedAt: .now,
            dataSource: .real,
            quotaWindows: [
                QuotaWindow(limitId: "future", windowId: "bank", kind: .unknown, remainingPercent: 40),
                QuotaWindow(limitId: "codex", windowId: "monthly", kind: .monthly, remainingPercent: 50),
                QuotaWindow(limitId: "codex", windowId: "secondary", kind: .weekly, remainingPercent: 60),
                QuotaWindow(limitId: "codex", windowId: "primary", kind: .fiveHour, remainingPercent: 70)
            ]
        )
        let state = WidgetDisplayState.make(
            snapshot: snapshot,
            status: .success,
            lastSuccessAt: snapshot.refreshedAt,
            lastAttemptAt: snapshot.refreshedAt,
            effectiveFiveHourResetAt: nil,
            savedAt: snapshot.refreshedAt
        )

        let compact = state.quotaSelection(capacity: 1, now: snapshot.refreshedAt)
        let medium = state.quotaSelection(capacity: 3, now: snapshot.refreshedAt)

        XCTAssertEqual(compact.primaryItem?.kind, .fiveHour)
        XCTAssertEqual(compact.overflowCount, 2)
        XCTAssertEqual(medium.visibleItems.map(\.kind), [.fiveHour, .weekly, .monthly])
        XCTAssertEqual(medium.overflowCount, 0)
    }

    func testWidgetSelectionDropsUntrustedWindowWithoutCountingItAsOverflow() {
        let snapshot = QuotaSnapshot(
            weeklyQuotaPercent: 0,
            fiveHourQuotaPercent: 0,
            weeklyQuotaState: .unavailable,
            fiveHourQuotaState: .unavailable,
            refreshedAt: .now,
            dataSource: .real,
            quotaWindows: [
                QuotaWindow(
                    limitId: "codex",
                    windowId: "primary",
                    kind: .fiveHour,
                    remainingPercent: 99,
                    state: .invalid
                ),
                QuotaWindow(limitId: "codex", windowId: "monthly", kind: .monthly, remainingPercent: 45)
            ]
        )
        let state = WidgetDisplayState.make(
            snapshot: snapshot,
            status: .success,
            lastSuccessAt: snapshot.refreshedAt,
            lastAttemptAt: snapshot.refreshedAt,
            effectiveFiveHourResetAt: nil,
            savedAt: snapshot.refreshedAt
        )

        let selection = state.quotaSelection(capacity: 1, now: snapshot.refreshedAt)

        XCTAssertEqual(selection.primaryItem?.kind, .monthly)
        XCTAssertEqual(selection.primaryItem?.percentText, "45%")
        XCTAssertEqual(selection.overflowCount, 0)
    }

    func testWidgetEarliestResetCreditLineUsesEarliestAvailableExpiry() {
        let now = Date(timeIntervalSince1970: 1_720_000_000)
        let snapshot = QuotaSnapshot(
            weeklyQuotaPercent: 71,
            fiveHourQuotaPercent: 64,
            resetCreditDetails: [
                ResetCreditDetailSnapshot(
                    ordinal: 3,
                    status: "expired",
                    grantedAt: now.addingTimeInterval(-6_000),
                    expiresAt: now.addingTimeInterval(3 * 60 * 60)
                ),
                ResetCreditDetailSnapshot(
                    ordinal: 4,
                    status: "redeemed",
                    grantedAt: now.addingTimeInterval(-5_000),
                    expiresAt: now.addingTimeInterval(6 * 60 * 60)
                ),
                ResetCreditDetailSnapshot(
                    ordinal: 2,
                    status: "available",
                    grantedAt: now.addingTimeInterval(-2_000),
                    expiresAt: now.addingTimeInterval(36 * 60 * 60)
                ),
                ResetCreditDetailSnapshot(
                    ordinal: 1,
                    status: " AVAILABLE ",
                    grantedAt: now.addingTimeInterval(-4_000),
                    expiresAt: now.addingTimeInterval(12 * 60 * 60 + 5 * 60)
                )
            ],
            fiveHourResetAt: now.addingTimeInterval(60 * 60),
            refreshedAt: now,
            dataSource: .real
        )
        let state = WidgetDisplayState.make(
            snapshot: snapshot,
            status: .success,
            lastSuccessAt: now,
            lastAttemptAt: now,
            effectiveFiveHourResetAt: snapshot.fiveHourResetAt,
            savedAt: now
        )

        XCTAssertEqual(
            state.earliestResetCreditLine(
                locale: Locale(identifier: "en_US_POSIX"),
                timeZone: TimeZone(secondsFromGMT: 0)!
            ),
            "最早重置 7/3 21:51"
        )
        XCTAssertEqual(state.resetCreditFooterText, state.resetCreditFooterLine)
        XCTAssertEqual(state.resetCreditFooterText, state.earliestResetCreditLine())
    }

    func testWidgetEarliestResetCreditLineHidesWhenNoAvailableExpiryExists() {
        let now = Date()
        let snapshot = QuotaSnapshot(
            weeklyQuotaPercent: 71,
            fiveHourQuotaPercent: 64,
            refreshedAt: now,
            dataSource: .real
        )
        let state = WidgetDisplayState.make(
            snapshot: snapshot,
            status: .success,
            lastSuccessAt: now,
            lastAttemptAt: now,
            effectiveFiveHourResetAt: snapshot.fiveHourResetAt,
            savedAt: now
        )

        XCTAssertNil(state.earliestResetCreditLine())
        XCTAssertNil(state.resetCreditFooterLine)
        XCTAssertNil(state.resetCreditFooterText)
    }

    func testWidgetStateDecodesLegacyPayloadWithoutFooterLine() throws {
        let now = Date(timeIntervalSince1970: 1_720_000_000)
        let snapshot = QuotaSnapshot(
            weeklyQuotaPercent: 71,
            fiveHourQuotaPercent: 64,
            resetCreditDetailsState: .detailed,
            resetCreditDetails: [
                ResetCreditDetailSnapshot(
                    ordinal: 1,
                    status: "available",
                    grantedAt: now.addingTimeInterval(-4_000),
                    expiresAt: now.addingTimeInterval(12 * 60 * 60 + 5 * 60)
                )
            ],
            fiveHourResetAt: now.addingTimeInterval(60 * 60),
            refreshedAt: now,
            dataSource: .real
        )
        let state = WidgetDisplayState.make(
            snapshot: snapshot,
            status: .success,
            lastSuccessAt: now,
            lastAttemptAt: now,
            effectiveFiveHourResetAt: snapshot.fiveHourResetAt,
            savedAt: now
        )
        var payload = try JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as! [String: Any]
        payload.removeValue(forKey: "resetCreditFooterLine")
        let legacyData = try JSONSerialization.data(withJSONObject: payload)
        let groupURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexMonitorNativeTests.widgetLegacy.\(UUID().uuidString)", isDirectory: true)
        let fileManager = WidgetStateTestFileManager(groupURL: groupURL)
        let stateURL = WidgetDisplayStateStore.stateURL(fileManager: fileManager)
        try FileManager.default.createDirectory(
            at: stateURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try legacyData.write(to: stateURL)

        let decoded = WidgetDisplayStateStore.load(fileManager: fileManager)

        XCTAssertEqual(decoded.resetCreditFooterLine, decoded.earliestResetCreditLine())
        XCTAssertEqual(decoded.resetCreditFooterText, decoded.resetCreditFooterLine)
    }

    func testWidgetStateCorruptionIsIsolatedAndFallsBackToPlaceholder() throws {
        let groupURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexMonitorNativeTests.widgetCorrupt.\(UUID().uuidString)", isDirectory: true)
        let fileManager = WidgetStateTestFileManager(groupURL: groupURL)
        let stateURL = WidgetDisplayStateStore.stateURL(fileManager: fileManager)
        try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("truncated".utf8).write(to: stateURL)

        XCTAssertEqual(WidgetDisplayStateStore.load(fileManager: fileManager), .placeholder)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stateURL.appendingPathExtension("corrupt").path) ||
                      FileManager.default.fileExists(atPath: stateURL.deletingPathExtension().appendingPathComponent("WidgetDisplayState.corrupt").path))
    }

    func testWidgetStateDoesNotLetOlderWriteReplaceNewerState() {
        let groupURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexMonitorNativeTests.widgetNewest.\(UUID().uuidString)", isDirectory: true)
        let fileManager = WidgetStateTestFileManager(groupURL: groupURL)
        let newer = WidgetDisplayState.make(snapshot: .notConnected, status: .noSnapshot, lastSuccessAt: nil, lastAttemptAt: nil, effectiveFiveHourResetAt: nil, savedAt: Date(timeIntervalSince1970: 200))
        let older = WidgetDisplayState.make(snapshot: .notConnected, status: .noSnapshot, lastSuccessAt: nil, lastAttemptAt: nil, effectiveFiveHourResetAt: nil, savedAt: Date(timeIntervalSince1970: 100))

        WidgetDisplayStateStore.save(newer, fileManager: fileManager)
        WidgetDisplayStateStore.save(older, fileManager: fileManager)

        XCTAssertEqual(WidgetDisplayStateStore.load(fileManager: fileManager), newer)
    }

    func testWidgetStateDoesNotLetOlderRealSnapshotReplaceNewerRealSnapshot() {
        let groupURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexMonitorNativeTests.widgetRealNewest.\(UUID().uuidString)", isDirectory: true)
        let fileManager = WidgetStateTestFileManager(groupURL: groupURL)
        let newerSnapshot = QuotaSnapshot(weeklyQuotaPercent: 90, fiveHourQuotaPercent: 80, refreshedAt: Date(timeIntervalSince1970: 200), dataSource: .real)
        let olderSnapshot = QuotaSnapshot(weeklyQuotaPercent: 10, fiveHourQuotaPercent: 20, refreshedAt: Date(timeIntervalSince1970: 100), dataSource: .real)
        let newer = WidgetDisplayState.make(snapshot: newerSnapshot, status: .success, lastSuccessAt: newerSnapshot.refreshedAt, lastAttemptAt: nil, effectiveFiveHourResetAt: nil, savedAt: Date(timeIntervalSince1970: 100))
        let older = WidgetDisplayState.make(snapshot: olderSnapshot, status: .success, lastSuccessAt: olderSnapshot.refreshedAt, lastAttemptAt: nil, effectiveFiveHourResetAt: nil, savedAt: Date(timeIntervalSince1970: 200))

        WidgetDisplayStateStore.save(newer, fileManager: fileManager)
        WidgetDisplayStateStore.save(older, fileManager: fileManager)

        XCTAssertEqual(WidgetDisplayStateStore.load(fileManager: fileManager).snapshot, newerSnapshot)
    }

    func testWidgetStateFileRemainsReadableByOlderExtensionVersions() throws {
        let groupURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexMonitorNativeTests.widgetLegacyCompatibility.\(UUID().uuidString)", isDirectory: true)
        let fileManager = WidgetStateTestFileManager(groupURL: groupURL)
        let now = Date(timeIntervalSince1970: 200)
        let snapshot = QuotaSnapshot(
            weeklyQuotaPercent: 81,
            fiveHourQuotaPercent: 63,
            refreshedAt: now,
            dataSource: .real
        )
        let state = WidgetDisplayState.make(
            snapshot: snapshot,
            status: .success,
            lastSuccessAt: now,
            lastAttemptAt: now,
            effectiveFiveHourResetAt: nil,
            savedAt: now
        )

        WidgetDisplayStateStore.save(state, fileManager: fileManager)

        let data = try Data(contentsOf: WidgetDisplayStateStore.stateURL(fileManager: fileManager))
        let legacyDecoded = try JSONDecoder().decode(WidgetDisplayState.self, from: data)
        XCTAssertEqual(legacyDecoded, state)

        let envelope = try JSONDecoder().decode(PersistenceEnvelope.self, from: data)
        XCTAssertEqual(envelope.formatVersion, PersistenceEnvelope.currentFormatVersion)
        XCTAssertEqual(envelope.revision, 1)
        XCTAssertEqual(try envelope.decode(WidgetDisplayState.self), state)
    }

    func testWidgetRealStateIsNotReplacedByLaterMockState() {
        let groupURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexMonitorNativeTests.widgetRealThenMock.\(UUID().uuidString)", isDirectory: true)
        let fileManager = WidgetStateTestFileManager(groupURL: groupURL)
        let realSnapshot = QuotaSnapshot(weeklyQuotaPercent: 90, fiveHourQuotaPercent: 80, refreshedAt: Date(timeIntervalSince1970: 100), dataSource: .real)
        let real = WidgetDisplayState.make(snapshot: realSnapshot, status: .success, lastSuccessAt: realSnapshot.refreshedAt, lastAttemptAt: nil, effectiveFiveHourResetAt: nil, savedAt: Date(timeIntervalSince1970: 100))
        let mock = WidgetDisplayState.make(snapshot: .notConnected, status: .demoMode, lastSuccessAt: nil, lastAttemptAt: nil, effectiveFiveHourResetAt: nil, savedAt: Date(timeIntervalSince1970: 200))

        WidgetDisplayStateStore.save(real, fileManager: fileManager)
        WidgetDisplayStateStore.save(mock, fileManager: fileManager)

        XCTAssertEqual(WidgetDisplayStateStore.load(fileManager: fileManager).snapshot, realSnapshot)
    }

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

    func testBridgeStartupDeduplicatesInitialSaveAndReload() async {
        let defaults = UserDefaults(suiteName: "CodexMonitorNativeTests.widgetStartupDedup.\(UUID().uuidString)")!
        let store = SnapshotStore(defaults: defaults, key: "snapshot")
        let now = Date()
        let snapshot = QuotaSnapshot(
            weeklyQuotaPercent: 72,
            fiveHourQuotaPercent: 69,
            fiveHourResetAt: now.addingTimeInterval(60 * 60),
            refreshedAt: now,
            dataSource: .real
        )
        store.saveSnapshot(snapshot)

        let appState = AppState(snapshotStore: store, refreshService: WidgetBridgeMockRefreshService(snapshot: snapshot))
        var savedStates: [WidgetDisplayState] = []
        var reloadCount = 0
        let bridge = WidgetTimelineBridge(
            appState: appState,
            saveState: { savedStates.append($0) },
            reloadTimelines: { reloadCount += 1 }
        )

        await Task.yield()
        await Task.yield()

        XCTAssertEqual(savedStates.count, 1)
        XCTAssertEqual(reloadCount, 1)
        XCTAssertEqual(savedStates.last?.snapshot, snapshot)
        XCTAssertEqual(savedStates.last?.status, .success)
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
        var reloadedStates: [WidgetDisplayState] = []
        let finalStateSaved = expectation(description: "Widget bridge saved the final success state")
        let bridge = WidgetTimelineBridge(
            appState: appState,
            saveState: {
                savedStates.append($0)
                if $0.snapshot == refreshed, $0.status == .success {
                    finalStateSaved.fulfill()
                }
            },
            reloadTimelines: {
                if let state = savedStates.last {
                    reloadedStates.append(state)
                }
            }
        )
        savedStates.removeAll()
        reloadedStates.removeAll()

        await appState.refreshNow(trigger: .manual)
        await fulfillment(of: [finalStateSaved], timeout: 1)

        XCTAssertEqual(savedStates.last?.snapshot, refreshed)
        XCTAssertEqual(savedStates.last?.status, .success)
        XCTAssertEqual(savedStates.last?.lastSuccessAt, refreshed.refreshedAt)
        XCTAssertEqual(savedStates.last?.lastAttemptAt, appState.lastAttemptAt)
        XCTAssertEqual(savedStates.last?.effectiveFiveHourResetAt, resetAt)
        XCTAssertEqual(reloadedStates.count, 1)
        XCTAssertEqual(reloadedStates.last?.snapshot, refreshed)
        XCTAssertEqual(reloadedStates.last?.status, .success)
        _ = bridge
    }

    func testManualRefreshWritesResetCreditLineForWidgetWhenDetailsExist() async {
        let defaults = UserDefaults(suiteName: "CodexMonitorNativeTests.widgetResetDetails.\(UUID().uuidString)")!
        let store = SnapshotStore(defaults: defaults, key: "snapshot")
        let now = Date()
        let resetCreditBase = Date(timeIntervalSince1970: 1_720_000_000)
        let initial = QuotaSnapshot(
            weeklyQuotaPercent: 72,
            fiveHourQuotaPercent: 69,
            fiveHourResetAt: now.addingTimeInterval(60 * 60),
            refreshedAt: now.addingTimeInterval(-60),
            dataSource: .real
        )
        store.saveSnapshot(initial)

        let refreshed = QuotaSnapshot(
            weeklyQuotaPercent: 81,
            fiveHourQuotaPercent: 63,
            resetCreditDetailsState: .detailed,
            resetCreditDetails: [
                ResetCreditDetailSnapshot(
                    ordinal: 1,
                    status: "available",
                    grantedAt: resetCreditBase.addingTimeInterval(-4_000),
                    expiresAt: resetCreditBase.addingTimeInterval(12 * 60 * 60 + 5 * 60)
                )
            ],
            fiveHourResetAt: now.addingTimeInterval(2 * 60 * 60),
            refreshedAt: now,
            dataSource: .real
        )
        let appState = AppState(snapshotStore: store, refreshService: WidgetBridgeMockRefreshService(snapshot: refreshed))

        var savedStates: [WidgetDisplayState] = []
        let finalStateSaved = expectation(description: "Widget bridge saved reset credit details")
        let bridge = WidgetTimelineBridge(
            appState: appState,
            saveState: {
                savedStates.append($0)
                if $0.status == .success,
                   $0.snapshot.resetCreditDetailsState == .detailed,
                   !$0.snapshot.resetCreditDetails.isEmpty {
                    finalStateSaved.fulfill()
                }
            },
            reloadTimelines: {}
        )
        savedStates.removeAll()

        await appState.refreshNow(trigger: .manual)
        await fulfillment(of: [finalStateSaved], timeout: 1)

        XCTAssertEqual(
            savedStates.last?.earliestResetCreditLine(
                locale: Locale(identifier: "en_US_POSIX"),
                timeZone: TimeZone(secondsFromGMT: 0)!
            ),
            "最早重置 7/3 21:51"
        )
        XCTAssertNotNil(savedStates.last?.resetCreditFooterLine)
        XCTAssertEqual(savedStates.last?.resetCreditFooterText, savedStates.last?.resetCreditFooterLine)
        _ = bridge
    }

    func testManualRefreshHidesResetCreditLineForWidgetWhenDetailsAreMissing() async {
        let defaults = UserDefaults(suiteName: "CodexMonitorNativeTests.widgetNoResetDetails.\(UUID().uuidString)")!
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

        let refreshed = QuotaSnapshot(
            weeklyQuotaPercent: 81,
            fiveHourQuotaPercent: 63,
            fiveHourResetAt: now.addingTimeInterval(2 * 60 * 60),
            refreshedAt: now,
            dataSource: .real
        )
        let appState = AppState(snapshotStore: store, refreshService: WidgetBridgeMockRefreshService(snapshot: refreshed))

        var savedStates: [WidgetDisplayState] = []
        let finalStateSaved = expectation(description: "Widget bridge saved snapshot without reset credit details")
        let bridge = WidgetTimelineBridge(
            appState: appState,
            saveState: {
                savedStates.append($0)
                if $0.status == .success,
                   $0.snapshot.weeklyQuotaPercent == refreshed.weeklyQuotaPercent,
                   $0.snapshot.resetCreditDetails.isEmpty {
                    finalStateSaved.fulfill()
                }
            },
            reloadTimelines: {}
        )
        savedStates.removeAll()

        await appState.refreshNow(trigger: .manual)
        await fulfillment(of: [finalStateSaved], timeout: 1)

        XCTAssertNil(
            savedStates.last?.earliestResetCreditLine(
                locale: Locale(identifier: "en_US_POSIX"),
                timeZone: TimeZone(secondsFromGMT: 0)!
            )
        )
        XCTAssertNil(savedStates.last?.resetCreditFooterLine)
        XCTAssertNil(savedStates.last?.resetCreditFooterText)
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
        var reloadCount = 0
        let refreshingStateSaved = expectation(description: "Widget bridge saved refreshing state with cached data")
        let finalStateSaved = expectation(description: "Widget bridge saved final success state")
        let bridge = WidgetTimelineBridge(
            appState: appState,
            saveState: {
                savedStates.append($0)
                if $0.snapshot == initial, $0.status == .refreshing, $0.lastAttemptAt != nil {
                    refreshingStateSaved.fulfill()
                }
                if $0.snapshot == refreshed, $0.status == .success {
                    finalStateSaved.fulfill()
                }
            },
            reloadTimelines: { reloadCount += 1 }
        )
        savedStates.removeAll()
        reloadCount = 0

        let refreshTask = Task {
            await appState.refreshNow(trigger: .manual)
        }

        await fulfillment(of: [refreshingStateSaved], timeout: 1)

        XCTAssertEqual(savedStates.last?.snapshot, initial)
        XCTAssertEqual(savedStates.last?.status, .refreshing)
        XCTAssertEqual(savedStates.last?.lastSuccessAt, initial.refreshedAt)
        XCTAssertEqual(savedStates.last?.effectiveFiveHourResetAt, resetAt)
        XCTAssertEqual(reloadCount, 0)

        await service.release()
        await refreshTask.value
        await fulfillment(of: [finalStateSaved], timeout: 1)
        XCTAssertEqual(savedStates.last?.snapshot, refreshed)
        XCTAssertEqual(savedStates.last?.status, .success)
        XCTAssertEqual(reloadCount, 1)
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
        var reloadCount = 0
        let finalStateSaved = expectation(description: "Widget bridge saved cached data with failure status")
        let bridge = WidgetTimelineBridge(
            appState: appState,
            saveState: {
                savedStates.append($0)
                if $0.snapshot == initial, $0.status == .networkFailed {
                    finalStateSaved.fulfill()
                }
            },
            reloadTimelines: { reloadCount += 1 }
        )
        savedStates.removeAll()
        reloadCount = 0

        await appState.refreshNow(trigger: .manual)
        await fulfillment(of: [finalStateSaved], timeout: 1)

        XCTAssertEqual(savedStates.last?.snapshot, initial)
        XCTAssertEqual(savedStates.last?.status, .networkFailed)
        XCTAssertEqual(savedStates.last?.lastSuccessAt, initial.refreshedAt)
        XCTAssertEqual(savedStates.last?.lastAttemptAt, appState.lastAttemptAt)
        XCTAssertEqual(savedStates.last?.effectiveFiveHourResetAt, resetAt)
        XCTAssertEqual(reloadCount, 1)
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

private final class WidgetStateTestFileManager: FileManager {
    private let groupURL: URL

    init(groupURL: URL) {
        self.groupURL = groupURL
        super.init()
    }

    override func containerURL(forSecurityApplicationGroupIdentifier groupIdentifier: String) -> URL? {
        groupURL
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
    private var started: CheckedContinuation<Void, Never>?

    init(snapshot: QuotaSnapshot) {
        self.snapshot = snapshot
    }

    func refresh(basedOn currentSnapshot: QuotaSnapshot) async throws -> QuotaSnapshot {
        started?.resume()
        started = nil
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
        return snapshot
    }

    func waitForStart() async {
        if continuation != nil { return }
        await withCheckedContinuation { started = $0 }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
