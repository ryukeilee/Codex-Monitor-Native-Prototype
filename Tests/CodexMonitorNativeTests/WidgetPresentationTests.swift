import XCTest
@testable import CodexMonitorNative

final class WidgetPresentationTests: XCTestCase {
    func testPresentationUsesWidgetStateSelectionForCapacityAndOverflow() {
        let now = Date(timeIntervalSince1970: 1_720_000_000)
        let snapshot = QuotaSnapshot(
            weeklyQuotaPercent: 0,
            fiveHourQuotaPercent: 0,
            weeklyQuotaState: .unavailable,
            fiveHourQuotaState: .unavailable,
            refreshedAt: now,
            dataSource: .real,
            quotaWindows: [
                QuotaWindow(limitId: "future", windowId: "unknown", kind: .unknown, remainingPercent: 40),
                QuotaWindow(limitId: "codex", windowId: "monthly", kind: .monthly, remainingPercent: 58),
                QuotaWindow(limitId: "codex", windowId: "secondary", kind: .weekly, remainingPercent: 71),
                QuotaWindow(limitId: "codex", windowId: "primary", kind: .fiveHour, remainingPercent: 64),
                QuotaWindow(limitId: "codex", windowId: "invalid", kind: .fiveHour, remainingPercent: 99, state: .invalid)
            ]
        )
        let state = WidgetDisplayState.make(
            snapshot: snapshot,
            status: .success,
            lastSuccessAt: now,
            lastAttemptAt: now,
            effectiveFiveHourResetAt: nil,
            savedAt: now
        )

        let small = WidgetPresentation(state: state, family: .small, now: now)
        let medium = WidgetPresentation(state: state, family: .medium, now: now)

        XCTAssertEqual(small.family.quotaCapacity, 1)
        XCTAssertEqual(small.primaryQuota?.label, "5小时额度")
        XCTAssertEqual(small.supplementaryQuotas, [])
        XCTAssertEqual(small.quotaSideItems.map(\.label), ["5小时额度"])
        XCTAssertEqual(small.overflowCount, 2)

        XCTAssertEqual(medium.family.quotaCapacity, 3)
        XCTAssertEqual(medium.primaryQuota?.label, "5小时额度")
        XCTAssertEqual(medium.supplementaryQuotas.map(\.label), ["周额度", "月额度"])
        XCTAssertEqual(medium.quotaSideItems.map(\.label), ["周额度", "月额度"])
        XCTAssertEqual(medium.overflowCount, 0)
        XCTAssertFalse(medium.supplementaryQuotas.contains { $0.percentText == "99%" })
    }

    func testPresentationFormatsCenterProgressLabelsAndFooter() {
        let minimumProgress = WidgetPresentation(
            quotaItems: [quota(id: "fiveHour", label: "5小时额度", percent: 6, progress: -0.2)],
            family: .small,
            resetCreditFooterText: "最早重置 7/3 21:51"
        )
        let maximumProgress = WidgetPresentation(
            quotaItems: [quota(id: "weekly", label: "周额度", percent: 100, progress: 1.2)],
            family: .medium,
            resetCreditFooterText: "无需裁剪"
        )
        let unavailable = WidgetPresentation(
            quotaItems: [],
            family: .small,
            resetCreditFooterText: nil
        )

        XCTAssertEqual(minimumProgress.centerQuotaNumberText, "6")
        XCTAssertEqual(minimumProgress.gaugeProgress, 0.05)
        XCTAssertEqual(minimumProgress.footerText, "7/3 21:51")
        XCTAssertEqual(minimumProgress.shortLabel(for: "刷新状态"), "状态")
        XCTAssertEqual(minimumProgress.shortLabel(for: "恢复时间"), "恢复")
        XCTAssertEqual(minimumProgress.shortLabel(for: "更新时间"), "更新")
        XCTAssertEqual(minimumProgress.shortLabel(for: "周额度"), "周额度")
        XCTAssertEqual(maximumProgress.gaugeProgress, 1.0)
        XCTAssertEqual(maximumProgress.footerText, "无需裁剪")
        XCTAssertEqual(unavailable.centerQuotaNumberText, "--")
        XCTAssertEqual(unavailable.gaugeProgress, 0.05)
    }

