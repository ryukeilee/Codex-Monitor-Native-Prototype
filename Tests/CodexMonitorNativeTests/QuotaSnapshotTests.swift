import XCTest
@testable import CodexMonitorNative

/// Characterization coverage for the account-bound cache merge performed by
/// `QuotaSnapshot.mergingPartial(with:)`. The dynamic-window merge must keep
/// live windows authoritative, fall back to cached values for non-current
/// windows, preserve duplicate semantic identities, and stay ordered by id.
final class QuotaSnapshotTests: XCTestCase {
    private let cachedReset = Date(timeIntervalSince1970: 500)
    private let currentReset = Date(timeIntervalSince1970: 900)

    private func makeSnapshot(
        windows: [QuotaWindow],
        boundary: QuotaAccountBoundary? = .testDefault
    ) -> QuotaSnapshot {
        QuotaSnapshot(
            weeklyQuotaPercent: 0,
            fiveHourQuotaPercent: 0,
            weeklyQuotaState: .unavailable,
            fiveHourQuotaState: .unavailable,
            refreshedAt: Date(timeIntervalSince1970: 100),
            dataSource: .real,
            quotaWindows: windows,
            accountBoundary: boundary
        )
    }

    func testMergeWithoutWindowsOnEitherSideReturnsEmpty() {
        let merged = makeSnapshot(windows: []).mergingPartial(with: makeSnapshot(windows: []))

        XCTAssertTrue(merged.quotaWindows.isEmpty)
    }

    func testMergeKeepsLiveWindowAndDoesNotAppendCachedWindowOfSameSemanticIdentity() {
        let cached = makeSnapshot(windows: [
            QuotaWindow(
                limitId: "codex",
                windowId: "secondary",
                kind: .weekly,
                durationMinutes: 10080,
                remainingPercent: 65,
                resetAt: cachedReset
            )
        ])
        let current = makeSnapshot(windows: [
            QuotaWindow(
                limitId: "codex",
                windowId: "secondary",
                kind: .weekly,
                durationMinutes: 10080,
                remainingPercent: 40,
                state: .live,
                resetAt: currentReset
            )
        ])

        let merged = current.mergingPartial(with: cached)

        XCTAssertEqual(merged.quotaWindows, [
            QuotaWindow(
                limitId: "codex",
                windowId: "secondary",
                kind: .weekly,
                durationMinutes: 10080,
                remainingPercent: 40,
                state: .live,
                resetAt: currentReset
            )
        ])
    }

    func testMergeFallsBackToFirstDisplayableCachedWindowPerSemanticIdentity() {
        let cached = makeSnapshot(windows: [
            QuotaWindow(
                limitId: "codex",
                windowId: "primary",
                kind: .fiveHour,
                durationMinutes: 300,
                remainingPercent: 12,
                state: .invalid
            ),
            QuotaWindow(
                limitId: "codex",
                windowId: "primary",
                kind: .fiveHour,
                durationMinutes: 300,
                remainingPercent: 70,
                resetAt: cachedReset
            ),
            QuotaWindow(
                limitId: "codex_other",
                windowId: "primary",
                kind: .fiveHour,
                durationMinutes: 300,
                remainingPercent: 55,
                state: .cached
            )
        ])
        let current = makeSnapshot(windows: [
            QuotaWindow(
                limitId: "codex",
                windowId: "primary",
                kind: .fiveHour,
                remainingPercent: 0,
                state: .unavailable
            )
        ])

        let merged = current.mergingPartial(with: cached)

        XCTAssertEqual(merged.quotaWindows, [
            QuotaWindow(
                limitId: "codex",
                windowId: "primary",
                kind: .fiveHour,
                durationMinutes: 300,
                remainingPercent: 70,
                state: .cached,
                resetAt: cachedReset
            )
        ])
    }

    func testMergeMarksInvalidAndCachedCurrentWindowsAsCachedFromCache() {
        let cached = makeSnapshot(windows: [
            QuotaWindow(
                limitId: "codex",
                windowId: "primary",
                kind: .fiveHour,
                durationMinutes: 300,
                remainingPercent: 74
            ),
            QuotaWindow(
                limitId: "codex",
                windowId: "secondary",
                kind: .weekly,
                durationMinutes: 10080,
                remainingPercent: 64
            )
        ])
        let current = makeSnapshot(windows: [
            QuotaWindow(
                limitId: "codex",
                windowId: "primary",
                kind: .fiveHour,
                remainingPercent: 3,
                state: .invalid
            ),
            QuotaWindow(
                limitId: "codex",
                windowId: "secondary",
                kind: .weekly,
                remainingPercent: 5,
                state: .cached
            )
        ])

        let merged = current.mergingPartial(with: cached)

        XCTAssertEqual(merged.quotaWindows.map(\.state), [.cached, .cached])
        XCTAssertEqual(merged.quotaWindows.map(\.remainingPercent), [74, 64])
    }

