import XCTest
import Darwin
@testable import CodexMonitorNative

@_silgen_name("flock")
private func widgetStateTestFlock(_ fileDescriptor: CInt, _ operation: CInt) -> CInt

@MainActor
final class WidgetTimelineBridgeTests: XCTestCase {
    func testAppStateShutdownPublishesOnlySettledFreshCacheStateForWidget() async {
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

        XCTAssertEqual(savedStates.map(\.status), [.success])
        XCTAssertEqual(savedStates.map(\.snapshot), [snapshot])
        XCTAssertEqual(savedStates.last?.snapshot, snapshot)
        XCTAssertEqual(savedStates.last?.status, .success)
        XCTAssertEqual(reloadCount, 1)
        _ = bridge
    }

    func testAppStateShutdownPublishesOnlySettledNoSnapshotStateForWidgetWithoutCache() async {
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

        XCTAssertEqual(savedStates.map(\.status), [.noSnapshot])
        XCTAssertEqual(savedStates.map(\.snapshot), [.notConnected])
        XCTAssertEqual(savedStates.last?.snapshot, .notConnected)
        XCTAssertEqual(savedStates.last?.status, appState.displayStatus)
        XCTAssertNotEqual(savedStates.last?.status, .refreshing)
        XCTAssertEqual(reloadCount, 1)
        _ = bridge
    }

