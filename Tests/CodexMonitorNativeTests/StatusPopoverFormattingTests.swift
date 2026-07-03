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
        XCTAssertEqual(StatusPopoverFormatting.titleSummary(for: .success), "已更新")
        XCTAssertEqual(StatusPopoverFormatting.titleSummary(for: .stale), "数据过期")
        XCTAssertEqual(StatusPopoverFormatting.titleSummary(for: .networkFailed), "网络异常")
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
            resetAt: resetAt,
            now: now,
            calendar: Calendar(identifier: .gregorian).setting(timeZone: TimeZone(secondsFromGMT: 0)!),
            locale: Locale(identifier: "en_US"),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        XCTAssertEqual(formatted, "Codex Monitor：5小时额度 43% · 周额度 58% · 恢复 今天 14:10 · 还需 1小时30分 · 正在刷新")
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
            resetAt: resetAt,
            now: now,
            calendar: Calendar(identifier: .gregorian).setting(timeZone: TimeZone(secondsFromGMT: 0)!),
            locale: Locale(identifier: "en_US"),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        XCTAssertEqual(formatted, "Codex Monitor：5小时额度 37% · 周额度 52% · 恢复 今天 13:25 · 还需 45分 · 需要登录，显示上次数据")
    }

    func testQuotaSummaryLineUsesPlaceholderWithoutRealSnapshot() {
        let snapshot = QuotaSnapshot.notConnected

        let formatted = StatusPopoverFormatting.quotaSummaryLine(
            snapshot: snapshot,
            status: .noSnapshot
        )

        XCTAssertEqual(formatted, "5小时额度 -- · 周额度 --")
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
            refreshedAt: .now,
            dataSource: .real
        )

        let summary = StatusPopoverFormatting.resetCreditsSummary(
            snapshot: snapshot,
            status: .success
        )

        XCTAssertEqual(summary?.countLine, "30 天内剩余重置速率限制次数：5")
        XCTAssertEqual(summary?.timingLine, "到期/恢复时间未知（未暴露）")
        XCTAssertEqual(summary?.detailLines, ["原始字段：未暴露 rateLimitResetCredits.*"])
    }

    func testResetCreditsSummaryShowsUnknownWhenCountMissing() {
        let snapshot = QuotaSnapshot(
            weeklyQuotaPercent: 52,
            fiveHourQuotaPercent: 37,
            refreshedAt: .now,
            dataSource: .real
        )

        let summary = StatusPopoverFormatting.resetCreditsSummary(
            snapshot: snapshot,
            status: .success
        )

        XCTAssertEqual(summary?.countLine, "30 天内剩余重置速率限制次数未知（未暴露）")
        XCTAssertEqual(summary?.timingLine, "到期/恢复时间未知（未暴露）")
        XCTAssertEqual(summary?.detailLines, ["原始字段：未暴露 rateLimitResetCredits.*"])
    }

    func testResetCreditsSummaryDoesNotUseRateLimitBankResetTimeAsCreditTime() {
        let snapshot = QuotaSnapshot(
            weeklyQuotaPercent: 52,
            fiveHourQuotaPercent: 37,
            resetAvailableCount: 5,
            resetCreditTimeEntries: [],
            resetCreditRawFields: [ResetCreditRawField(path: "rateLimitResetCredits.availableCount", value: "5")],
            fiveHourResetAt: makeDate("2026-06-19T14:10:00Z"),
            resetBanks: [
                ResetBankSnapshot(
                    limitId: "codex",
                    windowId: "primary",
                    displayName: "5小时额度",
                    remainingPercent: 37,
                    resetAt: makeDate("2026-06-19T14:10:00Z"),
                    resolvedResetFieldName: "resetAt",
                    rawResetFields: [ResetBankRawField(name: "resetAt", value: "2026-06-19T14:10:00Z")]
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
        XCTAssertEqual(summary?.timingLine, "到期/恢复时间未知（未暴露）")
    }

    func testResetCreditTimeDisplayItemsOnlyShowOfficialCreditTimes() {
        let now = makeDate("2026-06-19T12:40:00Z")
        let snapshot = QuotaSnapshot(
            weeklyQuotaPercent: 52,
            fiveHourQuotaPercent: 37,
            resetAvailableCount: 5,
            resetCreditTimeEntries: [
                ResetCreditTimeSnapshot(
                    label: "恢复时间",
                    date: makeDate("2026-06-19T13:10:00Z"),
                    sourcePath: "rateLimitResetCredits.restoresAt[0]"
                ),
                ResetCreditTimeSnapshot(
                    label: "到期时间",
                    date: makeDate("2026-06-19T15:10:00Z"),
                    sourcePath: "rateLimitResetCredits.expiresAt[0]"
                )
            ],
            resetCreditRawFields: [
                ResetCreditRawField(path: "rateLimitResetCredits.availableCount", value: "5"),
                ResetCreditRawField(path: "rateLimitResetCredits.restoresAt[0]", value: "2026-06-19T13:10:00Z"),
                ResetCreditRawField(path: "rateLimitResetCredits.expiresAt[0]", value: "2026-06-19T15:10:00Z")
            ],
            refreshedAt: .now,
            dataSource: .real
        )

        let items = StatusPopoverFormatting.resetCreditTimeDisplayItems(
            snapshot: snapshot,
            status: .success,
            now: now,
            calendar: Calendar(identifier: .gregorian).setting(timeZone: TimeZone(secondsFromGMT: 0)!),
            locale: Locale(identifier: "en_US"),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        XCTAssertEqual(items.map(\.label), ["恢复时间", "到期时间"])
        XCTAssertEqual(items.map(\.resetText), ["今天 13:10", "今天 15:10"])
        XCTAssertEqual(items.map(\.sourceText), [
            "来源：rateLimitResetCredits.restoresAt[0]",
            "来源：rateLimitResetCredits.expiresAt[0]"
        ])
    }

    func testResetBankDisplayItemsSortKnownTimesAheadOfUnknownAndKeepDiagnostics() {
        let now = makeDate("2026-06-19T12:40:00Z")
        let snapshot = QuotaSnapshot(
            weeklyQuotaPercent: 52,
            fiveHourQuotaPercent: 37,
            fiveHourResetAt: makeDate("2026-06-19T14:10:00Z"),
            resetBanks: [
                ResetBankSnapshot(
                    limitId: "codex_other",
                    windowId: "primary",
                    displayName: "周额度",
                    remainingPercent: 52,
                    resetAt: nil,
                    rawResetFields: [ResetBankRawField(name: "nextResetAt", value: "null")]
                ),
                ResetBankSnapshot(
                    limitId: "codex",
                    windowId: "primary",
                    displayName: "5小时额度",
                    remainingPercent: 37,
                    resetAt: makeDate("2026-06-19T14:10:00Z"),
                    resolvedResetFieldName: "resetAt",
                    rawResetFields: []
                )
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

        XCTAssertEqual(items.map(\.id), ["codex.primary", "codex_other.primary"])
        XCTAssertEqual(items[0].resetText, "今天 14:10")
        XCTAssertEqual(items[0].remainingText, "1小时30分")
        XCTAssertEqual(items[0].sourceText, "来源：rateLimitsByLimitId.codex.primary.resetAt")
        XCTAssertNil(items[0].detailText)
        XCTAssertEqual(items[1].resetText, "未知（未暴露）")
        XCTAssertEqual(items[1].remainingText, "未暴露")
        XCTAssertNil(items[1].sourceText)
        XCTAssertEqual(items[1].detailText, "诊断：解析失败 · 原始字段：rateLimitsByLimitId.codex_other.primary.nextResetAt=null")
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
                    resetAt: makeDate("2026-06-19T16:10:00Z"),
                    rawResetFields: []
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
                    resetAt: makeDate("2026-06-19T16:10:00Z"),
                    rawResetFields: []
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

    func testResetCreditsSummaryFlagsWhenOfficialCreditTimesExist() {
        let now = makeDate("2026-06-19T12:40:00Z")
        let snapshot = QuotaSnapshot(
            weeklyQuotaPercent: 52,
            fiveHourQuotaPercent: 37,
            resetAvailableCount: 5,
            resetCreditTimeEntries: [
                ResetCreditTimeSnapshot(
                    label: "恢复时间",
                    date: makeDate("2026-06-19T13:10:00Z"),
                    sourcePath: "rateLimitResetCredits.restoresAt[0]"
                )
            ],
            resetCreditRawFields: [
                ResetCreditRawField(path: "rateLimitResetCredits.availableCount", value: "5"),
                ResetCreditRawField(path: "rateLimitResetCredits.restoresAt[0]", value: "2026-06-19T13:10:00Z")
            ],
            refreshedAt: now,
            dataSource: .real
        )

        let summary = StatusPopoverFormatting.resetCreditsSummary(
            snapshot: snapshot,
            status: .networkFailed
        )

        XCTAssertEqual(summary?.countLine, "30 天内剩余重置速率限制次数：5")
        XCTAssertEqual(summary?.timingLine, "官方已暴露 reset credits 时间字段（见原始字段）")
        XCTAssertEqual(
            summary?.detailLines,
            ["原始字段：rateLimitResetCredits.availableCount=5 · rateLimitResetCredits.restoresAt[0]=2026-06-19T13:10:00Z"]
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
            resetAt: makeDate(resetAt),
            resolvedResetFieldName: "resetAt",
            rawResetFields: []
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
