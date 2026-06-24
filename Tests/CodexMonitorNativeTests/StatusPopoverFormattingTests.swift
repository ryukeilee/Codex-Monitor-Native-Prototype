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
        XCTAssertEqual(StatusPopoverFormatting.titleSummary(for: .success), "数据已更新")
        XCTAssertEqual(StatusPopoverFormatting.titleSummary(for: .stale), "数据已过期")
        XCTAssertEqual(StatusPopoverFormatting.titleSummary(for: .networkFailed), "上次刷新失败")
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

    private func makeDate(_ iso8601: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: iso8601)!
    }
}

private extension Calendar {
    func setting(timeZone: TimeZone) -> Calendar {
        var calendar = self
        calendar.timeZone = timeZone
        return calendar
    }
}
