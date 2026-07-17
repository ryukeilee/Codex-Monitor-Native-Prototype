import XCTest
@testable import CodexMonitorNative

final class StatusPopoverFormattingTests: XCTestCase {
    func testShortTimestampUsesTodayPrefixForSameDay() {
        let calendar = Calendar(identifier: .gregorian)
        let timeZone = TimeZone(secondsFromGMT: 0)!
        let locale = Locale(identifier: "en_US")
        let now = makeDate("2026-06-19T12:40:00Z")
        let date = makeDate("2026-06-19T08:05:00Z")

        let formatted = StatusPopoverFormatting.shortTimestamp(
            for: date,
            now: now,
            calendar: calendar.setting(timeZone: timeZone),
            locale: locale,
            timeZone: timeZone
        )

        XCTAssertEqual(formatted, "今天 08:05")
    }

    func testShortTimestampUsesMonthDayForOtherDays() {
        let calendar = Calendar(identifier: .gregorian)
        let timeZone = TimeZone(secondsFromGMT: 0)!
        let locale = Locale(identifier: "en_US")
        let now = makeDate("2026-06-19T12:40:00Z")
        let date = makeDate("2026-05-02T08:05:00Z")

        let formatted = StatusPopoverFormatting.shortTimestamp(
            for: date,
            now: now,
            calendar: calendar.setting(timeZone: timeZone),
            locale: locale,
            timeZone: timeZone
        )

        XCTAssertEqual(formatted, "5月2日 08:05")
    }

    func testUpdatedLineCollapsesMatchingTimes() {
        let calendar = Calendar(identifier: .gregorian)
        let timeZone = TimeZone(secondsFromGMT: 0)!
        let locale = Locale(identifier: "en_US")
        let date = makeDate("2026-06-19T12:40:00Z")

        let formatted = StatusPopoverFormatting.updatedLine(
            lastSuccess: date,
            lastAttempt: date,
            now: date,
            calendar: calendar.setting(timeZone: timeZone),
            locale: locale,
            timeZone: timeZone
        )

        XCTAssertEqual(formatted, "更新 今天 12:40")
    }

    func testUpdatedLineKeepsAttemptWhenDifferentFromSuccess() {
        let calendar = Calendar(identifier: .gregorian)
        let timeZone = TimeZone(secondsFromGMT: 0)!
        let locale = Locale(identifier: "en_US")
        let now = makeDate("2026-06-19T12:50:00Z")
        let lastSuccess = makeDate("2026-06-19T12:40:00Z")
        let lastAttempt = makeDate("2026-06-19T12:48:00Z")

        let formatted = StatusPopoverFormatting.updatedLine(
            lastSuccess: lastSuccess,
            lastAttempt: lastAttempt,
            now: now,
            calendar: calendar.setting(timeZone: timeZone),
            locale: locale,
            timeZone: timeZone
        )

        XCTAssertEqual(formatted, "更新 今天 12:40 · 尝试 今天 12:48")
    }

    func testSourceStatusLineUsesCompactPrimaryCopy() {
        XCTAssertEqual(
            StatusPopoverFormatting.sourceStatusLine(dataSource: .real, status: .success),
            "真实数据 · 最新"
        )
        XCTAssertEqual(
            StatusPopoverFormatting.sourceStatusLine(dataSource: .real, status: .stale),
            "真实数据 · 已过期"
        )
        XCTAssertEqual(
            StatusPopoverFormatting.sourceStatusLine(dataSource: .mock, status: .demoMode),
            "演示数据 · 演示模式"
        )
    }

    func testSourceStatusLineDistinguishesFailureStates() {
        XCTAssertEqual(
            StatusPopoverFormatting.sourceStatusLine(dataSource: .real, status: .networkFailed),
            "真实数据 · 网络异常"
        )
        XCTAssertEqual(
            StatusPopoverFormatting.sourceStatusLine(dataSource: .real, status: .authRequired),
            "真实数据 · 需要登录"
        )
        XCTAssertEqual(
            StatusPopoverFormatting.sourceStatusLine(dataSource: .real, status: .parseFailed),
            "真实数据 · 数据异常"
        )
    }

    func testCredibilityLineCombinesUpdateSourceAndStatus() {
        let calendar = Calendar(identifier: .gregorian)
        let timeZone = TimeZone(secondsFromGMT: 0)!
        let locale = Locale(identifier: "en_US")
        let now = makeDate("2026-06-19T12:50:00Z")
        let lastSuccess = makeDate("2026-06-19T12:40:00Z")
        let lastAttempt = makeDate("2026-06-19T12:48:00Z")

        let formatted = StatusPopoverFormatting.credibilityLine(
            lastSuccess: lastSuccess,
            lastAttempt: lastAttempt,
            dataSource: .real,
            status: .success,
            now: now,
            calendar: calendar.setting(timeZone: timeZone),
            locale: locale,
            timeZone: timeZone
        )

        XCTAssertEqual(formatted, "更新 今天 12:40 · 尝试 今天 12:48 · 真实数据 · 最新")
    }

    func testEnvironmentInfoLineKeepsSourceStatusWhenAvailable() {
        let calendar = Calendar(identifier: .gregorian)
        let timeZone = TimeZone(secondsFromGMT: 0)!
        let locale = Locale(identifier: "en_US")
        let now = makeDate("2026-06-19T12:50:00Z")
        let lastSuccess = makeDate("2026-06-19T12:40:00Z")

        let formatted = StatusPopoverFormatting.environmentInfoLine(
            lastSuccess: lastSuccess,
            lastAttempt: nil,
            dataSource: .real,
            status: .success,
            showsSourceStatus: true,
            now: now,
            calendar: calendar.setting(timeZone: timeZone),
            locale: locale,
            timeZone: timeZone
        )

        XCTAssertEqual(formatted, "更新 今天 12:40 · 真实数据 · 最新")
    }