    func testPresentationHidesLatestCaptionAndPreservesOtherQuotaContext() {
        let latest = WidgetPresentation(
            quotaItems: [quota(id: "latest", label: "周额度", percent: 99, progress: 0.99, stateText: "最新")],
            family: .small,
            resetCreditFooterText: nil
        )
        let stale = WidgetPresentation(
            quotaItems: [quota(id: "stale", label: "周额度", percent: 99, progress: 0.99, stateText: "上次数据")],
            family: .small,
            resetCreditFooterText: nil
        )
        let cached = WidgetPresentation(
            quotaItems: [
                quota(
                    id: "cached",
                    label: "周额度",
                    percent: 99,
                    progress: 0.99,
                    historyCaption: "（历史缓存）",
                    stateText: "历史缓存"
                )
            ],
            family: .small,
            resetCreditFooterText: nil
        )

        XCTAssertNil(latest.primaryQuota?.caption)
        XCTAssertEqual(stale.primaryQuota?.caption, "上次数据")
        XCTAssertEqual(cached.primaryQuota?.caption, "（历史缓存）")
    }

    func testPresentationMarksCachedResetCreditFooterAndHidesItAfterExpiry() {
        let now = Date(timeIntervalSince1970: 1_720_000_000)
        let snapshot = QuotaSnapshot(
            weeklyQuotaPercent: 71,
            fiveHourQuotaPercent: 64,
            resetAvailableCount: 1,
            resetCreditDetailsState: .unavailable,
            resetCreditDiagnostic: ResetCreditDiagnosticSnapshot(summary: "HTTP 状态码 503"),
            resetCreditDetails: [
                ResetCreditDetailSnapshot(
                    ordinal: 1,
                    status: "available",
                    grantedAt: now.addingTimeInterval(-1_000),
                    expiresAt: now.addingTimeInterval(60 * 60)
                )
            ],
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

        let active = WidgetPresentation(state: state, family: .small, now: now)
        let expired = WidgetPresentation(
            state: state,
            family: .small,
            now: now.addingTimeInterval(60 * 60 + 1)
        )

        XCTAssertTrue(state.resetCreditFooterLine?.hasPrefix("上次重置 ") ?? false)
        XCTAssertTrue(active.footerText?.hasPrefix("上次 ") ?? false)
        XCTAssertNil(expired.footerText)
    }

    func testPresentationHidesDetailedResetCreditFooterAtExactExpiry() {
        let now = Date(timeIntervalSince1970: 1_720_000_000)
        let expiresAt = now.addingTimeInterval(60)
        let snapshot = QuotaSnapshot(
            weeklyQuotaPercent: 71,
            fiveHourQuotaPercent: 64,
            resetAvailableCount: 1,
            resetCreditDetailsState: .detailed,
            resetCreditDetails: [
                ResetCreditDetailSnapshot(
                    ordinal: 1,
                    status: "available",
                    grantedAt: now.addingTimeInterval(-1_000),
                    expiresAt: expiresAt
                )
            ],
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

        XCTAssertNotNil(WidgetPresentation(state: state, family: .small, now: now).footerText)
        XCTAssertNil(
            WidgetPresentation(
                state: state,
                family: .small,
                now: expiresAt
            ).footerText
        )
    }

    func testWidgetProjectsPersistedSuccessToStaleWithoutAppProcess() {
        let now = Date(timeIntervalSince1970: 1_720_000_000)
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
            effectiveFiveHourResetAt: nil,
            savedAt: now
        )
        let staleDate = now.addingTimeInterval(
            QuotaTemporalSemantics.defaultStaleAfterInterval
        )

        XCTAssertEqual(state.effectiveStatus(at: now), .success)
        XCTAssertEqual(state.effectiveStatus(at: staleDate), .stale)
        XCTAssertEqual(
            WidgetPresentation(state: state, family: .small, now: staleDate)
                .primaryQuota?.caption,
            "已过期"
        )
    }

    func testWidgetNextTemporalTransitionUsesEarliestStrictDeadline() {
        let now = Date(timeIntervalSince1970: 1_720_000_000)
        let creditExpiry = now.addingTimeInterval(30)
        let quotaReset = now.addingTimeInterval(60)
        let snapshot = QuotaSnapshot(
            weeklyQuotaPercent: 71,
            fiveHourQuotaPercent: 64,
            resetCreditDetailsState: .detailed,
            resetCreditDetails: [
                ResetCreditDetailSnapshot(
                    ordinal: 1,
                    status: "available",
                    grantedAt: now,
                    expiresAt: creditExpiry
                )
            ],
            refreshedAt: now,
            dataSource: .real,
            quotaWindows: [
                QuotaWindow(
                    limitId: "codex",
                    windowId: "primary",
                    kind: .fiveHour,
                    durationMinutes: 300,
                    remainingPercent: 64,
                    resetAt: quotaReset
                )
            ]
        )
        let state = WidgetDisplayState.make(
            snapshot: snapshot,
            status: .success,
            lastSuccessAt: now,
            lastAttemptAt: now,
            effectiveFiveHourResetAt: quotaReset,
            savedAt: now
        )

        XCTAssertEqual(state.nextTemporalTransition(after: now), creditExpiry)
        XCTAssertEqual(state.nextTemporalTransition(after: creditExpiry), quotaReset)
        XCTAssertEqual(
            state.timelineEntryDates(startingAt: now),
            [
                now,
                creditExpiry,
                quotaReset,
                now.addingTimeInterval(QuotaTemporalSemantics.defaultStaleAfterInterval)
            ]
        )

        let expiredFiveHour = state.quotaItems(now: quotaReset)
            .first { $0.kind == .fiveHour }
        XCTAssertNil(expiredFiveHour?.progress)
        XCTAssertEqual(expiredFiveHour?.percentText, "--")
    }

    func testWidgetTimelinePlanAddsCalendarDayEntriesAroundSemanticTransitions() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(
            year: 2024,
            month: 7,
            day: 3,
            hour: 23,
            minute: 50
        ))!
        let creditExpiry = now.addingTimeInterval(5 * 60)
        let midnight = calendar.date(from: DateComponents(
            year: 2024,
            month: 7,
            day: 4
        ))!
        let quotaReset = now.addingTimeInterval(15 * 60)
        let staleDate = now.addingTimeInterval(
            QuotaTemporalSemantics.defaultStaleAfterInterval
        )
        let snapshot = QuotaSnapshot(
            weeklyQuotaPercent: 71,
            fiveHourQuotaPercent: 64,
            resetCreditDetailsState: .detailed,
            resetCreditDetails: [
                ResetCreditDetailSnapshot(
                    ordinal: 1,
                    status: "available",
                    grantedAt: now,
                    expiresAt: creditExpiry
                )
            ],
            refreshedAt: now,
            dataSource: .real,
            quotaWindows: [
                QuotaWindow(
                    limitId: "codex",
                    windowId: "primary",
                    kind: .fiveHour,
                    durationMinutes: 300,
                    remainingPercent: 64,
                    resetAt: quotaReset
                )
            ]
        )
        let state = WidgetDisplayState.make(
            snapshot: snapshot,
            status: .success,
            lastSuccessAt: now,
            lastAttemptAt: now,
            effectiveFiveHourResetAt: quotaReset,
            savedAt: now
        )

