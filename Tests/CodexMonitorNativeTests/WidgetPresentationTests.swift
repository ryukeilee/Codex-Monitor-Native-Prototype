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

    private func quota(
        id: String,
        label: String,
        percent: Int?,
        progress: Double?
    ) -> StatusPopoverFormatting.QuotaWindowDisplayItem {
        StatusPopoverFormatting.QuotaWindowDisplayItem(
            id: id,
            semanticIdentity: id,
            kind: .unknown,
            label: label,
            percentText: percent.map { "\($0)%" } ?? "--",
            historyCaption: nil,
            trustedPercent: percent,
            progress: progress,
            fieldState: .live,
            stateText: "当前",
            resetAt: nil,
            resetText: "未暴露",
            resetRemainingText: "未暴露",
            origin: .dynamic
        )
    }
}