    func testEnvironmentInfoLineHidesEmptySourceState() {
        let formatted = StatusPopoverFormatting.environmentInfoLine(
            lastSuccess: nil,
            lastAttempt: nil,
            dataSource: .mock,
            status: .noSnapshot,
            showsSourceStatus: false
        )

        XCTAssertNil(formatted)
    }

    func testEnvironmentInfoLineKeepsUpdateWithoutEmptySourceState() {
        let calendar = Calendar(identifier: .gregorian)
        let timeZone = TimeZone(secondsFromGMT: 0)!
        let locale = Locale(identifier: "en_US")
        let now = makeDate("2026-06-19T12:50:00Z")
        let lastAttempt = makeDate("2026-06-19T12:48:00Z")

        let formatted = StatusPopoverFormatting.environmentInfoLine(
            lastSuccess: nil,
            lastAttempt: lastAttempt,
            dataSource: .mock,
            status: .networkFailed,
            showsSourceStatus: false,
            now: now,
            calendar: calendar.setting(timeZone: timeZone),
            locale: locale,
            timeZone: timeZone
        )

        XCTAssertEqual(formatted, "更新 今天 12:48")
    }

    func testRealQuotaHealthLineShowsSuccess() {
        let formatted = StatusPopoverFormatting.realQuotaHealthLine(
            RealQuotaHealthDiagnostic(kind: .requestSucceeded, isUsingCachedSnapshot: false)
        )

        XCTAssertEqual(formatted, "真实链路：Codex 可用，请求成功")
    }

    func testRealQuotaHealthLineShowsLoginFailureWithCachedSnapshot() {
        let formatted = StatusPopoverFormatting.realQuotaHealthLine(
            RealQuotaHealthDiagnostic(kind: .loginRequired, isUsingCachedSnapshot: true)
        )

        XCTAssertEqual(formatted, "真实链路：需要登录，显示上次成功数据")
    }

    func testRealQuotaHealthLineShowsParseFailureWithoutCachedSnapshot() {
        let formatted = StatusPopoverFormatting.realQuotaHealthLine(
            RealQuotaHealthDiagnostic(kind: .responseInvalid, isUsingCachedSnapshot: false)
        )

        XCTAssertEqual(formatted, "真实链路：响应不可解析，当前无可用快照")
    }

    func testTitleSummaryMatchesStatusState() {
        XCTAssertEqual(StatusPopoverFormatting.titleSummary(for: .success), "最新数据")
        XCTAssertEqual(StatusPopoverFormatting.titleSummary(for: .refreshing), "读取中")
        XCTAssertEqual(StatusPopoverFormatting.titleSummary(for: .stale), "使用上次数据")
        XCTAssertEqual(StatusPopoverFormatting.titleSummary(for: .networkFailed), "网络异常")
    }

    func testFreshnessTitleDistinguishesPrimaryDataStates() {
        XCTAssertEqual(
            StatusPopoverFormatting.freshnessTitle(for: .success, isUsingCachedSnapshot: false),
            "最新数据"
        )
        XCTAssertEqual(
            StatusPopoverFormatting.freshnessTitle(for: .refreshing, isUsingCachedSnapshot: true),
            "读取中"
        )
        XCTAssertEqual(
            StatusPopoverFormatting.freshnessTitle(for: .stale, isUsingCachedSnapshot: true),
            "使用上次数据"
        )
        XCTAssertEqual(
            StatusPopoverFormatting.freshnessTitle(for: .networkFailed, isUsingCachedSnapshot: true),
            "使用上次数据"
        )
        XCTAssertEqual(
            StatusPopoverFormatting.freshnessTitle(for: .networkFailed, isUsingCachedSnapshot: false),
            "读取失败"
        )
    }

    func testFreshnessSummaryDoesNotClaimCachedDataWhenNoneExists() {
        XCTAssertEqual(
            StatusPopoverFormatting.freshnessSummary(for: .networkFailed, isUsingCachedSnapshot: false),
            "读取失败，无可用快照"
        )
        XCTAssertEqual(
            StatusPopoverFormatting.freshnessSummary(for: .networkFailed, isUsingCachedSnapshot: true),
            "读取失败，显示上次快照"
        )
    }

    func testRelativeRecoveryLineShowsRemainingDuration() {
        let now = makeDate("2026-06-19T12:40:00Z")
        let resetAt = makeDate("2026-06-19T14:10:00Z")

        let formatted = StatusPopoverFormatting.relativeRecoveryLine(for: resetAt, now: now)

        XCTAssertEqual(formatted, "1小时30分")
    }

    func testRelativeRecoveryLineShowsRecoveredWhenDeadlinePassed() {
        let now = makeDate("2026-06-19T12:40:00Z")
        let resetAt = makeDate("2026-06-19T12:35:00Z")

        let formatted = StatusPopoverFormatting.relativeRecoveryLine(for: resetAt, now: now)

        XCTAssertEqual(formatted, "已恢复")
    }

    func testQuotaSummaryLineUsesRealSnapshotForFailureStates() {
        let snapshot = QuotaSnapshot(
            weeklyQuotaPercent: 71,
            fiveHourQuotaPercent: 64,
            refreshedAt: .now,
            dataSource: .real
        )

        let formatted = StatusPopoverFormatting.quotaSummaryLine(
            snapshot: snapshot,
            status: .networkFailed
        )

        XCTAssertEqual(formatted, "5小时额度 64% · 周额度 71%")
    }

    func testQuotaValueTextHidesInvalidAndHistoricalFields() {
        let snapshot = QuotaSnapshot(
            weeklyQuotaPercent: 71,
            fiveHourQuotaPercent: 64,
            weeklyQuotaState: .cached,
            fiveHourQuotaState: .invalid,
            refreshedAt: .now,
            dataSource: .real
        )

        XCTAssertEqual(
            StatusPopoverFormatting.quotaValueText(for: .fiveHour, snapshot: snapshot, status: .success),
            "--"
        )
        XCTAssertEqual(
            StatusPopoverFormatting.quotaValueText(for: .weekly, snapshot: snapshot, status: .success),
            "--"
        )
        XCTAssertEqual(
            StatusPopoverFormatting.quotaSummaryLine(snapshot: snapshot, status: .success),
            "额度 --"
        )
    }

