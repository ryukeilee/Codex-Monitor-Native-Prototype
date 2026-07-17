import XCTest
@testable import CodexMonitorNative

final class QuotaRefreshServiceTests: XCTestCase {
    func testRefreshEnrichesAppServerCountOnlySnapshotWithResetCreditDetails() async throws {
        let earlyExpiry = makeDate("2026-06-19T18:00:00Z")
        let lateExpiry = makeDate("2026-06-20T12:00:00Z")
        let appServerSnapshot = QuotaSnapshot(
            weeklyQuotaPercent: 70,
            fiveHourQuotaPercent: 64,
            resetAvailableCount: 1,
            resetCreditDetailsState: .appServerCountOnly,
            fiveHourResetAt: makeDate("2026-06-19T14:10:00Z"),
            refreshedAt: makeDate("2026-06-19T12:40:00Z"),
            dataSource: .real,
            accountBoundary: .testDefault
        )
        let details = ResetCreditsDetailPayload(
            availableCount: 2,
            availableCredits: [
                ResetCreditDetailSnapshot(
                    ordinal: 1,
                    status: "available",
                    grantedAt: makeDate("2026-06-19T10:00:00Z"),
                    expiresAt: earlyExpiry
                ),
                ResetCreditDetailSnapshot(
                    ordinal: 2,
                    status: "available",
                    grantedAt: makeDate("2026-06-19T12:00:00Z"),
                    expiresAt: lateExpiry
                )
            ],
            statusSummary: [ResetCreditStatusSummary(status: "available", count: 2)]
        )

        let service = QuotaRefreshService(
            realProvider: StubRealQuotaProvider(snapshot: appServerSnapshot),
            resetCreditsDetailProvider: SucceedingResetCreditsProvider(payload: details),
            mockProvider: MockQuotaProvider()
        )

        let refreshed = try await service.refresh(basedOn: QuotaSnapshot.notConnected)

        XCTAssertEqual(refreshed.resetAvailableCount, 2)
        XCTAssertEqual(refreshed.resetCreditDetailsState, .detailed)
        XCTAssertNil(refreshed.resetCreditDiagnostic)
        XCTAssertEqual(refreshed.resetCreditDetails.compactMap(\.expiresAt), [earlyExpiry, lateExpiry])
        XCTAssertEqual(refreshed.resetCreditDetails.compactMap(\.expiresAt).min(), earlyExpiry)
        XCTAssertEqual(refreshed.resetCreditStatusSummary, [ResetCreditStatusSummary(status: "available", count: 2)])
    }

    func testRefreshFallsBackToAppServerCountWhenResetCreditDetailsFail() async throws {
        let appServerSnapshot = QuotaSnapshot(
            weeklyQuotaPercent: 70,
            fiveHourQuotaPercent: 64,
            resetAvailableCount: 5,
            resetCreditDetailsState: .appServerCountOnly,
            fiveHourResetAt: makeDate("2026-06-19T14:10:00Z"),
            refreshedAt: makeDate("2026-06-19T12:40:00Z"),
            dataSource: .real,
            accountBoundary: .testDefault
        )

        let service = QuotaRefreshService(
            realProvider: StubRealQuotaProvider(snapshot: appServerSnapshot),
            resetCreditsDetailProvider: FailingResetCreditsProvider(),
            mockProvider: MockQuotaProvider()
        )

        let refreshed = try await service.refresh(basedOn: QuotaSnapshot.notConnected)

        XCTAssertEqual(refreshed.resetAvailableCount, 5)
        XCTAssertEqual(refreshed.resetCreditDetailsState, ResetCreditDetailsState.unavailable)
        XCTAssertEqual(refreshed.resetCreditDiagnostic?.summary, "HTTP 状态码 503")
        XCTAssertTrue(refreshed.resetCreditDetails.isEmpty)
        XCTAssertTrue(refreshed.resetCreditStatusSummary.isEmpty)
    }