    func testAppStateShutdownPublishesSettledStateAndIsIdempotentForWidget() async {
        let defaults = UserDefaults(suiteName: "CodexMonitorNativeTests.widgetBridgeDeinit.\(UUID().uuidString)")!
        let initial = QuotaSnapshot(weeklyQuotaPercent: 70, fiveHourQuotaPercent: 60, refreshedAt: .now, dataSource: .real)
        let store = SnapshotStore(defaults: defaults, key: "snapshot")
        store.saveSnapshot(initial)
        let service = WidgetBridgeBlockingRefreshService(snapshot: initial)
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

        appState.refresh(trigger: .manual)
        await service.waitForStart()
        for _ in 0..<3 { await Task.yield() }
        XCTAssertTrue(savedStates.isEmpty)

        appState.shutdown()

        XCTAssertEqual(savedStates.map(\.status), [.success])
        XCTAssertNotEqual(savedStates.last?.status, .refreshing)
        XCTAssertEqual(reloadCount, 1)

        let savedCountAfterFirstShutdown = savedStates.count
        appState.shutdown()
        XCTAssertEqual(savedStates.count, savedCountAfterFirstShutdown)
        XCTAssertEqual(reloadCount, 1)
        _ = bridge
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
                now: now,
                locale: Locale(identifier: "en_US_POSIX"),
                timeZone: TimeZone(secondsFromGMT: 0)!
            ),
            "最早重置 7/3 21:51"
        )
        XCTAssertEqual(state.resetCreditFooterText(now: now), state.resetCreditFooterLine)
        XCTAssertEqual(
            state.resetCreditFooterText(now: now),
            state.earliestResetCreditLine(now: now)
        )
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

        XCTAssertEqual(
            decoded.resetCreditFooterLine,
            decoded.earliestResetCreditLine(now: now)
        )
        XCTAssertEqual(decoded.resetCreditFooterText(now: now), decoded.resetCreditFooterLine)
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

    func testWidgetStateDoesNotBypassOrQuarantineUnsupportedEnvelopeThroughLegacyFields() throws {
        let groupURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexMonitorNativeTests.widgetUnsupportedEnvelope.\(UUID().uuidString)", isDirectory: true)
        let fileManager = WidgetStateTestFileManager(groupURL: groupURL)
        let stateURL = WidgetDisplayStateStore.stateURL(fileManager: fileManager)
        let state = WidgetDisplayState.make(
            snapshot: QuotaSnapshot(
                weeklyQuotaPercent: 81,
                fiveHourQuotaPercent: 63,
                refreshedAt: Date(timeIntervalSince1970: 200),
                dataSource: .real,
                accountBoundary: .testDefault
            ),
            status: .success,
            lastSuccessAt: Date(timeIntervalSince1970: 200),
            lastAttemptAt: nil,
            effectiveFiveHourResetAt: nil,
            savedAt: Date(timeIntervalSince1970: 200)
        )
        var object = try JSONSerialization.jsonObject(
            with: legacyCompatibleEnvelopeData(state, revision: 1)
        ) as! [String: Any]
        object["formatVersion"] = PersistenceEnvelope.currentFormatVersion + 1
        let unsupportedData = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try FileManager.default.createDirectory(at: groupURL, withIntermediateDirectories: true)
        try unsupportedData.write(to: stateURL)

        XCTAssertEqual(WidgetDisplayStateStore.load(fileManager: fileManager), .placeholder)
        XCTAssertEqual(try Data(contentsOf: stateURL), unsupportedData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateURL.appendingPathExtension("corrupt").path))
    }

    func testWidgetStateDoesNotBypassChecksumFailureThroughLegacyFields() throws {
        let groupURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexMonitorNativeTests.widgetChecksumEnvelope.\(UUID().uuidString)", isDirectory: true)
        let fileManager = WidgetStateTestFileManager(groupURL: groupURL)
        let stateURL = WidgetDisplayStateStore.stateURL(fileManager: fileManager)
        let state = WidgetDisplayState.make(
            snapshot: .notConnected,
            status: .noSnapshot,
            lastSuccessAt: nil,
            lastAttemptAt: nil,
            effectiveFiveHourResetAt: nil,
            savedAt: Date(timeIntervalSince1970: 200)
        )
        var object = try JSONSerialization.jsonObject(
            with: legacyCompatibleEnvelopeData(state, revision: 1)
        ) as! [String: Any]
        object["checksum"] = "invalid"
        let corruptData = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try FileManager.default.createDirectory(at: groupURL, withIntermediateDirectories: true)
        try corruptData.write(to: stateURL)

        XCTAssertEqual(WidgetDisplayStateStore.load(fileManager: fileManager), .placeholder)
        XCTAssertEqual(try Data(contentsOf: stateURL.appendingPathExtension("corrupt")), corruptData)
    }

    func testWidgetStateRecoversBackupWhenFutureEnvelopeChecksumIsInvalid() throws {
        let groupURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexMonitorNativeTests.widgetCorruptFutureEnvelope.\(UUID().uuidString)", isDirectory: true)
        let fileManager = WidgetStateTestFileManager(groupURL: groupURL)
        let stateURL = WidgetDisplayStateStore.stateURL(fileManager: fileManager)
        let trusted = WidgetDisplayState.make(
            snapshot: QuotaSnapshot(
                weeklyQuotaPercent: 75,
                fiveHourQuotaPercent: 55,
                refreshedAt: Date(timeIntervalSince1970: 100),
                dataSource: .real,
                accountBoundary: .testDefault
            ),
            status: .success,
            lastSuccessAt: Date(timeIntervalSince1970: 100),
            lastAttemptAt: nil,
            effectiveFiveHourResetAt: nil,
            savedAt: Date(timeIntervalSince1970: 100)
        )
        let backupData = try legacyCompatibleEnvelopeData(trusted, revision: 1)
        var corruptObject = try JSONSerialization.jsonObject(
            with: legacyCompatibleEnvelopeData(trusted, revision: 2)
        ) as! [String: Any]
        corruptObject["formatVersion"] = PersistenceEnvelope.currentFormatVersion + 1
        corruptObject["checksum"] = "invalid"
        let corruptData = try JSONSerialization.data(withJSONObject: corruptObject, options: [.sortedKeys])
        try FileManager.default.createDirectory(at: groupURL, withIntermediateDirectories: true)
        try corruptData.write(to: stateURL)
        try backupData.write(to: stateURL.appendingPathExtension("backup"))

        XCTAssertEqual(WidgetDisplayStateStore.load(fileManager: fileManager), trusted)
        XCTAssertEqual(try Data(contentsOf: stateURL), backupData)
        XCTAssertEqual(try Data(contentsOf: stateURL.appendingPathExtension("corrupt")), corruptData)
    }

    func testWidgetStateRecoversAndMigratesLegacyRawBackup() throws {
        let groupURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexMonitorNativeTests.widgetLegacyBackup.\(UUID().uuidString)", isDirectory: true)
        let fileManager = WidgetStateTestFileManager(groupURL: groupURL)
        let stateURL = WidgetDisplayStateStore.stateURL(fileManager: fileManager)
        let state = WidgetDisplayState.make(
            snapshot: QuotaSnapshot(
                weeklyQuotaPercent: 78,
                fiveHourQuotaPercent: 52,
                refreshedAt: Date(timeIntervalSince1970: 100),
                dataSource: .real,
                accountBoundary: .testDefault
            ),
            status: .success,
            lastSuccessAt: Date(timeIntervalSince1970: 100),
            lastAttemptAt: nil,
            effectiveFiveHourResetAt: nil,
            savedAt: Date(timeIntervalSince1970: 100)
        )
        try FileManager.default.createDirectory(at: groupURL, withIntermediateDirectories: true)
        try Data("truncated".utf8).write(to: stateURL)
        try JSONEncoder().encode(state).write(to: stateURL.appendingPathExtension("backup"))

        XCTAssertEqual(WidgetDisplayStateStore.load(fileManager: fileManager), state)
        let migratedData = try Data(contentsOf: stateURL)
        let envelope = try JSONDecoder().decode(PersistenceEnvelope.self, from: migratedData)
        XCTAssertEqual(try envelope.decode(WidgetDisplayState.self), state)
        XCTAssertEqual(try Data(contentsOf: stateURL.appendingPathExtension("corrupt")), Data("truncated".utf8))
    }

    func testWidgetStateUsesBackupWithoutDowngradingFutureSnapshotSchema() throws {
        let groupURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexMonitorNativeTests.widgetFutureSchema.\(UUID().uuidString)", isDirectory: true)
        let fileManager = WidgetStateTestFileManager(groupURL: groupURL)
        let stateURL = WidgetDisplayStateStore.stateURL(fileManager: fileManager)
        let trusted = WidgetDisplayState.make(
            snapshot: QuotaSnapshot(
                weeklyQuotaPercent: 70,
                fiveHourQuotaPercent: 60,
                refreshedAt: Date(timeIntervalSince1970: 100),
                dataSource: .real,
                accountBoundary: .testDefault
            ),
            status: .success,
            lastSuccessAt: Date(timeIntervalSince1970: 100),
            lastAttemptAt: nil,
            effectiveFiveHourResetAt: nil,
            savedAt: Date(timeIntervalSince1970: 100)
        )
        let future = WidgetDisplayState.make(
            snapshot: QuotaSnapshot(
                weeklyQuotaPercent: 90,
                fiveHourQuotaPercent: 80,
                refreshedAt: Date(timeIntervalSince1970: 300),
                dataSource: .real,
                schemaVersion: QuotaSnapshot.currentSchemaVersion + 1,
                accountBoundary: .testDefault
            ),
            status: .success,
            lastSuccessAt: Date(timeIntervalSince1970: 300),
            lastAttemptAt: nil,
            effectiveFiveHourResetAt: nil,
            savedAt: Date(timeIntervalSince1970: 300)
        )
        let futureData = try legacyCompatibleEnvelopeData(future, revision: 2)
        try FileManager.default.createDirectory(at: groupURL, withIntermediateDirectories: true)
        try futureData.write(to: stateURL)

        WidgetDisplayStateStore.save(trusted, fileManager: fileManager)
        XCTAssertEqual(try Data(contentsOf: stateURL), futureData)

        try legacyCompatibleEnvelopeData(trusted, revision: 1)
            .write(to: stateURL.appendingPathExtension("backup"))
        XCTAssertEqual(WidgetDisplayStateStore.load(fileManager: fileManager), trusted)
        XCTAssertEqual(try Data(contentsOf: stateURL), futureData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateURL.appendingPathExtension("corrupt").path))
    }

    func testWidgetStatePreservesRawFutureSnapshotSchemaWhileUsingBackup() throws {
        let groupURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexMonitorNativeTests.widgetRawFutureSchema.\(UUID().uuidString)", isDirectory: true)
        let fileManager = WidgetStateTestFileManager(groupURL: groupURL)
        let stateURL = WidgetDisplayStateStore.stateURL(fileManager: fileManager)
        let trusted = WidgetDisplayState.make(
            snapshot: QuotaSnapshot(weeklyQuotaPercent: 70, fiveHourQuotaPercent: 60, refreshedAt: Date(timeIntervalSince1970: 100), dataSource: .real, accountBoundary: .testDefault),
            status: .success,
            lastSuccessAt: Date(timeIntervalSince1970: 100),
            lastAttemptAt: nil,
            effectiveFiveHourResetAt: nil,
            savedAt: Date(timeIntervalSince1970: 100)
        )
        let future = WidgetDisplayState.make(
            snapshot: QuotaSnapshot(weeklyQuotaPercent: 90, fiveHourQuotaPercent: 80, refreshedAt: Date(timeIntervalSince1970: 300), dataSource: .real, schemaVersion: QuotaSnapshot.currentSchemaVersion + 1, accountBoundary: .testDefault),
            status: .success,
            lastSuccessAt: Date(timeIntervalSince1970: 300),
            lastAttemptAt: nil,
            effectiveFiveHourResetAt: nil,
            savedAt: Date(timeIntervalSince1970: 300)
        )
        let futureData = try JSONEncoder().encode(future)
        try FileManager.default.createDirectory(at: groupURL, withIntermediateDirectories: true)
        try futureData.write(to: stateURL)
        try legacyCompatibleEnvelopeData(trusted, revision: 1)
            .write(to: stateURL.appendingPathExtension("backup"))

        WidgetDisplayStateStore.save(trusted, fileManager: fileManager)
        XCTAssertEqual(try Data(contentsOf: stateURL), futureData)
        XCTAssertEqual(WidgetDisplayStateStore.load(fileManager: fileManager), trusted)
        XCTAssertEqual(try Data(contentsOf: stateURL), futureData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateURL.appendingPathExtension("corrupt").path))
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

    func testWidgetStateSidecarLockMutuallyExcludesIndependentFileDescriptors() throws {
        let groupURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexMonitorNativeTests.widgetFileLock.\(UUID().uuidString)", isDirectory: true)
        let fileManager = WidgetStateTestFileManager(groupURL: groupURL)
        let lockURL = WidgetDisplayStateStore.lockURL(fileManager: fileManager)
        try FileManager.default.createDirectory(at: groupURL, withIntermediateDirectories: true)

        let firstDescriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        let secondDescriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        XCTAssertGreaterThanOrEqual(firstDescriptor, 0)
        XCTAssertGreaterThanOrEqual(secondDescriptor, 0)
        guard firstDescriptor >= 0, secondDescriptor >= 0 else { return }
        defer {
            _ = widgetStateTestFlock(firstDescriptor, LOCK_UN)
            _ = widgetStateTestFlock(secondDescriptor, LOCK_UN)
            Darwin.close(firstDescriptor)
            Darwin.close(secondDescriptor)
        }

        XCTAssertEqual(widgetStateTestFlock(firstDescriptor, LOCK_EX | LOCK_NB), 0)
        errno = 0
        XCTAssertEqual(widgetStateTestFlock(secondDescriptor, LOCK_EX | LOCK_NB), -1)
        XCTAssertTrue(errno == EWOULDBLOCK || errno == EAGAIN)

        XCTAssertEqual(widgetStateTestFlock(firstDescriptor, LOCK_UN), 0)
        XCTAssertEqual(widgetStateTestFlock(secondDescriptor, LOCK_EX | LOCK_NB), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: lockURL.path))
    }

    func testWidgetStateSaveWaitsForSidecarLock() throws {
        let groupURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexMonitorNativeTests.widgetStoreFileLock.\(UUID().uuidString)", isDirectory: true)
        let fileManager = WidgetStateTestFileManager(groupURL: groupURL)
        let lockURL = WidgetDisplayStateStore.lockURL(fileManager: fileManager)
        let stateURL = WidgetDisplayStateStore.stateURL(fileManager: fileManager)
        let state = WidgetDisplayState.make(
            snapshot: .notConnected,
            status: .noSnapshot,
            lastSuccessAt: nil,
            lastAttemptAt: nil,
            effectiveFiveHourResetAt: nil,
            savedAt: Date(timeIntervalSince1970: 200)
        )
        try FileManager.default.createDirectory(at: groupURL, withIntermediateDirectories: true)
        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        guard descriptor >= 0 else { return }
        XCTAssertEqual(widgetStateTestFlock(descriptor, LOCK_EX), 0)

        let context = WidgetStateUncheckedSendableBox((fileManager, state))
        let started = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            started.signal()
            WidgetDisplayStateStore.save(context.value.1, fileManager: context.value.0)
            finished.signal()
        }

        XCTAssertEqual(started.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(finished.wait(timeout: .now() + 0.1), .timedOut)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateURL.path))

        XCTAssertEqual(widgetStateTestFlock(descriptor, LOCK_UN), 0)
        Darwin.close(descriptor)
        XCTAssertEqual(finished.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(WidgetDisplayStateStore.load(fileManager: fileManager), state)
        XCTAssertTrue(FileManager.default.fileExists(atPath: lockURL.path))
    }

    func testWidgetStateRecoveryReadsOnlyAfterSidecarLockAndCannotOverwriteNewerState() throws {
        let groupURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexMonitorNativeTests.widgetRecoveryFileLock.\(UUID().uuidString)", isDirectory: true)
        let fileManager = WidgetStateTestFileManager(groupURL: groupURL)
        let stateURL = WidgetDisplayStateStore.stateURL(fileManager: fileManager)
        let lockURL = WidgetDisplayStateStore.lockURL(fileManager: fileManager)
        let older = WidgetDisplayState.make(
            snapshot: .notConnected,
            status: .noSnapshot,
            lastSuccessAt: nil,
            lastAttemptAt: nil,
            effectiveFiveHourResetAt: nil,
            savedAt: Date(timeIntervalSince1970: 100)
        )
        let newer = WidgetDisplayState.make(
            snapshot: .notConnected,
            status: .authRequired,
            lastSuccessAt: nil,
            lastAttemptAt: Date(timeIntervalSince1970: 200),
            effectiveFiveHourResetAt: nil,
            savedAt: Date(timeIntervalSince1970: 200)
        )
        let newerData = try legacyCompatibleEnvelopeData(newer, revision: 2)
        try FileManager.default.createDirectory(at: groupURL, withIntermediateDirectories: true)
        try Data("truncated".utf8).write(to: stateURL)
        try legacyCompatibleEnvelopeData(older, revision: 1)
            .write(to: stateURL.appendingPathExtension("backup"))

        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        guard descriptor >= 0 else { return }
        XCTAssertEqual(widgetStateTestFlock(descriptor, LOCK_EX), 0)

        let context = WidgetStateUncheckedSendableBox(fileManager)
        let loadedState = WidgetStateLockedValue<WidgetDisplayState?>(nil)
        let started = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            started.signal()
            loadedState.set(WidgetDisplayStateStore.load(fileManager: context.value))
            finished.signal()
        }

        XCTAssertEqual(started.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(finished.wait(timeout: .now() + 0.1), .timedOut)
        try newerData.write(to: stateURL, options: .atomic)

        XCTAssertEqual(widgetStateTestFlock(descriptor, LOCK_UN), 0)
        Darwin.close(descriptor)
        XCTAssertEqual(finished.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(loadedState.get(), newer)
        XCTAssertEqual(try Data(contentsOf: stateURL), newerData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateURL.appendingPathExtension("corrupt").path))
    }

    func testWidgetStateFailsClosedWhenSidecarLockCannotBeOpened() throws {
        let groupURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexMonitorNativeTests.widgetFileLockFailure.\(UUID().uuidString)", isDirectory: true)
        let fileManager = WidgetStateTestFileManager(groupURL: groupURL)
        let stateURL = WidgetDisplayStateStore.stateURL(fileManager: fileManager)
        let lockURL = WidgetDisplayStateStore.lockURL(fileManager: fileManager)
        let original = WidgetDisplayState.make(
            snapshot: .notConnected,
            status: .noSnapshot,
            lastSuccessAt: nil,
            lastAttemptAt: nil,
            effectiveFiveHourResetAt: nil,
            savedAt: Date(timeIntervalSince1970: 100)
        )
        let replacement = WidgetDisplayState.make(
            snapshot: .notConnected,
            status: .authRequired,
            lastSuccessAt: nil,
            lastAttemptAt: Date(timeIntervalSince1970: 200),
            effectiveFiveHourResetAt: nil,
            savedAt: Date(timeIntervalSince1970: 200)
        )
        let originalData = try legacyCompatibleEnvelopeData(original, revision: 1)
        try FileManager.default.createDirectory(at: groupURL, withIntermediateDirectories: true)
        try originalData.write(to: stateURL)
        try FileManager.default.createSymbolicLink(
            at: lockURL,
            withDestinationURL: groupURL.appendingPathComponent("untrusted-lock-target")
        )

        XCTAssertEqual(WidgetDisplayStateStore.load(fileManager: fileManager), .placeholder)
        WidgetDisplayStateStore.save(replacement, fileManager: fileManager)
        XCTAssertEqual(try Data(contentsOf: stateURL), originalData)
    }

    func testRepeatedFailedWidgetStateMovesDoNotAccumulateTemporaryFiles() throws {
        let groupURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexMonitorNativeTests.widgetFailedMove.\(UUID().uuidString)", isDirectory: true)
        let fileManager = FailingMoveWidgetStateTestFileManager(groupURL: groupURL)
        let state = WidgetDisplayState.make(
            snapshot: .notConnected,
            status: .noSnapshot,
            lastSuccessAt: nil,
            lastAttemptAt: nil,
            effectiveFiveHourResetAt: nil,
            savedAt: Date(timeIntervalSince1970: 200)
        )

        for _ in 0..<100 {
            WidgetDisplayStateStore.save(state, fileManager: fileManager)
        }

        let stateURL = WidgetDisplayStateStore.stateURL(fileManager: fileManager)
        let contents = try FileManager.default.contentsOfDirectory(
            at: groupURL,
            includingPropertiesForKeys: nil
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateURL.path))
        XCTAssertFalse(contents.contains { $0.lastPathComponent.contains(".tmp-") })
    }

    func testWidgetStateDoesNotLetOlderRealSnapshotReplaceNewerRealSnapshot() {
        let groupURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexMonitorNativeTests.widgetRealNewest.\(UUID().uuidString)", isDirectory: true)
        let fileManager = WidgetStateTestFileManager(groupURL: groupURL)
        let newerSnapshot = QuotaSnapshot(weeklyQuotaPercent: 90, fiveHourQuotaPercent: 80, refreshedAt: Date(timeIntervalSince1970: 200), dataSource: .real, accountBoundary: .testDefault)
        let olderSnapshot = QuotaSnapshot(weeklyQuotaPercent: 10, fiveHourQuotaPercent: 20, refreshedAt: Date(timeIntervalSince1970: 100), dataSource: .real, accountBoundary: .testDefault)
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
            dataSource: .real,
            accountBoundary: .testDefault
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
        let realSnapshot = QuotaSnapshot(weeklyQuotaPercent: 90, fiveHourQuotaPercent: 80, refreshedAt: Date(timeIntervalSince1970: 100), dataSource: .real, accountBoundary: .testDefault)
        let real = WidgetDisplayState.make(snapshot: realSnapshot, status: .success, lastSuccessAt: realSnapshot.refreshedAt, lastAttemptAt: nil, effectiveFiveHourResetAt: nil, savedAt: Date(timeIntervalSince1970: 100))
        let mock = WidgetDisplayState.make(snapshot: .notConnected, status: .demoMode, lastSuccessAt: nil, lastAttemptAt: nil, effectiveFiveHourResetAt: nil, savedAt: Date(timeIntervalSince1970: 200))

        WidgetDisplayStateStore.save(real, fileManager: fileManager)
        WidgetDisplayStateStore.save(mock, fileManager: fileManager)

        XCTAssertEqual(WidgetDisplayStateStore.load(fileManager: fileManager).snapshot, realSnapshot)
    }

    func testWidgetRejectsLegacyRealSnapshotWithoutAccountBoundary() throws {
        let groupURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexMonitorNativeTests.widgetUnboundReal.\(UUID().uuidString)", isDirectory: true)
        let fileManager = WidgetStateTestFileManager(groupURL: groupURL)
        let stateURL = WidgetDisplayStateStore.stateURL(fileManager: fileManager)
        let unbound = WidgetDisplayState.make(
            snapshot: QuotaSnapshot(
                weeklyQuotaPercent: 90,
                fiveHourQuotaPercent: 80,
                refreshedAt: Date(timeIntervalSince1970: 100),
                dataSource: .real
            ),
            status: .success,
            lastSuccessAt: Date(timeIntervalSince1970: 100),
            lastAttemptAt: nil,
            effectiveFiveHourResetAt: nil,
            savedAt: Date(timeIntervalSince1970: 100)
        )
        let rawData = try JSONEncoder().encode(unbound)
        try FileManager.default.createDirectory(at: groupURL, withIntermediateDirectories: true)
        try rawData.write(to: stateURL)

        XCTAssertEqual(WidgetDisplayStateStore.load(fileManager: fileManager), .placeholder)
        XCTAssertEqual(try Data(contentsOf: stateURL.appendingPathExtension("corrupt")), rawData)
    }

    func testWidgetAccountInvalidationReplacesRealStateAndRemovesRealBackup() {
        let groupURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexMonitorNativeTests.widgetAccountInvalidation.\(UUID().uuidString)", isDirectory: true)
        let fileManager = WidgetStateTestFileManager(groupURL: groupURL)
        let stateURL = WidgetDisplayStateStore.stateURL(fileManager: fileManager)
        let realSnapshot = QuotaSnapshot(
            weeklyQuotaPercent: 90,
            fiveHourQuotaPercent: 80,
            refreshedAt: Date(timeIntervalSince1970: 100),
            dataSource: .real,
            accountBoundary: .testDefault
        )
        let real = WidgetDisplayState.make(
            snapshot: realSnapshot,
            status: .success,
            lastSuccessAt: realSnapshot.refreshedAt,
            lastAttemptAt: nil,
            effectiveFiveHourResetAt: nil,
            savedAt: Date(timeIntervalSince1970: 100)
        )
        let invalidated = WidgetDisplayState.make(
            snapshot: .notConnected,
            status: .authRequired,
            lastSuccessAt: nil,
            lastAttemptAt: Date(timeIntervalSince1970: 200),
            effectiveFiveHourResetAt: nil,
            savedAt: Date(timeIntervalSince1970: 50)
        )

        WidgetDisplayStateStore.save(real, fileManager: fileManager)
        WidgetDisplayStateStore.save(real, fileManager: fileManager)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stateURL.appendingPathExtension("backup").path))

        WidgetDisplayStateStore.save(invalidated, fileManager: fileManager)

        XCTAssertEqual(WidgetDisplayStateStore.load(fileManager: fileManager), invalidated)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateURL.appendingPathExtension("backup").path))
    }

    func testWidgetAcceptsOlderTimestampFromDifferentVerifiedAccount() {
        let groupURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexMonitorNativeTests.widgetAccountSwitch.\(UUID().uuidString)", isDirectory: true)
        let fileManager = WidgetStateTestFileManager(groupURL: groupURL)
        let oldAccount = QuotaSnapshot(
            weeklyQuotaPercent: 90,
            fiveHourQuotaPercent: 80,
            refreshedAt: Date(timeIntervalSince1970: 200),
            dataSource: .real,
            accountBoundary: .testDefault
        )
        let newAccount = QuotaSnapshot(
            weeklyQuotaPercent: 20,
            fiveHourQuotaPercent: 30,
            refreshedAt: Date(timeIntervalSince1970: 100),
            dataSource: .real,
            accountBoundary: .testOtherAccount
        )

        let oldState = WidgetDisplayState.make(snapshot: oldAccount, status: .success, lastSuccessAt: oldAccount.refreshedAt, lastAttemptAt: nil, effectiveFiveHourResetAt: nil, savedAt: Date(timeIntervalSince1970: 100))
        WidgetDisplayStateStore.save(oldState, fileManager: fileManager)
        WidgetDisplayStateStore.save(oldState, fileManager: fileManager)
        let backupURL = WidgetDisplayStateStore.stateURL(fileManager: fileManager)
            .appendingPathExtension("backup")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path))

        WidgetDisplayStateStore.save(
            WidgetDisplayState.make(snapshot: newAccount, status: .success, lastSuccessAt: newAccount.refreshedAt, lastAttemptAt: nil, effectiveFiveHourResetAt: nil, savedAt: Date(timeIntervalSince1970: 50)),
            fileManager: fileManager
        )

        XCTAssertEqual(WidgetDisplayStateStore.load(fileManager: fileManager).snapshot, newAccount)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backupURL.path))
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

    func testTemporalReconciliationReloadsEquivalentWidgetStateWithoutRewritingIt() {
        let defaults = UserDefaults(suiteName: "CodexMonitorNativeTests.widgetTemporalReload.\(UUID().uuidString)")!
        let store = SnapshotStore(defaults: defaults, key: "snapshot")
        let now = Date(timeIntervalSince1970: 1_720_000_000)
        let snapshot = QuotaSnapshot(
            weeklyQuotaPercent: 72,
            fiveHourQuotaPercent: 69,
            refreshedAt: now,
            dataSource: .real
        )
        store.saveSnapshot(snapshot)
        let appState = AppState(
            snapshotStore: store,
            refreshService: WidgetBridgeMockRefreshService(snapshot: snapshot),
            now: { now }
        )
        var savedStates: [WidgetDisplayState] = []
        var reloadCount = 0
        let bridge = WidgetTimelineBridge(
            appState: appState,
            saveState: { savedStates.append($0) },
            reloadTimelines: { reloadCount += 1 }
        )
        savedStates.removeAll()
        reloadCount = 0

        appState.reconcileTemporalState()

        XCTAssertTrue(savedStates.isEmpty)
        XCTAssertEqual(reloadCount, 1)
        _ = bridge
    }

    func testStopCancelsSubscriptionAndIgnoresLateRefreshAndTemporalEvents() async {
        let defaults = UserDefaults(suiteName: "CodexMonitorNativeTests.widgetBridgeStop.\(UUID().uuidString)")!
        let initial = QuotaSnapshot(
            weeklyQuotaPercent: 72,
            fiveHourQuotaPercent: 69,
            refreshedAt: .now,
            dataSource: .real
        )
        let store = SnapshotStore(defaults: defaults, key: "snapshot")
        store.saveSnapshot(initial)
        let refreshed = QuotaSnapshot(
            weeklyQuotaPercent: 81,
            fiveHourQuotaPercent: 63,
            refreshedAt: .now,
            dataSource: .real
        )
        let appState = AppState(
            snapshotStore: store,
            refreshService: WidgetBridgeMockRefreshService(snapshot: refreshed)
        )
        var savedStates: [WidgetDisplayState] = []
        var reloadCount = 0
        let bridge = WidgetTimelineBridge(
            appState: appState,
            saveState: { savedStates.append($0) },
            reloadTimelines: { reloadCount += 1 }
        )
        savedStates.removeAll()
        reloadCount = 0

        bridge.stop()
        bridge.stop()
        appState.reconcileTemporalState()
        await appState.refreshNow(trigger: .manual)

        XCTAssertTrue(savedStates.isEmpty)
        XCTAssertEqual(reloadCount, 0)
        appState.shutdown()
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
        let now = Date(timeIntervalSince1970: 1_720_000_000)
        let resetCreditBase = now
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
        let appState = AppState(
            snapshotStore: store,
            refreshService: WidgetBridgeMockRefreshService(snapshot: refreshed),
            now: { now }
        )

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
                now: now,
                locale: Locale(identifier: "en_US_POSIX"),
                timeZone: TimeZone(secondsFromGMT: 0)!
            ),
            "最早重置 7/3 21:51"
        )
        XCTAssertNotNil(savedStates.last?.resetCreditFooterLine)
        XCTAssertEqual(
            savedStates.last?.resetCreditFooterText(now: now),
            savedStates.last?.resetCreditFooterLine
        )
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

    func testRefreshInProgressKeepsSettledWidgetFileUntilFinalState() async {
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
        let finalStateSaved = expectation(description: "Widget bridge saved final success state")
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
        savedStates.removeAll()
        reloadCount = 0

        let refreshTask = Task {
            await appState.refreshNow(trigger: .manual)
        }

        await service.waitForStart()
        XCTAssertTrue(savedStates.isEmpty)
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

private final class FailingMoveWidgetStateTestFileManager: FileManager {
    private let groupURL: URL

    init(groupURL: URL) {
        self.groupURL = groupURL
        super.init()
    }

    override func containerURL(forSecurityApplicationGroupIdentifier groupIdentifier: String) -> URL? {
        groupURL
    }

    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        if srcURL.lastPathComponent.contains(".tmp-") {
            throw CocoaError(.fileWriteUnknown)
        }
        try super.moveItem(at: srcURL, to: dstURL)
    }
}

private final class WidgetStateUncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}

private final class WidgetStateLockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func set(_ value: Value) {
        lock.lock()
        defer { lock.unlock() }
        self.value = value
    }

    func get() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private func legacyCompatibleEnvelopeData(
    _ state: WidgetDisplayState,
    revision: UInt64
) throws -> Data {
    let encoder = JSONEncoder()
    let envelope = try PersistenceEnvelope(value: state, revision: revision)
    var envelopeObject = try JSONSerialization.jsonObject(with: encoder.encode(envelope)) as! [String: Any]
    let legacyObject = try JSONSerialization.jsonObject(with: encoder.encode(state)) as! [String: Any]
    for (key, value) in legacyObject {
        envelopeObject[key] = value
    }
    return try JSONSerialization.data(withJSONObject: envelopeObject, options: [.sortedKeys])
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
