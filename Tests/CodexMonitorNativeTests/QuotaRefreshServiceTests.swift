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
            mockProvider: MockQuotaProvider(),
            currentAccountBoundary: { .testDefault }
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
            mockProvider: MockQuotaProvider(),
            currentAccountBoundary: { .testDefault }
        )

        let refreshed = try await service.refresh(basedOn: QuotaSnapshot.notConnected)

        XCTAssertEqual(refreshed.resetAvailableCount, 5)
        XCTAssertEqual(refreshed.resetCreditDetailsState, ResetCreditDetailsState.unavailable)
        XCTAssertEqual(refreshed.resetCreditDiagnostic?.summary, "HTTP 状态码 503")
        XCTAssertTrue(refreshed.resetCreditDetails.isEmpty)
        XCTAssertTrue(refreshed.resetCreditStatusSummary.isEmpty)
    }

    func testRefreshTreatsNoAvailableCreditsAsNormalAppServerCountState() async throws {
        let appServerSnapshot = QuotaSnapshot(
            weeklyQuotaPercent: 70,
            fiveHourQuotaPercent: 64,
            resetAvailableCount: 0,
            resetCreditDetailsState: .appServerCountOnly,
            fiveHourResetAt: makeDate("2026-06-19T14:10:00Z"),
            refreshedAt: makeDate("2026-06-19T12:40:00Z"),
            dataSource: .real,
            accountBoundary: .testDefault
        )

        let service = QuotaRefreshService(
            realProvider: StubRealQuotaProvider(snapshot: appServerSnapshot),
            resetCreditsDetailProvider: NoAvailableCreditsProvider(),
            mockProvider: MockQuotaProvider(),
            currentAccountBoundary: { .testDefault }
        )

        let refreshed = try await service.refresh(basedOn: QuotaSnapshot.notConnected)

        XCTAssertEqual(refreshed.resetAvailableCount, 0)
        XCTAssertEqual(refreshed.resetCreditDetailsState, .appServerCountOnly)
        XCTAssertNil(refreshed.resetCreditDiagnostic)
        XCTAssertTrue(refreshed.resetCreditDetails.isEmpty)
        XCTAssertTrue(refreshed.resetCreditStatusSummary.isEmpty)
    }

    func testResetCreditOutcomesShareQuotaProjectionAndClearRawAppServerFields() async throws {
        // The three outcomes must differ only in their reset-credit fields; the
        // rest of the refreshed snapshot is projected unchanged.
        let refreshedAt = makeDate("2026-06-19T12:40:00Z")
        let fiveHourResetAt = makeDate("2026-06-19T14:10:00Z")
        let weeklyWindow = QuotaWindow(
            limitId: "codex",
            windowId: "weekly",
            kind: .weekly,
            durationMinutes: 10080,
            remainingPercent: 70,
            resetAt: makeDate("2026-06-26T12:00:00Z")
        )
        let weeklyBank = ResetBankSnapshot(
            limitId: "codex",
            windowId: "weekly",
            displayName: "周额度",
            remainingPercent: 70,
            resetAt: makeDate("2026-06-26T12:00:00Z")
        )
        let appServerSnapshot = QuotaSnapshot(
            weeklyQuotaPercent: 70,
            fiveHourQuotaPercent: 64,
            // Non-default states and schema version, so a projection that
            // relies on initializer defaults cannot pass this test.
            weeklyQuotaState: .cached,
            fiveHourQuotaState: .invalid,
            resetAvailableCount: 1,
            resetCreditDetailsState: .appServerCountOnly,
            resetCreditTimeEntries: [
                ResetCreditTimeSnapshot(
                    label: "reset",
                    date: makeDate("2026-06-19T18:00:00Z"),
                    sourcePath: "rateLimits.primaryResetAt"
                )
            ],
            resetCreditRawFields: [
                ResetCreditRawField(path: "credits.available", value: "1")
            ],
            fiveHourResetAt: fiveHourResetAt,
            resetBanks: [weeklyBank],
            refreshedAt: refreshedAt,
            dataSource: .real,
            errorMessage: "app-server note",
            schemaVersion: 7,
            quotaWindows: [weeklyWindow],
            accountBoundary: .testDefault
        )
        // A payload without a count must keep the app-server count; the
        // override direction is covered by
        // testRefreshEnrichesAppServerCountOnlySnapshotWithResetCreditDetails.
        let details = ResetCreditsDetailPayload(
            availableCount: nil,
            availableCredits: [
                ResetCreditDetailSnapshot(
                    ordinal: 1,
                    status: "available",
                    grantedAt: nil,
                    expiresAt: makeDate("2026-06-19T18:00:00Z")
                )
            ],
            statusSummary: [ResetCreditStatusSummary(status: "available", count: 1)]
        )

        func makeService(
            detailProvider: any ResetCreditsDetailRefreshing
        ) -> QuotaRefreshService {
            QuotaRefreshService(
                realProvider: StubRealQuotaProvider(snapshot: appServerSnapshot),
                resetCreditsDetailProvider: detailProvider,
                mockProvider: MockQuotaProvider(),
                currentAccountBoundary: { .testDefault }
            )
        }

        let succeeded = try await makeService(
            detailProvider: SucceedingResetCreditsProvider(payload: details)
        ).refresh(basedOn: .notConnected)
        let emptyFromServer = try await makeService(
            detailProvider: NoAvailableCreditsProvider()
        ).refresh(basedOn: .notConnected)
        let failed = try await makeService(
            detailProvider: FailingResetCreditsProvider()
        ).refresh(basedOn: .notConnected)

        XCTAssertEqual(succeeded.resetCreditDetailsState, .detailed)
        XCTAssertEqual(emptyFromServer.resetCreditDetailsState, .appServerCountOnly)
        XCTAssertEqual(failed.resetCreditDetailsState, .unavailable)
        XCTAssertEqual(succeeded.resetCreditDetails, details.availableCredits)
        XCTAssertEqual(succeeded.resetCreditStatusSummary, details.statusSummary)
        XCTAssertNil(succeeded.resetCreditDiagnostic)
        XCTAssertNil(emptyFromServer.resetCreditDiagnostic)
        XCTAssertEqual(failed.resetCreditDiagnostic?.summary, "HTTP 状态码 503")

        for refreshed in [succeeded, emptyFromServer, failed] {
            XCTAssertEqual(refreshed.weeklyQuotaPercent, 70)
            XCTAssertEqual(refreshed.fiveHourQuotaPercent, 64)
            XCTAssertEqual(refreshed.weeklyQuotaState, .cached)
            XCTAssertEqual(refreshed.fiveHourQuotaState, .invalid)
            XCTAssertEqual(refreshed.resetAvailableCount, 1)
            XCTAssertEqual(refreshed.fiveHourResetAt, fiveHourResetAt)
            XCTAssertEqual(refreshed.resetBanks, [weeklyBank])
            XCTAssertEqual(refreshed.quotaWindows, [weeklyWindow])
            XCTAssertEqual(refreshed.refreshedAt, refreshedAt)
            XCTAssertEqual(refreshed.dataSource, .real)
            XCTAssertEqual(refreshed.errorMessage, "app-server note")
            XCTAssertEqual(refreshed.schemaVersion, 7)
            XCTAssertEqual(refreshed.accountBoundary, .testDefault)
            // The detail provider owns the reset-credit presentation on this
            // path, so the raw app-server rendering never survives it.
            XCTAssertTrue(refreshed.resetCreditTimeEntries.isEmpty)
            XCTAssertTrue(refreshed.resetCreditRawFields.isEmpty)
        }
    }

    func testRefreshKeepsUnavailableFallbackWhenNoAvailableCreditsButReusableDetailsExist() async throws {
        let earlyExpiry = makeDate("2026-06-19T18:00:00Z")
        let previous = QuotaSnapshot(
            weeklyQuotaPercent: 70,
            fiveHourQuotaPercent: 64,
            resetAvailableCount: 1,
            resetCreditDetailsState: .detailed,
            resetCreditDetails: [
                ResetCreditDetailSnapshot(
                    ordinal: 1,
                    status: "available",
                    grantedAt: makeDate("2026-06-19T10:00:00Z"),
                    expiresAt: earlyExpiry
                )
            ],
            resetCreditStatusSummary: [ResetCreditStatusSummary(status: "available", count: 1)],
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
            resetCreditsDetailProvider: NoAvailableCreditsProvider(),
            mockProvider: MockQuotaProvider(),
            currentAccountBoundary: { .testDefault }
        )

        let refreshed = try await service.refresh(basedOn: previous)

        XCTAssertEqual(refreshed.resetAvailableCount, 1)
        XCTAssertEqual(refreshed.resetCreditDetailsState, .unavailable)
        XCTAssertEqual(refreshed.resetCreditDiagnostic?.summary, "没有 available credits")
        XCTAssertEqual(refreshed.resetCreditDetails.compactMap(\.expiresAt), [earlyExpiry])
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
            mockProvider: MockQuotaProvider(),
            currentAccountBoundary: { .testDefault }
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
            mockProvider: MockQuotaProvider(),
            currentAccountBoundary: { .testDefault }
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
            mockProvider: MockQuotaProvider(),
            currentAccountBoundary: { .testDefault }
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
            mockProvider: MockQuotaProvider(),
            currentAccountBoundary: { .testOtherAccount }
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
            mockProvider: MockQuotaProvider(),
            currentAccountBoundary: { nil }
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

    func testRefreshBindsResetCreditDetailsToRealSnapshotAccount() async throws {
        let recorder = RefreshCallRecorder()
        let snapshot = makeBoundRealSnapshot()
        let service = QuotaRefreshService(
            realProvider: StubRealQuotaProvider(snapshot: snapshot),
            resetCreditsDetailProvider: RecordingResetCreditsProvider(recorder: recorder),
            mockProvider: MockQuotaProvider(),
            currentAccountBoundary: { .testDefault }
        )

        let refreshed = try await service.refresh(basedOn: .notConnected)

        let boundaries = await recorder.detailAccountBoundaries
        XCTAssertEqual(boundaries, [.testDefault])
        XCTAssertEqual(refreshed.resetCreditDetailsState, .detailed)
        XCTAssertEqual(refreshed.accountBoundary, .testDefault)
    }

    func testRefreshCancelledBeforeRealProviderDoesNotStartProviders() async {
        let recorder = RefreshCallRecorder()
        let startGate = RefreshCancellationGate()
        let snapshot = makeBoundRealSnapshot()
        let service = QuotaRefreshService(
            realProvider: RecordingRealQuotaProvider(snapshot: snapshot, recorder: recorder),
            resetCreditsDetailProvider: RecordingResetCreditsProvider(recorder: recorder),
            mockProvider: MockQuotaProvider(),
            currentAccountBoundary: { .testDefault }
        )

        let task = Task {
            await startGate.waitForRelease()
            return try await service.refresh(basedOn: .notConnected)
        }
        task.cancel()
        await startGate.release()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let realCallCount = await recorder.realCallCount
        let detailCallCount = await recorder.detailCallCount
        XCTAssertEqual(realCallCount, 0)
        XCTAssertEqual(detailCallCount, 0)
    }

    func testRefreshCancelledAfterRealProviderThrowsCancellationWithoutPublishingSnapshot() async {
        let recorder = RefreshCallRecorder()
        let realProviderGate = RefreshCancellationGate()
        let snapshot = makeBoundRealSnapshot()
        let service = QuotaRefreshService(
            realProvider: BlockingRealQuotaProvider(
                snapshot: snapshot,
                recorder: recorder,
                gate: realProviderGate
            ),
            resetCreditsDetailProvider: RecordingResetCreditsProvider(recorder: recorder),
            mockProvider: MockQuotaProvider(),
            currentAccountBoundary: { .testDefault }
        )

        let task = Task { try await service.refresh(basedOn: .notConnected) }
        let realLegStarted = await waitForStart(of: realProviderGate)
        XCTAssertTrue(realLegStarted, "The refresh must have entered the RPC leg before it was cancelled")
        task.cancel()
        await realProviderGate.release()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation instead of a published snapshot")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let realCallCount = await recorder.realCallCount
        let detailCallCount = await recorder.detailCallCount
        XCTAssertEqual(realCallCount, 1)
        // The detail leg now starts before the RPC leg is awaited, so its
        // request has already been made by the time the RPC leg completes.
        // The cancelled refresh must still publish nothing.
        XCTAssertEqual(detailCallCount, 1)
    }

    func testRefreshCancelledWhileResetCreditDetailsAreBlockedRethrowsCancellation() async {
        // The detail leg now runs concurrently with the RPC leg; a refresh
        // cancelled while that leg is still blocked must still throw
        // `CancellationError` and publish nothing.
        let detailProviderGate = RefreshCancellationGate()
        let snapshot = makeBoundRealSnapshot()
        let service = QuotaRefreshService(
            realProvider: StubRealQuotaProvider(snapshot: snapshot),
            resetCreditsDetailProvider: BlockingResetCreditsProvider(gate: detailProviderGate),
            mockProvider: MockQuotaProvider(),
            currentAccountBoundary: { .testDefault }
        )

        let task = Task { try await service.refresh(basedOn: .notConnected) }
        let detailLegStarted = await waitForStart(of: detailProviderGate)
        XCTAssertTrue(detailLegStarted, "The refresh must have entered the detail leg before it was cancelled")
        task.cancel()
        await detailProviderGate.release()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation instead of a degraded snapshot")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testResetCreditDetailLegRunsWhileRealProviderLegIsStillInFlight() async throws {
        let recorder = RefreshCallRecorder()
        let realGate = RefreshCancellationGate()
        let detailGate = RefreshCancellationGate()
        let service = QuotaRefreshService(
            realProvider: BlockingRealQuotaProvider(
                snapshot: makeBoundRealSnapshot(),
                recorder: recorder,
                gate: realGate
            ),
            resetCreditsDetailProvider: BlockingRecordingResetCreditsProvider(
                recorder: recorder,
                gate: detailGate
            ),
            mockProvider: MockQuotaProvider(),
            currentAccountBoundary: { .testDefault }
        )

        let task = Task { try await service.refresh(basedOn: .notConnected) }
        // The RPC leg is blocked on its gate here, so a detail call observed
        // before that gate is released can only have started concurrently.
        let realLegStarted = await waitForStart(of: realGate)
        let detailLegStarted = await waitForStart(of: detailGate)
        let realCallCount = await recorder.realCallCount
        let detailCallCount = await recorder.detailCallCount
        await realGate.release()
        await detailGate.release()
        let refreshed = try await task.value

        XCTAssertTrue(realLegStarted, "The RPC leg must have started")
        XCTAssertTrue(detailLegStarted, "The detail leg must start while the RPC leg is still in flight")
        XCTAssertEqual(realCallCount, 1)
        XCTAssertEqual(detailCallCount, 1)
        XCTAssertEqual(refreshed.resetCreditDetailsState, .detailed)
    }

    func testRefreshDiscardsPrefetchedDetailsFetchedUnderADifferentAccountBoundary() async throws {
        // `auth.json` held a different login session than the one the RPC leg
        // proved, so the prefetched payload must not be published under the
        // refreshed snapshot.
        let recorder = RefreshCallRecorder()
        let payload = ResetCreditsDetailPayload(
            availableCount: 2,
            availableCredits: [
                ResetCreditDetailSnapshot(
                    ordinal: 1,
                    status: "available",
                    grantedAt: makeDate("2026-06-19T10:00:00Z"),
                    expiresAt: makeDate("2026-06-19T18:00:00Z")
                )
            ],
            statusSummary: [ResetCreditStatusSummary(status: "available", count: 1)]
        )
        let service = QuotaRefreshService(
            realProvider: StubRealQuotaProvider(snapshot: makeBoundRealSnapshot()),
            resetCreditsDetailProvider: RecordingDetailedResetCreditsProvider(
                recorder: recorder,
                payload: payload
            ),
            mockProvider: MockQuotaProvider(),
            currentAccountBoundary: { .testRelogin }
        )

        let refreshed = try await service.refresh(basedOn: .notConnected)

        let boundaries = await recorder.detailAccountBoundaries
        XCTAssertEqual(boundaries, [.testRelogin])
        XCTAssertEqual(refreshed.resetCreditDetailsState, .unavailable)
        XCTAssertEqual(
            refreshed.resetCreditDiagnostic?.summary,
            ResetCreditsDetailError.accountBoundaryMismatch.localizedDescription
        )
        XCTAssertEqual(refreshed.resetAvailableCount, 1)
        XCTAssertTrue(refreshed.resetCreditDetails.isEmpty)
        XCTAssertTrue(refreshed.resetCreditStatusSummary.isEmpty)
        XCTAssertEqual(refreshed.accountBoundary, .testDefault)
    }

    func testRefreshGatesPrefetchedNonPayloadOutcomesUnderADifferentAccountBoundary() async throws {
        // Every prefetched outcome carries the identity its request was bound
        // to, not only a payload. An outcome produced under identity A must not
        // be published under the identity B snapshot the RPC leg proved: for
        // `noAvailableCredits` that would downgrade the identity-mismatch
        // contract to the neutral app-server count, and for a fetch failure it
        // would persist a diagnostic produced under A.
        let previousUnderRequestedIdentity = QuotaSnapshot(
            weeklyQuotaPercent: 70,
            fiveHourQuotaPercent: 64,
            resetAvailableCount: 1,
            resetCreditDetailsState: .detailed,
            resetCreditDetails: [
                ResetCreditDetailSnapshot(
                    ordinal: 1,
                    status: "available",
                    grantedAt: makeDate("2026-06-19T10:00:00Z"),
                    expiresAt: makeDate("2026-06-19T18:00:00Z")
                )
            ],
            resetCreditStatusSummary: [ResetCreditStatusSummary(status: "available", count: 1)],
            refreshedAt: makeDate("2026-06-19T12:40:00Z"),
            dataSource: .real,
            accountBoundary: .testRelogin
        )
        let providers: [(name: String, provider: any ResetCreditsDetailRefreshing)] = [
            ("noAvailableCredits", NoAvailableCreditsProvider()),
            ("fetchFailure", FailingResetCreditsProvider())
        ]

        for (name, detailProvider) in providers {
            let service = QuotaRefreshService(
                realProvider: StubRealQuotaProvider(snapshot: makeBoundRealSnapshot()),
                resetCreditsDetailProvider: detailProvider,
                mockProvider: MockQuotaProvider(),
                currentAccountBoundary: { .testRelogin }
            )

            let refreshed = try await service.refresh(
                basedOn: previousUnderRequestedIdentity
            )

            XCTAssertEqual(refreshed.resetCreditDetailsState, .unavailable, name)
            XCTAssertNotEqual(refreshed.resetCreditDetailsState, .appServerCountOnly, name)
            XCTAssertEqual(
                refreshed.resetCreditDiagnostic?.summary,
                ResetCreditsDetailError.accountBoundaryMismatch.localizedDescription,
                name
            )
            // Identity A's cached details must not leak into identity B's
            // snapshot ...
            XCTAssertTrue(refreshed.resetCreditDetails.isEmpty, name)
            XCTAssertTrue(refreshed.resetCreditStatusSummary.isEmpty, name)
            // ... and the count still comes from the RPC snapshot.
            XCTAssertEqual(refreshed.resetAvailableCount, 1, name)
            XCTAssertEqual(refreshed.accountBoundary, .testDefault, name)
        }
    }

    func testRefreshUsesSerialDetailLegWhenNoRequestIdentityIsAvailable() async throws {
        // No usable identity when the refresh started means no request could be
        // bound upfront, so the detail leg runs after the RPC leg under the
        // boundary the refreshed snapshot proves, exactly as it did before the
        // legs overlapped.
        let recorder = RefreshCallRecorder()
        let payload = ResetCreditsDetailPayload(
            availableCount: 2,
            availableCredits: [
                ResetCreditDetailSnapshot(
                    ordinal: 1,
                    status: "available",
                    grantedAt: makeDate("2026-06-19T10:00:00Z"),
                    expiresAt: makeDate("2026-06-19T18:00:00Z")
                )
            ],
            statusSummary: [ResetCreditStatusSummary(status: "available", count: 1)]
        )
        let service = QuotaRefreshService(
            realProvider: StubRealQuotaProvider(snapshot: makeBoundRealSnapshot()),
            resetCreditsDetailProvider: RecordingDetailedResetCreditsProvider(
                recorder: recorder,
                payload: payload
            ),
            mockProvider: MockQuotaProvider(),
            currentAccountBoundary: { nil }
        )

        let refreshed = try await service.refresh(basedOn: .notConnected)

        XCTAssertEqual(refreshed.resetCreditDetailsState, .detailed)
        XCTAssertEqual(refreshed.resetAvailableCount, 2)
        XCTAssertEqual(refreshed.resetCreditDetails, payload.availableCredits)
        XCTAssertEqual(refreshed.resetCreditStatusSummary, payload.statusSummary)
        XCTAssertNil(refreshed.resetCreditDiagnostic)
        let boundaries = await recorder.detailAccountBoundaries
        XCTAssertEqual(boundaries, [.testDefault])
    }

    func testPrefetchedAndSerialDetailOutcomesPublishIdenticalSnapshots() async throws {
        // The concurrency change must not change what is published: for every
        // detail outcome the prefetched path produces a snapshot that is
        // field-for-field identical to the serial path's snapshot.
        let payload = ResetCreditsDetailPayload(
            availableCount: 2,
            availableCredits: [
                ResetCreditDetailSnapshot(
                    ordinal: 1,
                    status: "available",
                    grantedAt: makeDate("2026-06-19T10:00:00Z"),
                    expiresAt: makeDate("2026-06-19T18:00:00Z")
                )
            ],
            statusSummary: [ResetCreditStatusSummary(status: "available", count: 1)]
        )
        let previous = QuotaSnapshot(
            weeklyQuotaPercent: 70,
            fiveHourQuotaPercent: 64,
            resetAvailableCount: 1,
            resetCreditDetailsState: .detailed,
            resetCreditDetails: [
                ResetCreditDetailSnapshot(
                    ordinal: 1,
                    status: "available",
                    grantedAt: makeDate("2026-06-19T10:00:00Z"),
                    expiresAt: makeDate("2026-06-19T18:00:00Z")
                )
            ],
            resetCreditStatusSummary: [ResetCreditStatusSummary(status: "available", count: 1)],
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

        func refreshed(
            basedOn currentSnapshot: QuotaSnapshot,
            detailProvider: any ResetCreditsDetailRefreshing,
            requestBoundary: QuotaAccountBoundary?
        ) async throws -> QuotaSnapshot {
            try await QuotaRefreshService(
                realProvider: StubRealQuotaProvider(snapshot: appServerSnapshot),
                resetCreditsDetailProvider: detailProvider,
                mockProvider: MockQuotaProvider(),
                currentAccountBoundary: { requestBoundary }
            ).refresh(basedOn: currentSnapshot)
        }

        let providers: [any ResetCreditsDetailRefreshing] = [
            SucceedingResetCreditsProvider(payload: payload),
            NoAvailableCreditsProvider(),
            FailingResetCreditsProvider()
        ]
        let expectedStates: [ResetCreditDetailsState] = [.detailed, .appServerCountOnly, .unavailable]

        for (detailProvider, expectedState) in zip(providers, expectedStates) {
            let serial = try await refreshed(
                basedOn: .notConnected,
                detailProvider: detailProvider,
                requestBoundary: nil
            )
            let prefetched = try await refreshed(
                basedOn: .notConnected,
                detailProvider: detailProvider,
                requestBoundary: .testDefault
            )
            XCTAssertEqual(serial.resetCreditDetailsState, expectedState)
            XCTAssertEqual(serial, prefetched)

            // The reusable-details fallback must be identical on both paths
            // too.
            let serialWithPrevious = try await refreshed(
                basedOn: previous,
                detailProvider: detailProvider,
                requestBoundary: nil
            )
            let prefetchedWithPrevious = try await refreshed(
                basedOn: previous,
                detailProvider: detailProvider,
                requestBoundary: .testDefault
            )
            XCTAssertEqual(serialWithPrevious, prefetchedWithPrevious)
        }
    }

    func testFailedRealProviderDoesNotWaitForThePrefetchedDetailLeg() async throws {
        let recorder = RefreshCallRecorder()
        let realGate = RefreshCancellationGate()
        let detailGate = RefreshCancellationGate()
        let service = QuotaRefreshService(
            realProvider: FailingRealQuotaProvider(
                error: .rpcRejected(code: 7),
                recorder: recorder,
                gate: realGate
            ),
            resetCreditsDetailProvider: CancellationUnblockedResetCreditsProvider(
                recorder: recorder,
                gate: detailGate
            ),
            mockProvider: MockQuotaProvider(),
            currentAccountBoundary: { .testDefault }
        )

        let returned = FirstSignal<RefreshOutcome>()
        let refreshTask = Task { () -> RefreshOutcome in
            let outcome: RefreshOutcome
            do {
                _ = try await service.refresh(basedOn: .notConnected)
                outcome = .snapshotReturned
            } catch let error as RealQuotaError {
                outcome = .rpcError(error)
            } catch {
                outcome = .unexpectedError
            }
            await returned.signal(outcome)
            return outcome
        }
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await returned.signal(.timedOut)
        }

        // The RPC leg is held until the detail leg has provably started and
        // entered its own wait, so a regression cannot pass by failing the RPC
        // leg before the detail leg ever ran.
        let detailLegStarted = await waitForStart(of: detailGate)
        let realLegStarted = await waitForStart(of: realGate)
        await realGate.release()
        let outcome = await returned.wait()
        // Failure cleanup: unblock a refresh that wrongly waited for the gate.
        await detailGate.release()
        _ = await refreshTask.value

        XCTAssertTrue(detailLegStarted, "The failed refresh must have started the detail leg")
        XCTAssertTrue(realLegStarted, "The RPC leg must have started before it failed")
        XCTAssertEqual(
            outcome,
            .rpcError(.rpcRejected(code: 7)),
            "A failed RPC leg must cancel the detail leg instead of waiting for it"
        )
        let detailCallCount = await recorder.detailCallCount
        let detailCancellationCount = await recorder.detailCancellationCount
        XCTAssertEqual(detailCallCount, 1)
        XCTAssertEqual(detailCancellationCount, 1)
    }

    /// Bounded wait for a gate to reach its "started" state. Used where the
    /// assertion is "this leg started while the other was still in flight", so
    /// a regression fails the assertion instead of hanging the suite.
    private func waitForStart(
        of gate: RefreshCancellationGate,
        timeout: TimeInterval = 2
    ) async -> Bool {
        let first = FirstSignal<Bool>()
        Task {
            await gate.waitForStart()
            await first.signal(true)
        }
        Task {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            await first.signal(false)
        }
        return await first.wait()
    }

    private func makeBoundRealSnapshot() -> QuotaSnapshot {
        QuotaSnapshot(
            weeklyQuotaPercent: 70,
            fiveHourQuotaPercent: 64,
            resetAvailableCount: 1,
            resetCreditDetailsState: .appServerCountOnly,
            refreshedAt: makeDate("2026-06-19T12:40:00Z"),
            dataSource: .real,
            accountBoundary: .testDefault
        )
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
    func fetchDetails(
        for _: QuotaAccountBoundary
    ) async throws -> ResetCreditsDetailPayload {
        throw ResetCreditsDetailError.unexpectedStatusCode(503)
    }
}

private struct NoAvailableCreditsProvider: ResetCreditsDetailRefreshing, Sendable {
    func fetchDetails(
        for _: QuotaAccountBoundary
    ) async throws -> ResetCreditsDetailPayload {
        throw ResetCreditsDetailError.noAvailableCredits
    }
}

private struct SucceedingResetCreditsProvider: ResetCreditsDetailRefreshing, Sendable {
    let payload: ResetCreditsDetailPayload

    func fetchDetails(
        for _: QuotaAccountBoundary
    ) async throws -> ResetCreditsDetailPayload {
        payload
    }
}

private struct RecordingDetailedResetCreditsProvider: ResetCreditsDetailRefreshing, Sendable {
    let recorder: RefreshCallRecorder
    let payload: ResetCreditsDetailPayload

    func fetchDetails(
        for accountBoundary: QuotaAccountBoundary
    ) async throws -> ResetCreditsDetailPayload {
        await recorder.recordDetailCall(accountBoundary: accountBoundary)
        return payload
    }
}

private struct RecordingRealQuotaProvider: RealQuotaRefreshing, Sendable {
    let snapshot: QuotaSnapshot
    let recorder: RefreshCallRecorder

    func fetchQuota() async throws -> QuotaSnapshot {
        await recorder.recordRealCall()
        return snapshot
    }
}

private struct FailingRealQuotaProvider: RealQuotaRefreshing, Sendable {
    let error: RealQuotaError
    let recorder: RefreshCallRecorder
    var gate: RefreshCancellationGate? = nil

    func fetchQuota() async throws -> QuotaSnapshot {
        await recorder.recordRealCall()
        if let gate {
            await gate.markStarted()
            await gate.waitForRelease()
        }
        throw error
    }
}

private struct BlockingRealQuotaProvider: RealQuotaRefreshing, Sendable {
    let snapshot: QuotaSnapshot
    let recorder: RefreshCallRecorder
    let gate: RefreshCancellationGate

    func fetchQuota() async throws -> QuotaSnapshot {
        await recorder.recordRealCall()
        await gate.markStarted()
        await gate.waitForRelease()
        return snapshot
    }
}

private struct RecordingResetCreditsProvider: ResetCreditsDetailRefreshing, Sendable {
    let recorder: RefreshCallRecorder

    func fetchDetails(
        for accountBoundary: QuotaAccountBoundary
    ) async throws -> ResetCreditsDetailPayload {
        await recorder.recordDetailCall(accountBoundary: accountBoundary)
        return ResetCreditsDetailPayload(
            availableCount: 1,
            availableCredits: [],
            statusSummary: []
        )
    }
}

private struct BlockingResetCreditsProvider: ResetCreditsDetailRefreshing, Sendable {
    let gate: RefreshCancellationGate

    func fetchDetails(
        for _: QuotaAccountBoundary
    ) async throws -> ResetCreditsDetailPayload {
        await gate.markStarted()
        await gate.waitForRelease()
        try Task.checkCancellation()
        return ResetCreditsDetailPayload(
            availableCount: 1,
            availableCredits: [],
            statusSummary: []
        )
    }
}

private struct BlockingRecordingResetCreditsProvider: ResetCreditsDetailRefreshing, Sendable {
    let recorder: RefreshCallRecorder
    let gate: RefreshCancellationGate

    func fetchDetails(
        for accountBoundary: QuotaAccountBoundary
    ) async throws -> ResetCreditsDetailPayload {
        await recorder.recordDetailCall(accountBoundary: accountBoundary)
        await gate.markStarted()
        await gate.waitForRelease()
        return ResetCreditsDetailPayload(
            availableCount: 1,
            availableCredits: [],
            statusSummary: []
        )
    }
}

/// Blocks until the refresh is cancelled, mirroring a request that only
/// completes when `URLSession` observes cancellation. The cancellation handler
/// releases the gate so the refresh can drain the leg.
private struct CancellationUnblockedResetCreditsProvider: ResetCreditsDetailRefreshing, Sendable {
    let recorder: RefreshCallRecorder
    let gate: RefreshCancellationGate

    func fetchDetails(
        for accountBoundary: QuotaAccountBoundary
    ) async throws -> ResetCreditsDetailPayload {
        await recorder.recordDetailCall(accountBoundary: accountBoundary)
        await gate.markStarted()
        await withTaskCancellationHandler {
            await gate.waitForRelease()
        } onCancel: {
            Task {
                await recorder.recordDetailCancellation()
                await gate.release()
            }
        }
        try Task.checkCancellation()
        return ResetCreditsDetailPayload(
            availableCount: 1,
            availableCredits: [],
            statusSummary: []
        )
    }
}

private actor RefreshCallRecorder {
    private(set) var realCallCount = 0
    private(set) var detailCallCount = 0
    private(set) var detailCancellationCount = 0
    private(set) var detailAccountBoundaries: [QuotaAccountBoundary] = []

    func recordRealCall() {
        realCallCount += 1
    }

    func recordDetailCall(accountBoundary: QuotaAccountBoundary) {
        detailCallCount += 1
        detailAccountBoundaries.append(accountBoundary)
    }

    func recordDetailCancellation() {
        detailCancellationCount += 1
    }
}

/// Result of a refresh call, raced against a bound so a regression fails an
/// assertion instead of hanging the suite.
private enum RefreshOutcome: Equatable, Sendable {
    case snapshotReturned
    case rpcError(RealQuotaError)
    case unexpectedError
    /// No outcome arrived before the test's bound elapsed.
    case timedOut
}

/// Returns the first value it is signalled with, from whichever signal arrives
/// first. The losing unstructured task is left unawaited on purpose, so a wait
/// can be bounded without blocking the suite.
private actor FirstSignal<Value: Sendable> {
    private var value: Value?
    private var waiters: [CheckedContinuation<Value, Never>] = []

    func signal(_ value: Value) {
        guard self.value == nil else { return }
        self.value = value
        let waiters = self.waiters
        self.waiters.removeAll()
        waiters.forEach { $0.resume(returning: value) }
    }

    func wait() async -> Value {
        if let value {
            return value
        }
        return await withCheckedContinuation { waiters.append($0) }
    }
}

private actor RefreshCancellationGate {
    private var hasStarted = false
    private var isReleased = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func markStarted() {
        hasStarted = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func waitForStart() async {
        guard !hasStarted else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func waitForRelease() async {
        guard !isReleased else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func release() {
        isReleased = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}