    func testRefreshKeepsMatchingUnexpiredResetCreditTimesWhenDetailRefreshFails() async throws {
        let earlyExpiry = makeDate("2026-06-19T18:00:00Z")
        let lateExpiry = makeDate("2026-06-20T12:00:00Z")
        let previous = QuotaSnapshot(
            weeklyQuotaPercent: 70,
            fiveHourQuotaPercent: 64,
            resetAvailableCount: 2,
            resetCreditDetailsState: .detailed,
            resetCreditDetails: [
                ResetCreditDetailSnapshot(
                    ordinal: 1,
                    status: "available",
                    grantedAt: makeDate("2026-06-19T10:00:00Z"),
                    expiresAt: earlyExpiry
                ),
                ResetCreditDetailSnapshot(
                    ordinal: 2,
                    status: "available",
                    grantedAt: makeDate("2026-06-19T12:00:00Z"),
                    expiresAt: lateExpiry
                )
            ],
            resetCreditStatusSummary: [ResetCreditStatusSummary(status: "available", count: 2)],
            refreshedAt: makeDate("2026-06-19T12:40:00Z"),
            dataSource: .real,
            accountBoundary: .testDefault
        )
        let appServerSnapshot = QuotaSnapshot(
            weeklyQuotaPercent: 69,
            fiveHourQuotaPercent: 63,
            resetAvailableCount: 2,
            resetCreditDetailsState: .appServerCountOnly,
            refreshedAt: makeDate("2026-06-19T12:45:00Z"),
            dataSource: .real,
            accountBoundary: .testDefault
        )
        let service = QuotaRefreshService(
            realProvider: StubRealQuotaProvider(snapshot: appServerSnapshot),
            resetCreditsDetailProvider: FailingResetCreditsProvider(),
            mockProvider: MockQuotaProvider()
        )

        let refreshed = try await service.refresh(basedOn: previous)

        XCTAssertEqual(refreshed.resetAvailableCount, 2)
        XCTAssertEqual(refreshed.resetCreditDetailsState, .unavailable)
        XCTAssertEqual(refreshed.resetCreditDiagnostic?.summary, "HTTP 状态码 503")
        XCTAssertEqual(refreshed.resetCreditDetails.compactMap(\.expiresAt), [earlyExpiry, lateExpiry])
        XCTAssertEqual(
            refreshed.resetCreditStatusSummary,
            [ResetCreditStatusSummary(status: "available", count: 2)]
        )

        let refreshedAgain = try await service.refresh(basedOn: refreshed)

        XCTAssertEqual(refreshedAgain.resetCreditDetails.compactMap(\.expiresAt), [earlyExpiry, lateExpiry])
        XCTAssertEqual(refreshedAgain.resetCreditDetailsState, .unavailable)
    }

    func testRefreshDropsCachedResetCreditTimesWhenAvailableCountChanges() async throws {
        let previous = QuotaSnapshot(
            weeklyQuotaPercent: 70,
            fiveHourQuotaPercent: 64,
            resetAvailableCount: 2,
            resetCreditDetailsState: .detailed,
            resetCreditDetails: [
                ResetCreditDetailSnapshot(
                    ordinal: 1,
                    status: "available",
                    grantedAt: nil,
                    expiresAt: makeDate("2026-06-19T18:00:00Z")
                )
            ],
            refreshedAt: makeDate("2026-06-19T12:40:00Z"),
            dataSource: .real,
            accountBoundary: .testDefault
        )
        let appServerSnapshot = QuotaSnapshot(
            weeklyQuotaPercent: 69,
            fiveHourQuotaPercent: 63,
            resetAvailableCount: 1,
            resetCreditDetailsState: .appServerCountOnly,
            refreshedAt: makeDate("2026-06-19T12:45:00Z"),
            dataSource: .real,
            accountBoundary: .testDefault
        )
        let service = QuotaRefreshService(
            realProvider: StubRealQuotaProvider(snapshot: appServerSnapshot),
            resetCreditsDetailProvider: FailingResetCreditsProvider(),
            mockProvider: MockQuotaProvider()
        )

        let refreshed = try await service.refresh(basedOn: previous)

        XCTAssertEqual(refreshed.resetAvailableCount, 1)
        XCTAssertTrue(refreshed.resetCreditDetails.isEmpty)
        XCTAssertTrue(refreshed.resetCreditStatusSummary.isEmpty)
    }

