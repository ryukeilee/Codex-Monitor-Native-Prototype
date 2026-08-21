import XCTest

@testable import CodexMonitorNative

final class QuotaCardDensityPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    func testLiveWindowWithTrustedPercentHidesRedundantFreshnessBadge() {
        // "最新" duplicates the popover header status line.
        XCTAssertFalse(QuotaCardDensityPolicy.showsStateBadge(
            fieldState: .live,
            trustedPercent: 42,
            resetAt: now.addingTimeInterval(3_600),
            now: now
        ))
    }

    func testCachedWindowWithTrustedPercentHidesBadgeDuplicatedByHistoryCaption() {
        // The cached-history caption next to the percentage already carries
        // the "历史缓存" signal.
        XCTAssertFalse(QuotaCardDensityPolicy.showsStateBadge(
            fieldState: .cached,
            trustedPercent: 42,
            resetAt: now.addingTimeInterval(3_600),
            now: now
        ))
    }

    func testLiveWindowWithoutResetTimeKeepsBadgeHidden() {
        XCTAssertFalse(QuotaCardDensityPolicy.showsStateBadge(
            fieldState: .live,
            trustedPercent: 96,
            resetAt: nil,
            now: now
        ))
    }

    func testInvalidAndUnavailableWindowsKeepAnomalyBadge() {
        XCTAssertTrue(QuotaCardDensityPolicy.showsStateBadge(
            fieldState: .invalid,
            trustedPercent: nil,
            resetAt: nil,
            now: now
        ))
        XCTAssertTrue(QuotaCardDensityPolicy.showsStateBadge(
            fieldState: .unavailable,
            trustedPercent: nil,
            resetAt: now.addingTimeInterval(3_600),
            now: now
        ))
    }

    func testWindowPastResetDeadlineKeepsPendingRefreshBadge() {
        // After the reset deadline passes, the card shows "--" and only the
        // badge explains "已恢复，待刷新".
        XCTAssertTrue(QuotaCardDensityPolicy.showsStateBadge(
            fieldState: .live,
            trustedPercent: nil,
            resetAt: now.addingTimeInterval(-60),
            now: now
        ))
        XCTAssertTrue(QuotaCardDensityPolicy.showsStateBadge(
            fieldState: .cached,
            trustedPercent: nil,
            resetAt: now.addingTimeInterval(-60),
            now: now
        ))
    }

    func testResetDeadlineBoundaryStaysAuthoritative() {
        // QuotaTemporalSemantics.isPending uses the strict `now < deadline`
        // boundary: at exactly the deadline the window already counts as
        // recovered, matching makeQuotaWindowDisplayItem's isBeforeReset, so
        // the pending-refresh badge appears from the deadline onward.
        XCTAssertFalse(QuotaCardDensityPolicy.showsStateBadge(
            fieldState: .live,
            trustedPercent: nil,
            resetAt: now.addingTimeInterval(60),
            now: now
        ))
        XCTAssertTrue(QuotaCardDensityPolicy.showsStateBadge(
            fieldState: .live,
            trustedPercent: nil,
            resetAt: now,
            now: now
        ))
        XCTAssertTrue(QuotaCardDensityPolicy.showsStateBadge(
            fieldState: .live,
            trustedPercent: nil,
            resetAt: now.addingTimeInterval(-1),
            now: now
        ))
    }
}