        let plan = state.timelinePlan(startingAt: now, calendar: calendar)

        XCTAssertEqual(plan.entryDates.first, now)
        XCTAssertEqual(
            plan.reloadAfter,
            now.addingTimeInterval(WidgetTimelinePlan.activeRevalidationInterval)
        )
        XCTAssertTrue(plan.entryDates.contains(creditExpiry))
        XCTAssertTrue(plan.entryDates.contains(midnight))
        XCTAssertTrue(plan.entryDates.contains(quotaReset))
        XCTAssertTrue(plan.entryDates.contains(staleDate))
        XCTAssertEqual(plan.entryDates, Array(Set(plan.entryDates)).sorted())
        XCTAssertEqual(plan.calendarDayEntryDates.count, WidgetTimelinePlan.calendarDayLookaheadCount)
        XCTAssertEqual(plan.calendarDayEntryDates.first, midnight)
        XCTAssertEqual(
            state.quotaItems(now: quotaReset)
                .first { $0.kind == .fiveHour }?
                .percentText,
            "--"
        )
        XCTAssertNil(
            WidgetPresentation(state: state, family: .small, now: creditExpiry)
                .footerText
        )
    }

    func testWidgetTimelinePlanUsesBudgetedAdaptiveRevalidation() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(
            year: 2024,
            month: 7,
            day: 3,
            hour: 12
        ))!
        let snapshot = QuotaSnapshot(
            weeklyQuotaPercent: 71,
            fiveHourQuotaPercent: 64,
            refreshedAt: now,
            dataSource: .real
        )
        let fresh = WidgetDisplayState.make(
            snapshot: snapshot,
            status: .success,
            lastSuccessAt: now,
            lastAttemptAt: now,
            effectiveFiveHourResetAt: nil,
            savedAt: now
        )
        let stale = WidgetDisplayState.make(
            snapshot: snapshot,
            status: .success,
            lastSuccessAt: now.addingTimeInterval(
                -QuotaTemporalSemantics.defaultStaleAfterInterval
            ),
            lastAttemptAt: now,
            effectiveFiveHourResetAt: nil,
            savedAt: now
        )

        XCTAssertEqual(
            fresh.timelinePlan(startingAt: now, calendar: calendar).reloadAfter,
            now.addingTimeInterval(WidgetTimelinePlan.activeRevalidationInterval)
        )
        XCTAssertEqual(
            stale.timelinePlan(startingAt: now, calendar: calendar).reloadAfter,
            now.addingTimeInterval(WidgetTimelinePlan.passiveRevalidationInterval)
        )
        XCTAssertEqual(
            WidgetDisplayState.placeholder
                .timelinePlan(startingAt: now, calendar: calendar)
                .reloadAfter,
            now.addingTimeInterval(WidgetTimelinePlan.disconnectedRevalidationInterval)
        )
        XCTAssertGreaterThanOrEqual(WidgetTimelinePlan.activeRevalidationInterval, 30 * 60)
        XCTAssertGreaterThanOrEqual(WidgetTimelinePlan.passiveRevalidationInterval, 60 * 60)
        XCTAssertGreaterThanOrEqual(WidgetTimelinePlan.disconnectedRevalidationInterval, 6 * 60 * 60)
    }

    func testWidgetTimelinePlanRecomputesCalendarBoundaryForTimeZoneChange() {
        let now = Date(timeIntervalSince1970: 1_720_008_000)
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var shanghaiCalendar = Calendar(identifier: .gregorian)
        shanghaiCalendar.timeZone = TimeZone(secondsFromGMT: 8 * 60 * 60)!
        let state = WidgetDisplayState.placeholder

        let utcPlan = state.timelinePlan(startingAt: now, calendar: utcCalendar)
        let shanghaiPlan = state.timelinePlan(startingAt: now, calendar: shanghaiCalendar)

        XCTAssertNotEqual(
            utcPlan.calendarDayEntryDates.first,
            shanghaiPlan.calendarDayEntryDates.first
        )
        XCTAssertEqual(
            utcPlan.calendarDayEntryDates.first,
            utcCalendar.dateInterval(of: .day, for: now)?.end
        )
        XCTAssertEqual(
            shanghaiPlan.calendarDayEntryDates.first,
            shanghaiCalendar.dateInterval(of: .day, for: now)?.end
        )
    }

    func testWidgetTimelinePlanUsesCalendarBoundariesAcrossDaylightSavingChange() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let now = calendar.date(from: DateComponents(
            year: 2024,
            month: 3,
            day: 9,
            hour: 23,
            minute: 30
        ))!
        let firstMidnight = calendar.date(from: DateComponents(
            year: 2024,
            month: 3,
            day: 10
        ))!
        let secondMidnight = calendar.date(from: DateComponents(
            year: 2024,
            month: 3,
            day: 11
        ))!

        let plan = WidgetDisplayState.placeholder.timelinePlan(
            startingAt: now,
            calendar: calendar
        )

        XCTAssertEqual(Array(plan.calendarDayEntryDates.prefix(2)), [firstMidnight, secondMidnight])
        XCTAssertEqual(secondMidnight.timeIntervalSince(firstMidnight), 23 * 60 * 60)
    }

    func testWidgetExpiresOrphanedRefreshingStateAndFutureSuccessTimestamp() {
        let now = Date(timeIntervalSince1970: 1_720_000_000)
        let snapshot = QuotaSnapshot(
            weeklyQuotaPercent: 71,
            fiveHourQuotaPercent: 64,
            refreshedAt: now.addingTimeInterval(-60),
            dataSource: .real
        )
        let refreshing = WidgetDisplayState.make(
            snapshot: snapshot,
            status: .refreshing,
            lastSuccessAt: snapshot.refreshedAt,
            lastAttemptAt: now,
            effectiveFiveHourResetAt: nil,
            savedAt: now
        )
        let leaseExpiry = now.addingTimeInterval(
            WidgetDisplayState.refreshingLeaseInterval
        )
        let futureSuccess = WidgetDisplayState.make(
            snapshot: snapshot,
            status: .success,
            lastSuccessAt: now.addingTimeInterval(5 * 60),
            lastAttemptAt: now,
            effectiveFiveHourResetAt: nil,
            savedAt: now
        )
        let disconnectedRefreshing = WidgetDisplayState.make(
            snapshot: .notConnected,
            status: .refreshing,
            lastSuccessAt: nil,
            lastAttemptAt: now,
            effectiveFiveHourResetAt: nil,
            savedAt: now
        )

        XCTAssertEqual(refreshing.effectiveStatus(at: leaseExpiry.addingTimeInterval(-1)), .refreshing)
        XCTAssertEqual(refreshing.effectiveStatus(at: leaseExpiry), .stale)
        XCTAssertEqual(refreshing.nextTemporalTransition(after: now), leaseExpiry)
        XCTAssertEqual(futureSuccess.effectiveStatus(at: now), .stale)
        XCTAssertEqual(
            disconnectedRefreshing.effectiveStatus(at: leaseExpiry.addingTimeInterval(-1)),
            .refreshing
        )
        XCTAssertEqual(disconnectedRefreshing.effectiveStatus(at: leaseExpiry), .noSnapshot)
    }

    private func quota(
        id: String,
        label: String,
        percent: Int?,
        progress: Double?,
        historyCaption: String? = nil,
        stateText: String = "当前"
    ) -> StatusPopoverFormatting.QuotaWindowDisplayItem {
        StatusPopoverFormatting.QuotaWindowDisplayItem(
            id: id,
            semanticIdentity: id,
            kind: .unknown,
            label: label,
            percentText: percent.map { "\($0)%" } ?? "--",
            historyCaption: historyCaption,
            trustedPercent: percent,
            progress: progress,
            fieldState: .live,
            stateText: stateText,
            resetAt: nil,
            resetText: "未暴露",
            resetRemainingText: "未暴露",
            origin: .dynamic
        )
    }
}