    func testMergePrefersCurrentDurationAndResetAtOverCachedValues() {
        let cached = makeSnapshot(windows: [
            QuotaWindow(
                limitId: "codex",
                windowId: "primary",
                kind: .fiveHour,
                durationMinutes: 300,
                remainingPercent: 80,
                resetAt: cachedReset
            ),
            QuotaWindow(
                limitId: "codex",
                windowId: "secondary",
                kind: .weekly,
                durationMinutes: 10080,
                remainingPercent: 60,
                resetAt: cachedReset
            )
        ])
        let current = makeSnapshot(windows: [
            QuotaWindow(
                limitId: "codex",
                windowId: "primary",
                kind: .fiveHour,
                remainingPercent: 0,
                state: .unavailable
            ),
            QuotaWindow(
                limitId: "codex",
                windowId: "secondary",
                kind: .weekly,
                durationMinutes: 20000,
                remainingPercent: 0,
                state: .unavailable,
                resetAt: currentReset
            )
        ])

        let merged = current.mergingPartial(with: cached)

        XCTAssertEqual(merged.quotaWindows.map(\.durationMinutes), [300, 20000])
        XCTAssertEqual(merged.quotaWindows.map(\.resetAt), [cachedReset, currentReset])
    }

    func testMergeAppendsUnmatchedDisplayableCachedWindowsInCacheOrderKeepingDuplicateIdentities() {
        let current = makeSnapshot(windows: [
            QuotaWindow(
                limitId: "codex",
                windowId: "primary",
                kind: .fiveHour,
                durationMinutes: 300,
                remainingPercent: 90
            )
        ])
        let cached = makeSnapshot(windows: [
            QuotaWindow(
                limitId: "codex",
                windowId: "secondary",
                kind: .weekly,
                durationMinutes: 10080,
                remainingPercent: 60
            ),
            QuotaWindow(
                limitId: "codex",
                windowId: "primary",
                kind: .fiveHour,
                remainingPercent: 10
            ),
            QuotaWindow(
                limitId: "codex_other",
                windowId: "secondary",
                kind: .weekly,
                remainingPercent: 30
            ),
            QuotaWindow(
                limitId: "codex",
                windowId: "future",
                kind: .unknown,
                remainingPercent: 20
            ),
            QuotaWindow(
                limitId: "codex",
                windowId: "tertiary",
                kind: .weekly,
                remainingPercent: 5,
                state: .unavailable
            )
        ])

        let merged = current.mergingPartial(with: cached)

        XCTAssertEqual(
            merged.quotaWindows.map(\.id),
            ["codex.future", "codex.primary", "codex.secondary", "codex_other.secondary"]
        )
        XCTAssertEqual(merged.quotaWindows.map(\.remainingPercent), [20, 90, 60, 30])
        XCTAssertEqual(merged.quotaWindows.map(\.state), [.cached, .live, .cached, .cached])
    }

    func testMergeLeavesNonCurrentWindowUnchangedWhenCacheHasNoMatchingIdentity() {
        let current = makeSnapshot(windows: [
            QuotaWindow(
                limitId: "codex",
                windowId: "monthly",
                kind: .monthly,
                durationMinutes: 43200,
                remainingPercent: 0,
                state: .unavailable,
                resetAt: currentReset
            )
        ])
        let cached = makeSnapshot(windows: [
            QuotaWindow(
                limitId: "codex",
                windowId: "secondary",
                kind: .weekly,
                remainingPercent: 50
            )
        ])

        let merged = current.mergingPartial(with: cached)

        XCTAssertEqual(merged.quotaWindows.map(\.id), ["codex.monthly", "codex.secondary"])
        XCTAssertEqual(merged.quotaWindows[0].state, .unavailable)
        XCTAssertEqual(merged.quotaWindows[0].resetAt, currentReset)
        XCTAssertEqual(merged.quotaWindows[1].state, .cached)
    }

    func testMergeIsSkippedWhenAccountBoundaryDoesNotMatch() {
        let cached = makeSnapshot(
            windows: [
                QuotaWindow(
                    limitId: "codex",
                    windowId: "primary",
                    kind: .fiveHour,
                    durationMinutes: 300,
                    remainingPercent: 70
                )
            ],
            boundary: .testOtherAccount
        )
        let current = makeSnapshot(windows: [
            QuotaWindow(
                limitId: "codex",
                windowId: "primary",
                kind: .fiveHour,
                remainingPercent: 0,
                state: .unavailable
            )
        ])

        let merged = current.mergingPartial(with: cached)

        XCTAssertEqual(merged.quotaWindows, current.quotaWindows)
    }
}