    func testQuotaValueDisplayDoesNotExposeHistoricalCache() {
        let snapshot = QuotaSnapshot(
            weeklyQuotaPercent: 71,
            fiveHourQuotaPercent: 64,
            weeklyQuotaState: .cached,
            refreshedAt: .now,
            dataSource: .real
        )

        let display = StatusPopoverFormatting.quotaValueDisplay(
            for: .weekly,
            snapshot: snapshot,
            status: .success
        )

        XCTAssertEqual(display.percentText, "--")
        XCTAssertNil(display.historyCaption)
        XCTAssertEqual(display.combinedText, "--")
    }

    func testQuotaSummaryLineIncludesMonthlyAndHidesUnknownWindows() {
        let snapshot = QuotaSnapshot(
            weeklyQuotaPercent: 70,
            fiveHourQuotaPercent: 80,
            refreshedAt: .now,
            dataSource: .real,
            quotaWindows: [
                QuotaWindow(limitId: "codex", windowId: "primary", kind: .fiveHour, durationMinutes: 300, remainingPercent: 80),
                QuotaWindow(limitId: "codex", windowId: "secondary", kind: .weekly, durationMinutes: 10080, remainingPercent: 70),
                QuotaWindow(limitId: "codex", windowId: "monthly", kind: .monthly, durationMinutes: 43200, remainingPercent: 55),
                QuotaWindow(limitId: "codex", windowId: "future", kind: .unknown, durationMinutes: 1234, remainingPercent: 90)
            ]
        )

        let summary = StatusPopoverFormatting.quotaSummaryLine(snapshot: snapshot, status: .success)

        XCTAssertTrue(summary.contains("月额度 55%"))
        XCTAssertFalse(summary.contains("未知额度"))
    }

    func testWeeklyDisplayDoesNotFallBackToHistoricalLegacyCache() {
        let snapshot = QuotaSnapshot(
            weeklyQuotaPercent: 72,
            fiveHourQuotaPercent: 0,
            weeklyQuotaState: .cached,
            fiveHourQuotaState: .unavailable,
            refreshedAt: .now,
            dataSource: .real,
            quotaWindows: [
                QuotaWindow(
                    limitId: "codex",
                    windowId: "primary",
                    kind: .unknown,
                    durationMinutes: nil,
                    remainingPercent: 0,
                    state: .invalid
                )
            ]
        )

        let display = StatusPopoverFormatting.quotaValueDisplay(
            for: .weekly,
            snapshot: snapshot,
            status: .networkFailed
        )

        XCTAssertEqual(display.percentText, "--")
        XCTAssertNil(display.historyCaption)
    }

    func testQuotaProjectionSortsKnownSemanticKindsAndHidesUnknownWindows() {
        let snapshot = QuotaSnapshot(
            weeklyQuotaPercent: 0,
            fiveHourQuotaPercent: 0,
            weeklyQuotaState: .unavailable,
            fiveHourQuotaState: .unavailable,
            refreshedAt: .now,
            dataSource: .real,
            quotaWindows: [
                QuotaWindow(limitId: "zeta", windowId: "future", kind: .unknown, remainingPercent: 44),
                QuotaWindow(limitId: "codex", windowId: "monthly", kind: .monthly, durationMinutes: 43_200, remainingPercent: 55),
                QuotaWindow(limitId: "alpha", windowId: "short", kind: .unknown, durationMinutes: 90, remainingPercent: 66),
                QuotaWindow(limitId: "codex", windowId: "secondary", kind: .weekly, durationMinutes: 10_080, remainingPercent: 70),
                QuotaWindow(limitId: "codex", windowId: "primary", kind: .fiveHour, durationMinutes: 300, remainingPercent: 80)
            ]
        )

        let items = StatusPopoverFormatting.quotaWindowDisplayItems(snapshot: snapshot, status: .success)

        XCTAssertEqual(items.map(\.kind), [.fiveHour, .weekly, .monthly])
        XCTAssertEqual(items.map(\.id), [
            "codex.primary",
            "codex.secondary",
            "codex.monthly"
        ])
        XCTAssertTrue(items.allSatisfy { $0.label.count <= 18 })
    }