    func testRefreshMergesPartialRPCFieldsWithCurrentRealSnapshot() async throws {
        let current = QuotaSnapshot(
            weeklyQuotaPercent: 70,
            fiveHourQuotaPercent: 64,
            refreshedAt: makeDate("2026-06-19T12:40:00Z"),
            dataSource: .real,
            accountBoundary: .testDefault
        )
        let partial = QuotaSnapshot(
            weeklyQuotaPercent: 0,
            fiveHourQuotaPercent: 58,
            weeklyQuotaState: .unavailable,
            fiveHourQuotaState: .live,
            refreshedAt: makeDate("2026-06-19T12:45:00Z"),
            dataSource: .real,
            accountBoundary: .testDefault
        )
        let service = QuotaRefreshService(
            realProvider: StubRealQuotaProvider(snapshot: partial),
            resetCreditsDetailProvider: FailingResetCreditsProvider(),
            mockProvider: MockQuotaProvider()
        )

        let refreshed = try await service.refresh(basedOn: current)

        XCTAssertEqual(refreshed.weeklyQuotaPercent, 70)
        XCTAssertEqual(refreshed.weeklyQuotaState, .cached)
        XCTAssertEqual(refreshed.fiveHourQuotaPercent, 58)
        XCTAssertEqual(refreshed.fiveHourQuotaState, .live)
    }

    func testRefreshDoesNotMergeCachedFieldsAcrossAccountBoundary() async throws {
        let current = QuotaSnapshot(
            weeklyQuotaPercent: 70,
            fiveHourQuotaPercent: 64,
            resetAvailableCount: 1,
            resetCreditDetailsState: .detailed,
            resetCreditDetails: [
                ResetCreditDetailSnapshot(
                    ordinal: 1,
                    status: "available",
                    grantedAt: nil,
                    expiresAt: makeDate("2026-06-20T12:00:00Z")
                )
            ],
            refreshedAt: makeDate("2026-06-19T12:40:00Z"),
            dataSource: .real,
            accountBoundary: .testDefault
        )
        let switchedAccountPartial = QuotaSnapshot(
            weeklyQuotaPercent: 0,
            fiveHourQuotaPercent: 58,
            weeklyQuotaState: .unavailable,
            fiveHourQuotaState: .live,
            resetAvailableCount: 1,
            refreshedAt: makeDate("2026-06-19T12:45:00Z"),
            dataSource: .real,
            accountBoundary: .testOtherAccount
        )
        let service = QuotaRefreshService(
            realProvider: StubRealQuotaProvider(snapshot: switchedAccountPartial),
            resetCreditsDetailProvider: FailingResetCreditsProvider(),
            mockProvider: MockQuotaProvider()
        )

        let refreshed = try await service.refresh(basedOn: current)

        XCTAssertEqual(refreshed.weeklyQuotaPercent, 0)
        XCTAssertEqual(refreshed.weeklyQuotaState, .unavailable)
        XCTAssertEqual(refreshed.fiveHourQuotaPercent, 58)
        XCTAssertTrue(refreshed.resetCreditDetails.isEmpty)
        XCTAssertEqual(refreshed.accountBoundary, .testOtherAccount)
    }

    func testRefreshRejectsUnboundRealSnapshot() async {
        let unbound = QuotaSnapshot(
            weeklyQuotaPercent: 70,
            fiveHourQuotaPercent: 64,
            refreshedAt: makeDate("2026-06-19T12:40:00Z"),
            dataSource: .real
        )
        let service = QuotaRefreshService(
            realProvider: StubRealQuotaProvider(snapshot: unbound),
            resetCreditsDetailProvider: FailingResetCreditsProvider(),
            mockProvider: MockQuotaProvider()
        )

        do {
            _ = try await service.refresh(basedOn: .notConnected)
            XCTFail("Expected account identity validation failure")
        } catch let error as RealQuotaError {
            XCTAssertEqual(error, .accountIdentityUnavailable)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func makeDate(_ iso8601: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: iso8601)!
    }
}

private struct StubRealQuotaProvider: RealQuotaRefreshing, Sendable {
    let snapshot: QuotaSnapshot

    func fetchQuota() async throws -> QuotaSnapshot {
        snapshot
    }
}

private struct FailingResetCreditsProvider: ResetCreditsDetailRefreshing, Sendable {
    func fetchDetails() async throws -> ResetCreditsDetailPayload {
        throw ResetCreditsDetailError.unexpectedStatusCode(503)
    }
}

private struct SucceedingResetCreditsProvider: ResetCreditsDetailRefreshing, Sendable {
    let payload: ResetCreditsDetailPayload

    func fetchDetails() async throws -> ResetCreditsDetailPayload {
        payload
    }
}
