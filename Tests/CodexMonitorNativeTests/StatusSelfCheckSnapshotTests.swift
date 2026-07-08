import Foundation
import XCTest
@testable import CodexMonitorNative

@MainActor
final class StatusSelfCheckSnapshotTests: XCTestCase {
    func testFormattedVersionCombinesMarketingAndBuildVersion() {
        let bundle = try! makeBundle(
            info: [
                "CFBundleShortVersionString": "0.1.0",
                "CFBundleVersion": "7"
            ]
        )

        XCTAssertEqual(StatusSelfCheckSnapshot.formattedVersion(bundle: bundle), "0.1.0 (7)")
    }

    func testFormattedVersionFallsBackWhenBundleVersionMissing() {
        let bundle = try! makeBundle(info: [:])

        XCTAssertEqual(StatusSelfCheckSnapshot.formattedVersion(bundle: bundle), "未写入")
    }

    func testFormattedRefreshSummaryUsesUnrefreshedCopy() {
        XCTAssertEqual(
            StatusSelfCheckSnapshot.formattedRefreshSummary(lastSuccess: nil, lastAttempt: nil),
            "未刷新"
        )
    }

    func testFormattedWidgetSummaryShowsMissingStateFile() {
        XCTAssertEqual(
            StatusSelfCheckSnapshot.formattedWidgetSummary(state: nil, hasStateFile: false),
            "未写入"
        )
    }

    func testFormattedWidgetSummaryShowsSavedStatus() {
        let now = makeDate("2026-07-08T06:40:00Z")
        let state = WidgetDisplayState.make(
            snapshot: QuotaSnapshot(
                weeklyQuotaPercent: 78,
                fiveHourQuotaPercent: 64,
                refreshedAt: now.addingTimeInterval(-300),
                dataSource: .real
            ),
            status: .success,
            lastSuccessAt: now.addingTimeInterval(-300),
            lastAttemptAt: now.addingTimeInterval(-240),
            effectiveFiveHourResetAt: nil,
            savedAt: now
        )

        let summary = StatusSelfCheckSnapshot.formattedWidgetSummary(
            state: state,
            hasStateFile: true,
            now: now,
            calendar: calendar(timeZone: TimeZone(secondsFromGMT: 0)!),
            locale: Locale(identifier: "en_US"),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        XCTAssertEqual(summary, "最新数据 · 保存 今天 06:40")
    }

    private func makeDate(_ iso8601: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: iso8601)!
    }

    private func calendar(timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    private func makeBundle(info: [String: Any]) throws -> Bundle {
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexMonitorNativeTests.bundle.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let plistURL = bundleURL.appendingPathComponent("Info.plist")
        let data = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        )
        try data.write(to: plistURL)
        return try XCTUnwrap(Bundle(url: bundleURL))
    }
}