    func testQuotaProjectionKeepsOnlyCurrentTrustedItemWithResetMetadata() {
        let now = makeDate("2026-06-19T12:40:00Z")
        let resetAt = makeDate("2026-06-19T14:10:00Z")
        let snapshot = QuotaSnapshot(
            weeklyQuotaPercent: 0,
            fiveHourQuotaPercent: 0,
            weeklyQuotaState: .unavailable,
            fiveHourQuotaState: .unavailable,
            refreshedAt: now,
            dataSource: .real,
            quotaWindows: [
                QuotaWindow(
                    limitId: "codex",
                    windowId: "monthly",
                    kind: .monthly,
                    durationMinutes: 43_200,
                    remainingPercent: 55,
                    state: .live,
                    resetAt: resetAt
                ),
                QuotaWindow(
                    limitId: "future",
                    windowId: "invalid",
                    kind: .unknown,
                    durationMinutes: 720,
                    remainingPercent: 91,
                    state: .invalid,
                    resetAt: resetAt
                )
            ]
        )

        let items = StatusPopoverFormatting.quotaWindowDisplayItems(
            snapshot: snapshot,
            status: .success,
            now: now,
            calendar: Calendar(identifier: .gregorian).setting(timeZone: TimeZone(secondsFromGMT: 0)!),
            locale: Locale(identifier: "en_US"),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        XCTAssertEqual(items[0].trustedPercent, 55)
        XCTAssertEqual(items[0].progress, 0.55)
        XCTAssertEqual(items[0].percentText, "55%")
        XCTAssertNil(items[0].historyCaption)
        XCTAssertEqual(items[0].stateText, "最新")
        XCTAssertEqual(items[0].resetAt, resetAt)
        XCTAssertEqual(items[0].resetText, "今天 14:10")
        XCTAssertEqual(items[0].resetRemainingText, "1小时30分")
        XCTAssertEqual(items.count, 1)
    }

    func testQuotaProjectionUsesOnlyCurrentLegacyFallbackWhenSemanticWindowIsMissing() {
        let unknown = QuotaWindow(
            limitId: "future",
            windowId: "primary",
            kind: .unknown,
            durationMinutes: 600,
            remainingPercent: 42
        )
        let fallbackSnapshot = QuotaSnapshot(
            weeklyQuotaPercent: 72,
            fiveHourQuotaPercent: 0,
            weeklyQuotaState: .live,
            fiveHourQuotaState: .unavailable,
            refreshedAt: .now,
            dataSource: .real,
            quotaWindows: [unknown]
        )

        let fallbackItems = StatusPopoverFormatting.quotaWindowDisplayItems(
            snapshot: fallbackSnapshot,
            status: .success
        )

        XCTAssertEqual(fallbackItems.map(\.kind), [.weekly])
        XCTAssertEqual(fallbackItems[0].id, "legacy.weekly")
        XCTAssertEqual(fallbackItems[0].origin, .legacyFallback)
        XCTAssertEqual(fallbackItems[0].trustedPercent, 72)
        XCTAssertNil(fallbackItems[0].historyCaption)

        let dynamicUnavailable = QuotaSnapshot(
            weeklyQuotaPercent: 72,
            fiveHourQuotaPercent: 0,
            weeklyQuotaState: .cached,
            fiveHourQuotaState: .unavailable,
            refreshedAt: .now,
            dataSource: .real,
            quotaWindows: [
                QuotaWindow(
                    limitId: "codex",
                    windowId: "secondary",
                    kind: .weekly,
                    durationMinutes: 10_080,
                    remainingPercent: 0,
                    state: .invalid
                )
            ]
        )
        let unavailableItems = StatusPopoverFormatting.quotaWindowDisplayItems(
            snapshot: dynamicUnavailable,
            status: .success
        )

        XCTAssertTrue(unavailableItems.isEmpty)
    }

    func testQuotaProjectionDropsCachedAndInvalidWindowsAndDeduplicatesKnownKinds() {
        let snapshot = QuotaSnapshot(
            weeklyQuotaPercent: 44,
            fiveHourQuotaPercent: 99,
            weeklyQuotaState: .live,
            fiveHourQuotaState: .cached,
            refreshedAt: .now,
            dataSource: .real,
            quotaWindows: [
                QuotaWindow(limitId: "codex", windowId: "primary", kind: .fiveHour, remainingPercent: 99, state: .cached),
                QuotaWindow(limitId: "codex", windowId: "secondary", kind: .weekly, remainingPercent: 44),
                QuotaWindow(limitId: "codex_other", windowId: "primary", kind: .weekly, remainingPercent: 100),
                QuotaWindow(limitId: "future", windowId: "unknown", kind: .unknown, remainingPercent: 0, state: .invalid)
            ]
        )

        let items = StatusPopoverFormatting.quotaWindowDisplayItems(snapshot: snapshot, status: .success)

        XCTAssertEqual(items.map(\.id), ["codex.secondary"])
        XCTAssertEqual(items.map(\.label), ["周额度"])
        XCTAssertEqual(items.map(\.percentText), ["44%"])
    }

    func testPopoverProjectionCoversOnlyWeeklyHidesOnlyUnknownAndShowsKnownTriple() {
        let weeklyOnly = QuotaSnapshot(
            weeklyQuotaPercent: 0,
            fiveHourQuotaPercent: 0,
            weeklyQuotaState: .unavailable,
            fiveHourQuotaState: .unavailable,
            refreshedAt: .now,
            dataSource: .real,
            quotaWindows: [
                QuotaWindow(limitId: "codex", windowId: "secondary", kind: .weekly, remainingPercent: 62)
            ]
        )
        let unknownOnly = QuotaSnapshot(
            weeklyQuotaPercent: 0,
            fiveHourQuotaPercent: 0,
            weeklyQuotaState: .unavailable,
            fiveHourQuotaState: .unavailable,
            refreshedAt: .now,
            dataSource: .real,
            quotaWindows: [
                QuotaWindow(limitId: "future", windowId: "bank", kind: .unknown, durationMinutes: 720, remainingPercent: 73)
            ]
        )
        let knownTriple = QuotaSnapshot(
            weeklyQuotaPercent: 0,
            fiveHourQuotaPercent: 0,
            weeklyQuotaState: .unavailable,
            fiveHourQuotaState: .unavailable,
            refreshedAt: .now,
            dataSource: .real,
            quotaWindows: [
                QuotaWindow(limitId: "codex", windowId: "monthly", kind: .monthly, remainingPercent: 51),
                QuotaWindow(limitId: "codex", windowId: "primary", kind: .fiveHour, remainingPercent: 81),
                QuotaWindow(limitId: "codex", windowId: "secondary", kind: .weekly, remainingPercent: 61)
            ]
        )

        XCTAssertEqual(
            StatusPopoverFormatting.quotaWindowDisplayItems(snapshot: weeklyOnly, status: .success).map(\.kind),
            [.weekly]
        )
        XCTAssertEqual(
            StatusPopoverFormatting.quotaWindowDisplayItems(snapshot: unknownOnly, status: .success).map(\.kind),
            []
        )
        XCTAssertEqual(
            StatusPopoverFormatting.quotaWindowDisplayItems(snapshot: knownTriple, status: .success).map(\.kind),
            [.fiveHour, .weekly, .monthly]
        )
    }

    func testPopoverLayoutSignalCountsOnlyKnownCurrentWindows() {
        let fourWindows = [
            QuotaWindow(limitId: "codex", windowId: "primary", kind: .fiveHour, remainingPercent: 80),
            QuotaWindow(limitId: "codex", windowId: "secondary", kind: .weekly, remainingPercent: 70),
            QuotaWindow(limitId: "codex", windowId: "monthly", kind: .monthly, remainingPercent: 60),
            QuotaWindow(limitId: "future", windowId: "a", kind: .unknown, durationMinutes: 600, remainingPercent: 50)
        ]
        let makeSnapshot: ([QuotaWindow]) -> QuotaSnapshot = { windows in
            QuotaSnapshot(
                weeklyQuotaPercent: 0,
                fiveHourQuotaPercent: 0,
                weeklyQuotaState: .unavailable,
                fiveHourQuotaState: .unavailable,
                refreshedAt: .now,
                dataSource: .real,
                quotaWindows: windows
            )
        }
        let compact = StatusPopoverFormatting.quotaWindowLayoutSignal(
            snapshot: makeSnapshot(fourWindows),
            status: .success
        )
        let expanded = StatusPopoverFormatting.quotaWindowLayoutSignal(
            snapshot: makeSnapshot(fourWindows + [
                QuotaWindow(limitId: "future", windowId: "b", kind: .unknown, durationMinutes: 720, remainingPercent: 40)
            ]),
            status: .success
        )

        XCTAssertEqual(compact.rowCount, 2)
        XCTAssertFalse(compact.requiresScrolling)
        XCTAssertEqual(expanded.rowCount, 2)
        XCTAssertFalse(expanded.requiresScrolling)
        XCTAssertEqual(compact, expanded)
        XCTAssertEqual(expanded.itemTokens.count, 3)
    }

    func testWeeklyMenuTitleNeverSubstitutesMonthlyOrUnknownWindow() {
        let makeSnapshot: (QuotaWindow) -> QuotaSnapshot = { window in
            QuotaSnapshot(
                weeklyQuotaPercent: 0,
                fiveHourQuotaPercent: 0,
                weeklyQuotaState: .unavailable,
                fiveHourQuotaState: .unavailable,
                refreshedAt: .now,
                dataSource: .real,
                quotaWindows: [window]
            )
        }

        XCTAssertEqual(
            StatusPopoverFormatting.weeklyQuotaMenuTitle(
                snapshot: makeSnapshot(QuotaWindow(limitId: "codex", windowId: "monthly", kind: .monthly, remainingPercent: 88)),
                status: .success
            ),
            "--%"
        )
        XCTAssertEqual(
            StatusPopoverFormatting.weeklyQuotaMenuTitle(
                snapshot: makeSnapshot(QuotaWindow(limitId: "future", windowId: "bank", kind: .unknown, remainingPercent: 77)),
                status: .success
            ),
            "--%"
        )
        XCTAssertEqual(
            StatusPopoverFormatting.weeklyQuotaMenuTitle(
                snapshot: makeSnapshot(QuotaWindow(limitId: "codex", windowId: "secondary", kind: .weekly, remainingPercent: 66)),
                status: .success
            ),
            "66%"
        )
    }

    func testDemoProjectionNeverExposesMockPercentAsTrusted() {
        let snapshot = QuotaSnapshot(
            weeklyQuotaPercent: 0,
            fiveHourQuotaPercent: 0,
            refreshedAt: .now,
            dataSource: .mock,
            quotaWindows: [
                QuotaWindow(limitId: "demo", windowId: "monthly", kind: .monthly, remainingPercent: 99)
            ]
        )

        let items = StatusPopoverFormatting.quotaWindowDisplayItems(
            snapshot: snapshot,
            status: .demoMode
        )

        XCTAssertTrue(items.isEmpty)
    }

    func testQuotaTooltipKeepsSameQuotaValuesWhileRefreshing() {
        let now = makeDate("2026-06-19T12:40:00Z")
        let resetAt = makeDate("2026-06-19T14:10:00Z")
        let snapshot = QuotaSnapshot(
            weeklyQuotaPercent: 58,
            fiveHourQuotaPercent: 43,
            fiveHourResetAt: resetAt,
            refreshedAt: .now,
            dataSource: .real
        )

        let formatted = StatusPopoverFormatting.quotaTooltip(
            snapshot: snapshot,
            status: .refreshing,
            now: now,
            calendar: Calendar(identifier: .gregorian).setting(timeZone: TimeZone(secondsFromGMT: 0)!),
            locale: Locale(identifier: "en_US"),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        XCTAssertEqual(formatted, "Codex Monitor：5小时额度 43% · 周额度 58% · 5小时额度恢复 今天 14:10 · 还需 1小时30分 · 正在刷新")
    }

    func testQuotaTooltipKeepsSameQuotaValuesOnAuthFailure() {
        let now = makeDate("2026-06-19T12:40:00Z")
        let resetAt = makeDate("2026-06-19T13:25:00Z")
        let snapshot = QuotaSnapshot(
            weeklyQuotaPercent: 52,
            fiveHourQuotaPercent: 37,
            fiveHourResetAt: resetAt,
            refreshedAt: .now,
            dataSource: .real
        )

        let formatted = StatusPopoverFormatting.quotaTooltip(
            snapshot: snapshot,
            status: .authRequired,
            now: now,
            calendar: Calendar(identifier: .gregorian).setting(timeZone: TimeZone(secondsFromGMT: 0)!),
            locale: Locale(identifier: "en_US"),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        XCTAssertEqual(formatted, "Codex Monitor：5小时额度 37% · 周额度 52% · 5小时额度恢复 今天 13:25 · 还需 45分 · 需要登录，显示上次数据")
    }

    func testQuotaSummaryLineUsesPlaceholderWithoutRealSnapshot() {
        let snapshot = QuotaSnapshot.notConnected

        let formatted = StatusPopoverFormatting.quotaSummaryLine(
            snapshot: snapshot,
            status: .noSnapshot
        )

        XCTAssertEqual(formatted, "额度 --")
    }

    func testRecoverySummaryLineUsesPlaceholdersWithoutUsableQuotaState() {
        let formatted = StatusPopoverFormatting.recoverySummaryLine(
            resetAt: makeDate("2026-06-19T13:25:00Z"),
            status: .noSnapshot,
            now: makeDate("2026-06-19T12:40:00Z"),
            calendar: Calendar(identifier: .gregorian).setting(timeZone: TimeZone(secondsFromGMT: 0)!),
            locale: Locale(identifier: "en_US"),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        XCTAssertEqual(formatted, "恢复 -- · 还需 --")
    }

    func testRecoverySummaryLineShowsUnknownWhenRealResetTimeIsNotExposed() {
        let formatted = StatusPopoverFormatting.recoverySummaryLine(
            resetAt: nil,
            status: .success,
            now: makeDate("2026-06-19T12:40:00Z"),
            calendar: Calendar(identifier: .gregorian).setting(timeZone: TimeZone(secondsFromGMT: 0)!),
            locale: Locale(identifier: "en_US"),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        XCTAssertEqual(formatted, "恢复 未知（未暴露） · 还需 未暴露")
    }

    func testRecoveryDetailsExposeResetAndRemainingSeparately() {
        let now = makeDate("2026-06-19T12:40:00Z")
        let resetAt = makeDate("2026-06-19T14:10:00Z")

        let details = StatusPopoverFormatting.recoveryDetails(
            resetAt: resetAt,
            status: .success,
            now: now,
            calendar: Calendar(identifier: .gregorian).setting(timeZone: TimeZone(secondsFromGMT: 0)!),
            locale: Locale(identifier: "en_US"),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        XCTAssertEqual(details, .init(resetText: "今天 14:10", remainingText: "1小时30分"))
    }

    func testResetCreditsSummaryUsesRealCountWhenExposed() {
        let snapshot = QuotaSnapshot(
            weeklyQuotaPercent: 52,
            fiveHourQuotaPercent: 37,
            resetAvailableCount: 5,
            resetCreditDetailsState: .unavailable,
            resetCreditDiagnostic: ResetCreditDiagnosticSnapshot(summary: "HTTP 状态码 503"),
            refreshedAt: .now,
            dataSource: .real
        )

        let summary = StatusPopoverFormatting.resetCreditsSummary(
            snapshot: snapshot,
            status: .success
        )

        XCTAssertEqual(summary?.countLine, "重置次数 5")
        XCTAssertEqual(summary?.timingLine, "到期时间暂不可用")
        XCTAssertNil(summary?.featuredCreditItem)
        XCTAssertTrue(summary?.additionalCreditItems.isEmpty ?? false)
        XCTAssertEqual(summary?.detailLines, ["详情失败：HTTP 状态码 503"])
    }

    func testResetCreditsSummaryShowsUnknownWhenCountMissing() {
        let snapshot = QuotaSnapshot(
            weeklyQuotaPercent: 52,
            fiveHourQuotaPercent: 37,
            resetCreditDetailsState: .unavailable,
            refreshedAt: .now,
            dataSource: .real
        )

        let summary = StatusPopoverFormatting.resetCreditsSummary(
            snapshot: snapshot,
            status: .success
        )

        XCTAssertEqual(summary?.countLine, "重置次数未知")
        XCTAssertEqual(summary?.timingLine, "到期时间暂不可用")
        XCTAssertEqual(summary?.detailLines, ["详情暂不可用，当前仅显示 Codex 提供的次数"])
    }

    func testResetCreditsSummaryShowsCachedExpiryWhenDetailRefreshFails() {
        let now = makeDate("2026-06-19T12:40:00Z")
        let snapshot = QuotaSnapshot(
            weeklyQuotaPercent: 52,
            fiveHourQuotaPercent: 37,
            resetAvailableCount: 1,
            resetCreditDetailsState: .unavailable,
            resetCreditDiagnostic: ResetCreditDiagnosticSnapshot(summary: "HTTP 状态码 503"),
            resetCreditDetails: [
                ResetCreditDetailSnapshot(
                    ordinal: 1,
                    status: "available",
                    grantedAt: makeDate("2026-06-19T10:10:00Z"),
                    expiresAt: makeDate("2026-06-19T13:10:00Z")
                )
            ],
            refreshedAt: now,
            dataSource: .real
        )

        let summary = StatusPopoverFormatting.resetCreditsSummary(
            snapshot: snapshot,
            status: .success,
            now: now,
            calendar: Calendar(identifier: .gregorian).setting(timeZone: TimeZone(secondsFromGMT: 0)!),
            locale: Locale(identifier: "en_US"),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        XCTAssertNil(summary?.timingLine)
        XCTAssertEqual(summary?.featuredCreditItem?.expiryText, "今天 13:10")
        XCTAssertEqual(summary?.featuredCreditItem?.remainingText, "剩余 30分 · 上次成功")
        XCTAssertEqual(
            summary?.detailLines,
            ["详情刷新失败，显示上次成功时间：HTTP 状态码 503"]
        )
    }

    func testResetCreditsSummaryHidesCachedExpiryAfterItPasses() {
        let now = makeDate("2026-06-19T13:11:00Z")
        let snapshot = QuotaSnapshot(
            weeklyQuotaPercent: 52,
            fiveHourQuotaPercent: 37,
            resetAvailableCount: 1,
            resetCreditDetailsState: .unavailable,
            resetCreditDiagnostic: ResetCreditDiagnosticSnapshot(summary: "HTTP 状态码 503"),
            resetCreditDetails: [
                ResetCreditDetailSnapshot(
                    ordinal: 1,
                    status: "available",
                    grantedAt: nil,
                    expiresAt: makeDate("2026-06-19T13:10:00Z")
                )
            ],
            refreshedAt: makeDate("2026-06-19T12:40:00Z"),
            dataSource: .real
        )

        let summary = StatusPopoverFormatting.resetCreditsSummary(
            snapshot: snapshot,
            status: .success,
            now: now
        )

        XCTAssertEqual(summary?.timingLine, "到期时间暂不可用")
        XCTAssertNil(summary?.featuredCreditItem)
        XCTAssertTrue(summary?.additionalCreditItems.isEmpty ?? false)
        XCTAssertEqual(summary?.detailLines, ["详情失败：HTTP 状态码 503"])
    }

    func testResetCreditsSummaryShowsSanitizedFailureReasonWithoutSecrets() {
        let snapshot = QuotaSnapshot(
            weeklyQuotaPercent: 52,
            fiveHourQuotaPercent: 37,
            resetAvailableCount: 5,
            resetCreditDetailsState: .unavailable,
            resetCreditDiagnostic: ResetCreditDiagnosticSnapshot(summary: "tokens 缺失"),
            refreshedAt: .now,
            dataSource: .real
        )

        let summary = StatusPopoverFormatting.resetCreditsSummary(
            snapshot: snapshot,
            status: .success
        )

        XCTAssertEqual(summary?.detailLines, ["详情失败：tokens 缺失"])
        XCTAssertFalse(summary?.detailLines.joined(separator: " ").contains("Bearer") ?? true)
        XCTAssertFalse(summary?.detailLines.joined(separator: " ").contains("credit-") ?? true)
    }

    func testResetCreditsSummaryDoesNotUseRateLimitBankResetTimeAsCreditTime() {
        let snapshot = QuotaSnapshot(
            weeklyQuotaPercent: 52,
            fiveHourQuotaPercent: 37,
            resetAvailableCount: 5,
            resetCreditDetailsState: .appServerCountOnly,
            fiveHourResetAt: makeDate("2026-06-19T14:10:00Z"),
            resetBanks: [
                ResetBankSnapshot(
                    limitId: "codex",
                    windowId: "primary",
                    displayName: "5小时额度",
                    remainingPercent: 37,
                    resetAt: makeDate("2026-06-19T14:10:00Z")
                )
            ],
            refreshedAt: .now,
            dataSource: .real
        )

        let items = StatusPopoverFormatting.resetCreditTimeDisplayItems(
            snapshot: snapshot,
            status: .success
        )

        let summary = StatusPopoverFormatting.resetCreditsSummary(
            snapshot: snapshot,
            status: .success
        )

        XCTAssertTrue(items.isEmpty)
        XCTAssertEqual(summary?.timingLine, "到期时间暂不可用")
    }

    func testResetCreditsSummaryShowsWhamExpiryRowsAndCountdown() {
        let now = makeDate("2026-06-19T12:40:00Z")
        let snapshot = QuotaSnapshot(
            weeklyQuotaPercent: 52,
            fiveHourQuotaPercent: 37,
            resetAvailableCount: 5,
            resetCreditDetailsState: .detailed,
            resetCreditDetails: [
                ResetCreditDetailSnapshot(
                    ordinal: 2,
                    status: "available",
                    grantedAt: makeDate("2026-06-19T11:10:00Z"),
                    expiresAt: makeDate("2026-06-19T15:10:00Z")
                ),
                ResetCreditDetailSnapshot(
                    ordinal: 1,
                    status: "available",
                    grantedAt: makeDate("2026-06-19T10:10:00Z"),
                    expiresAt: makeDate("2026-06-19T13:10:00Z")
                )
            ],
            resetCreditStatusSummary: [ResetCreditStatusSummary(status: "available", count: 2)],
            refreshedAt: .now,
            dataSource: .real
        )

        let summary = StatusPopoverFormatting.resetCreditsSummary(
            snapshot: snapshot,
            status: .success,
            now: now,
            calendar: Calendar(identifier: .gregorian).setting(timeZone: TimeZone(secondsFromGMT: 0)!),
            locale: Locale(identifier: "en_US"),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        XCTAssertNil(summary?.timingLine)
        XCTAssertEqual(summary?.featuredCreditItem?.expiryText, "今天 13:10")
        XCTAssertEqual(summary?.featuredCreditItem?.remainingText, "剩余 30分")
        XCTAssertEqual(summary?.featuredCreditItem?.grantedText, "今天 10:10")
        XCTAssertEqual(summary?.additionalCreditItems.map(\.expiryText), ["今天 15:10"])
        XCTAssertEqual(summary?.additionalCreditItems.map(\.remainingText), ["剩余 2小时30分"])
        XCTAssertEqual(summary?.additionalCreditItems.map(\.grantedText), ["今天 11:10"])
        XCTAssertEqual(summary?.detailLines, ["已加载重置次数详情"])
    }

    func testResetCreditsSummaryKeepsAllCreditsInLowPrioritySectionSortedByExpiry() {
        let now = makeDate("2026-06-19T12:40:00Z")
        let snapshot = QuotaSnapshot(
            weeklyQuotaPercent: 52,
            fiveHourQuotaPercent: 37,
            resetAvailableCount: 3,
            resetCreditDetailsState: .detailed,
            resetCreditDetails: [
                ResetCreditDetailSnapshot(
                    ordinal: 3,
                    status: "available",
                    grantedAt: makeDate("2026-06-19T11:30:00Z"),
                    expiresAt: makeDate("2026-06-19T18:10:00Z")
                ),
                ResetCreditDetailSnapshot(
                    ordinal: 1,
                    status: "available",
                    grantedAt: makeDate("2026-06-19T10:10:00Z"),
                    expiresAt: makeDate("2026-06-19T13:10:00Z")
                ),
                ResetCreditDetailSnapshot(
                    ordinal: 2,
                    status: "available",
                    grantedAt: makeDate("2026-06-19T10:40:00Z"),
                    expiresAt: makeDate("2026-06-19T15:10:00Z")
                )
            ],
            resetCreditStatusSummary: [ResetCreditStatusSummary(status: "available", count: 3)],
            refreshedAt: .now,
            dataSource: .real
        )

        let summary = StatusPopoverFormatting.resetCreditsSummary(
            snapshot: snapshot,
            status: .success,
            now: now,
            calendar: Calendar(identifier: .gregorian).setting(timeZone: TimeZone(secondsFromGMT: 0)!),
            locale: Locale(identifier: "en_US"),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        XCTAssertEqual(summary?.featuredCreditItem?.expiryText, "今天 13:10")
        XCTAssertEqual(summary?.additionalCreditItems.map(\.expiryText), ["今天 15:10", "今天 18:10"])
    }

    func testResetBankDisplayItemsClampToFastestThreeRowsByResetTime() {
        let now = makeDate("2026-06-19T12:40:00Z")
        let snapshot = QuotaSnapshot(
            weeklyQuotaPercent: 80,
            fiveHourQuotaPercent: 70,
            resetBanks: [
                makeResetBank(id: "d.primary", percent: 40, resetAt: "2026-06-19T16:40:00Z"),
                makeResetBank(id: "b.primary", percent: 60, resetAt: "2026-06-19T13:40:00Z"),
                makeResetBank(id: "c.primary", percent: 50, resetAt: "2026-06-19T15:40:00Z"),
                makeResetBank(id: "a.primary", percent: 70, resetAt: "2026-06-19T12:50:00Z")
            ],
            refreshedAt: .now,
            dataSource: .real
        )

        let items = StatusPopoverFormatting.resetBankDisplayItems(
            snapshot: snapshot,
            status: .success,
            now: now,
            calendar: Calendar(identifier: .gregorian).setting(timeZone: TimeZone(secondsFromGMT: 0)!),
            locale: Locale(identifier: "en_US"),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items.map(\.id), ["a.primary", "b.primary", "c.primary"])
    }

    func testResetBankDisplayItemsRespectTimeZoneForAbsoluteTimestamp() {
        let timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let calendar = Calendar(identifier: .gregorian).setting(timeZone: timeZone)
        let now = makeDate("2026-06-19T15:40:00Z")
        let snapshot = QuotaSnapshot(
            weeklyQuotaPercent: 80,
            fiveHourQuotaPercent: 70,
            resetBanks: [
                ResetBankSnapshot(
                    limitId: "codex",
                    windowId: "primary",
                    displayName: "5小时额度",
                    remainingPercent: 70,
                    resetAt: makeDate("2026-06-19T16:10:00Z")
                )
            ],
            refreshedAt: .now,
            dataSource: .real
        )

        let items = StatusPopoverFormatting.resetBankDisplayItems(
            snapshot: snapshot,
            status: .success,
            now: now,
            calendar: calendar,
            locale: Locale(identifier: "zh_CN"),
            timeZone: timeZone
        )

        XCTAssertEqual(items.first?.resetText, "6月20日 00:10")
        XCTAssertEqual(items.first?.remainingText, "30分")
    }

    func testResetBankDisplayItemsDoNotRepeatGlobalStaleStatePerRow() {
        let snapshot = QuotaSnapshot(
            weeklyQuotaPercent: 80,
            fiveHourQuotaPercent: 70,
            resetBanks: [
                ResetBankSnapshot(
                    limitId: "codex",
                    windowId: "primary",
                    displayName: "5小时额度",
                    remainingPercent: 70,
                    resetAt: makeDate("2026-06-19T16:10:00Z")
                )
            ],
            refreshedAt: .now,
            dataSource: .real
        )

        let items = StatusPopoverFormatting.resetBankDisplayItems(
            snapshot: snapshot,
            status: .stale
        )

        XCTAssertNil(items.first?.detailText)
    }

    func testResetBankDisplayItemsUseSemanticDiagnosticsWithoutProtocolPaths() {
        let snapshot = QuotaSnapshot(
            weeklyQuotaPercent: 80,
            fiveHourQuotaPercent: 70,
            resetBanks: [
                ResetBankSnapshot(
                    limitId: "codex",
                    windowId: "primary",
                    displayName: "5小时额度",
                    remainingPercent: 70,
                    resetAt: nil,
                    resetTimeStatus: .parseFailed
                )
            ],
            refreshedAt: .now,
            dataSource: .real
        )

        let item = StatusPopoverFormatting.resetBankDisplayItems(
            snapshot: snapshot,
            status: .success
        ).first

        XCTAssertNil(item?.sourceText)
        XCTAssertEqual(item?.detailText, "诊断：重置时间格式不受支持")
        XCTAssertFalse(item?.detailText?.contains("rateLimitsByLimitId") ?? true)
    }

    func testResetCreditsSummaryHidesNonAvailableStatesInDiagnostics() {
        let snapshot = QuotaSnapshot(
            weeklyQuotaPercent: 52,
            fiveHourQuotaPercent: 37,
            resetAvailableCount: 2,
            resetCreditDetailsState: .detailed,
            resetCreditDetails: [
                ResetCreditDetailSnapshot(
                    ordinal: 1,
                    status: "available",
                    grantedAt: nil,
                    expiresAt: makeDate("2026-06-19T13:10:00Z")
                )
            ],
            resetCreditStatusSummary: [
                ResetCreditStatusSummary(status: "available", count: 1),
                ResetCreditStatusSummary(status: "expired", count: 1),
                ResetCreditStatusSummary(status: "redeemed", count: 2)
            ],
            refreshedAt: .now,
            dataSource: .real
        )

        let summary = StatusPopoverFormatting.resetCreditsSummary(
            snapshot: snapshot,
            status: .networkFailed
        )

        XCTAssertEqual(summary?.countLine, "重置次数 2")
        XCTAssertEqual(
            summary?.detailLines,
            [
                "已加载重置次数详情",
                "已隐藏非 available 状态：redeemed 2 条 · expired 1 条"
            ]
        )
    }

    private func makeDate(_ iso8601: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: iso8601)!
    }

    private func makeResetBank(id: String, percent: Int, resetAt: String) -> ResetBankSnapshot {
        let parts = id.split(separator: ".", maxSplits: 1).map(String.init)
        return ResetBankSnapshot(
            limitId: parts[0],
            windowId: parts[1],
            displayName: id,
            remainingPercent: percent,
            resetAt: makeDate(resetAt)
        )
    }
}

private extension Calendar {
    func setting(timeZone: TimeZone) -> Calendar {
        var calendar = self
        calendar.timeZone = timeZone
        return calendar
    }
}
