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

        XCTAssertEqual(formatted, "Today 08:05")
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

        XCTAssertEqual(formatted, "Updated Today 12:40")
    }

    func testSourceStatusLineUsesCompactPrimaryCopy() {
        XCTAssertEqual(
            StatusPopoverFormatting.sourceStatusLine(dataSource: .real, status: .success),
            "Real data · Connected"
        )
        XCTAssertEqual(
            StatusPopoverFormatting.sourceStatusLine(dataSource: .mock, status: .demoMode),
            "Demo data · Demo mode"
        )
    }

    func testTitleSummaryMatchesStatusState() {
        XCTAssertEqual(StatusPopoverFormatting.titleSummary(for: .success), "Quota looks healthy")
        XCTAssertEqual(StatusPopoverFormatting.titleSummary(for: .networkFailed), "Refresh failed")
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
