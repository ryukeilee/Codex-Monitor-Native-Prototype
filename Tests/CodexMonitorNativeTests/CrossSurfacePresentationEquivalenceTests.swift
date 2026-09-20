import XCTest
@testable import CodexMonitorNative

final class CrossSurfacePresentationEquivalenceTests: XCTestCase {
    func testPopoverAndWidgetQuotaItemsAreEquivalentAcrossRepresentativeStates() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let resetAt = now.addingTimeInterval(3_600)
        let cases: [(name: String, snapshot: QuotaSnapshot, status: QuotaRefreshStatus)] = [
            (
                "one dynamic window",
                snapshot(windows: [window("codex", "primary", .fiveHour, 81, resetAt: resetAt)], refreshedAt: now),
                .success
            ),
            (
                "three dynamic windows",
                snapshot(windows: [
                    window("codex", "primary", .fiveHour, 81, resetAt: resetAt),
                    window("codex", "secondary", .weekly, 62),
                    window("codex", "monthly", .monthly, 44, resetAt: resetAt)
                ], refreshedAt: now),
                .success
            ),
            (
                "five dynamic windows with duplicate kinds",
                snapshot(windows: [
                    window("codex", "primary", .fiveHour, 81, resetAt: resetAt),
                    window("backup", "five", .fiveHour, 79, resetAt: resetAt),
                    window("codex", "secondary", .weekly, 62),
                    window("backup", "week", .weekly, 60),
                    window("codex", "monthly", .monthly, 44, resetAt: resetAt)
                ], refreshedAt: now),
                .success
            ),
            (
                "unknown duration window",
                snapshot(windows: [window("future", "bank", .unknown, 73, durationMinutes: 720)], refreshedAt: now),
                .success
            ),
            (
                "monthly only",
                snapshot(windows: [window("codex", "monthly", .monthly, 44, resetAt: resetAt)], refreshedAt: now),
                .success
            ),
            (
                "no data",
                QuotaSnapshot(
                    weeklyQuotaPercent: 0,
                    fiveHourQuotaPercent: 0,
                    weeklyQuotaState: .unavailable,
                    fiveHourQuotaState: .unavailable,
                    refreshedAt: now,
                    dataSource: .real,
                    quotaWindows: []
                ),
                .noSnapshot
            ),
            (
                "refresh failure retains successful snapshot",
                snapshot(windows: [
                    window("codex", "primary", .fiveHour, 81, resetAt: resetAt),
                    window("codex", "secondary", .weekly, 62)
                ], refreshedAt: now),
                .networkFailed
            ),
            (
                "empty reset credits",
                QuotaSnapshot(
                    weeklyQuotaPercent: 62,
                    fiveHourQuotaPercent: 81,
                    resetAvailableCount: 0,
                    resetCreditDetailsState: .appServerCountOnly,
                    resetCreditDetails: [],
                    refreshedAt: now,
                    dataSource: .real,
                    quotaWindows: [
                        window("codex", "primary", .fiveHour, 81, resetAt: resetAt),
                        window("codex", "secondary", .weekly, 62)
                    ]
                ),
                .success
            )
        ]

        for testCase in cases {
            let state = WidgetDisplayState.make(
                snapshot: testCase.snapshot,
                status: testCase.status,
                lastSuccessAt: testCase.status == .networkFailed ? now : now,
                lastAttemptAt: testCase.status == .networkFailed ? now.addingTimeInterval(10) : nil,
                effectiveFiveHourResetAt: resetAt,
                savedAt: now
            )
            let popoverItems = StatusPopoverFormatting.quotaWindowDisplayItems(
                snapshot: testCase.snapshot,
                status: testCase.status,
                now: now
            )
            let widgetItems = state.quotaItems(now: now)
            let widgetPresentation = WidgetPresentation(state: state, family: .medium, now: now)
            let widgetVisibleQuotas = [widgetPresentation.primaryQuota].compactMap { $0 }
                + widgetPresentation.supplementaryQuotas

            // The raw item equality covers every shared display field, while
            // this comparison also exercises the Widget's final medium layout.
            XCTAssertEqual(widgetItems, popoverItems, testCase.name)
            XCTAssertEqual(
                widgetVisibleQuotas,
                popoverItems.map(WidgetPresentation.Quota.init),
                testCase.name
            )
            XCTAssertEqual(widgetPresentation.overflowCount, 0, testCase.name)
            XCTAssertTrue(testCase.snapshot.resetCreditDetails.isEmpty, testCase.name)
        }
    }

    private func snapshot(windows: [QuotaWindow], refreshedAt: Date) -> QuotaSnapshot {
        QuotaSnapshot(
            weeklyQuotaPercent: windows.first(where: { $0.kind == .weekly })?.remainingPercent ?? 0,
            fiveHourQuotaPercent: windows.first(where: { $0.kind == .fiveHour })?.remainingPercent ?? 0,
            weeklyQuotaState: windows.contains(where: { $0.kind == .weekly }) ? .live : .unavailable,
            fiveHourQuotaState: windows.contains(where: { $0.kind == .fiveHour }) ? .live : .unavailable,
            refreshedAt: refreshedAt,
            dataSource: .real,
            quotaWindows: windows,
            accountBoundary: .testDefault
        )
    }

    private func window(
        _ limitId: String,
        _ windowId: String,
        _ kind: QuotaWindowKind,
        _ percent: Int,
        durationMinutes: Int? = nil,
        resetAt: Date? = nil
    ) -> QuotaWindow {
        QuotaWindow(
            limitId: limitId,
            windowId: windowId,
            kind: kind,
            durationMinutes: durationMinutes,
            remainingPercent: percent,
            resetAt: resetAt
        )
    }
}
