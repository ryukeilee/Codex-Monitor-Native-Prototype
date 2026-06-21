import XCTest
@testable import CodexMonitorNative

final class QuotaDecisionTests: XCTestCase {
    func testDecisionIsSafeWhenBothQuotasAreComfortable() {
        let snapshot = QuotaSnapshot(
            weeklyQuotaPercent: 68,
            fiveHourQuotaPercent: 72,
            refreshedAt: .now,
            dataSource: .real
        )

        let decision = QuotaDecisionEngine.evaluate(snapshot: snapshot, hasUsableRealData: true)

        XCTAssertEqual(decision.level, .safe)
        XCTAssertEqual(decision.recommendation, "可以继续正常使用")
    }

    func testDecisionIsObserveWhenQuotaNeedsAttention() {
        let snapshot = QuotaSnapshot(
            weeklyQuotaPercent: 55,
            fiveHourQuotaPercent: 40,
            refreshedAt: .now,
            dataSource: .real
        )

        let decision = QuotaDecisionEngine.evaluate(snapshot: snapshot, hasUsableRealData: true)

        XCTAssertEqual(decision.level, .observe)
        XCTAssertEqual(decision.recommendation, "留意消耗，优先短任务")
    }

    func testDecisionIsConserveWhenQuotaIsTight() {
        let snapshot = QuotaSnapshot(
            weeklyQuotaPercent: 14,
            fiveHourQuotaPercent: 48,
            refreshedAt: .now,
            dataSource: .real
        )

        let decision = QuotaDecisionEngine.evaluate(snapshot: snapshot, hasUsableRealData: true)

        XCTAssertEqual(decision.level, .conserve)
        XCTAssertEqual(decision.recommendation, "建议只做轻量修复")
    }

    func testDecisionIsStopWhenQuotaIsNearlyExhausted() {
        let snapshot = QuotaSnapshot(
            weeklyQuotaPercent: 22,
            fiveHourQuotaPercent: 9,
            refreshedAt: .now,
            dataSource: .real
        )

        let decision = QuotaDecisionEngine.evaluate(snapshot: snapshot, hasUsableRealData: true)

        XCTAssertEqual(decision.level, .stop)
        XCTAssertEqual(decision.recommendation, "暂停大任务，等待恢复")
    }

    func testRecoveryFallsBackToFiveHoursAfterRefreshWhenResetTimeIsMissing() {
        let refreshedAt = Date(timeIntervalSince1970: 1_718_000_000)
        let snapshot = QuotaSnapshot(
            weeklyQuotaPercent: 60,
            fiveHourQuotaPercent: 50,
            refreshedAt: refreshedAt,
            dataSource: .real
        )

        let resetAt = QuotaDecisionEngine.effectiveFiveHourResetAt(for: snapshot, hasUsableRealData: true)

        XCTAssertEqual(resetAt, refreshedAt.addingTimeInterval(5 * 60 * 60))
    }
}
