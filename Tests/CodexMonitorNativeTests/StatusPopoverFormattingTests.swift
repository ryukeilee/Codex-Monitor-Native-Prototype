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

    func testQuotaValueTextHidesUntrustedFieldAndMarksHistoricalCache() {
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
            "71%（历史缓存）"
        )
        XCTAssertEqual(
            StatusPopoverFormatting.quotaSummaryLine(snapshot: snapshot, status: .success),
            "5小时额度 -- · 周额度 71%（历史缓存）"
        )
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
        XCTAssertEqual(summary?.detailLines, ["详情来源暂不可用，当前仅显示 app-server 次数"])
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
        XCTAssertEqual(summary?.detailLines, ["详情来源：wham reset credits endpoint"])
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
                "详情来源：wham reset credits endpoint",
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
