import XCTest
@testable import CodexMonitorNative

final class UsageTrendTests: XCTestCase {
    func testAnalysisRequiresThreeSamplesAcrossTenMinutes() {
        let base = Date(timeIntervalSince1970: 10_000)
        var history = UsageTrendHistory(accountBoundary: .testDefault)
        history.append(sample(at: base, remaining: 80))
        history.append(sample(at: base.addingTimeInterval(9 * 60), remaining: 79))

        var analysis = UsageTrendAnalyzer.analyze(history: history, currentResetAt: nil)
        XCTAssertEqual(analysis.state, .insufficientData)
        XCTAssertNil(analysis.ratePercentPerHour)
        XCTAssertNil(analysis.exhaustionAt)

        history.append(sample(at: base.addingTimeInterval(10 * 60), remaining: 78))
        analysis = UsageTrendAnalyzer.analyze(history: history, currentResetAt: nil)
        XCTAssertEqual(analysis.state, .consuming)
        XCTAssertEqual(analysis.ratePercentPerHour ?? 0, 12, accuracy: 0.001)
    }

    func testAnalysisComputesRateAndExhaustionFromContinuousSamples() {
        let base = Date(timeIntervalSince1970: 20_000)
        let resetAt = base.addingTimeInterval(24 * 60 * 60)
        var history = UsageTrendHistory(accountBoundary: .testDefault)
        history.append(sample(at: base, remaining: 90, resetAt: resetAt))
        history.append(sample(at: base.addingTimeInterval(30 * 60), remaining: 85, resetAt: resetAt))
        history.append(sample(at: base.addingTimeInterval(60 * 60), remaining: 80, resetAt: resetAt))

        let analysis = UsageTrendAnalyzer.analyze(history: history, currentResetAt: resetAt)

        XCTAssertEqual(analysis.state, .consuming)
        XCTAssertEqual(analysis.ratePercentPerHour ?? 0, 10, accuracy: 0.001)
        XCTAssertEqual(analysis.exhaustionAt, base.addingTimeInterval(9 * 60 * 60))
        XCTAssertEqual(analysis.willExhaustBeforeReset, true)
    }

    func testStableSamplesDoNotInventExhaustionPrediction() {
        let base = Date(timeIntervalSince1970: 30_000)
        var history = UsageTrendHistory(accountBoundary: .testDefault)
        history.append(sample(at: base, remaining: 70))
        history.append(sample(at: base.addingTimeInterval(10 * 60), remaining: 70))
        history.append(sample(at: base.addingTimeInterval(20 * 60), remaining: 70))

        let analysis = UsageTrendAnalyzer.analyze(history: history, currentResetAt: nil)

        XCTAssertEqual(analysis.state, .stable)
        XCTAssertEqual(analysis.ratePercentPerHour, 0)
        XCTAssertNil(analysis.exhaustionAt)
    }

    func testResetStartsNewSeriesAndReportsInsufficientData() {
        let base = Date(timeIntervalSince1970: 40_000)
        let firstReset = base.addingTimeInterval(60 * 60)
        let nextReset = firstReset.addingTimeInterval(7 * 24 * 60 * 60)
        var history = UsageTrendHistory(accountBoundary: .testDefault)
        history.append(sample(at: base, remaining: 20, resetAt: firstReset))
        history.append(sample(at: base.addingTimeInterval(10 * 60), remaining: 18, resetAt: firstReset))
        history.append(sample(at: base.addingTimeInterval(20 * 60), remaining: 95, resetAt: nextReset))

        let analysis = UsageTrendAnalyzer.analyze(history: history, currentResetAt: nextReset)

        XCTAssertEqual(history.samples.map(\.remainingPercent), [95])
        XCTAssertEqual(analysis.state, .insufficientData)
        XCTAssertEqual(analysis.latestNotice, .quotaReset)
        XCTAssertNil(analysis.ratePercentPerHour)
    }

    func testAnomalousRapidDropStartsFreshBaselineInsteadOfInflatingRate() {
        let base = Date(timeIntervalSince1970: 50_000)
        var history = UsageTrendHistory(accountBoundary: .testDefault)
        history.append(sample(at: base, remaining: 80))
        history.append(sample(at: base.addingTimeInterval(10 * 60), remaining: 79))
        history.append(sample(at: base.addingTimeInterval(15 * 60), remaining: 40))

        let analysis = UsageTrendAnalyzer.analyze(history: history, currentResetAt: nil)

        XCTAssertEqual(history.samples.map(\.remainingPercent), [40])
        XCTAssertEqual(analysis.state, .insufficientData)
        XCTAssertEqual(analysis.latestNotice, .anomalousJump)
        XCTAssertNil(analysis.ratePercentPerHour)
    }

    func testOutOfOrderSampleIsIgnored() {
        let base = Date(timeIntervalSince1970: 60_000)
        var history = UsageTrendHistory(accountBoundary: .testDefault)
        history.append(sample(at: base, remaining: 80))
        history.append(sample(at: base.addingTimeInterval(-1), remaining: 10))

        XCTAssertEqual(history.samples, [sample(at: base, remaining: 80)])
    }

    func testStoreLoadsOnlyMatchingAccountSessionBoundary() {
        let suiteName = "CodexMonitorNativeTests.usageTrendStore.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UsageTrendStore(defaults: defaults, key: "trend")
        let history = UsageTrendHistory(
            accountBoundary: .testDefault,
            samples: [sample(at: Date(timeIntervalSince1970: 70_000), remaining: 75)]
        )

        XCTAssertTrue(store.save(history))
        XCTAssertEqual(store.load(matching: .testDefault), history)
        XCTAssertNil(store.load(matching: .testOtherAccount))
        XCTAssertNil(store.load(matching: nil))
    }

    func testMetricPrefersCanonicalLiveWeeklyWindowAndCarriesReset() {
        let date = Date(timeIntervalSince1970: 80_000)
        let resetAt = date.addingTimeInterval(3600)
        let snapshot = QuotaSnapshot(
            weeklyQuotaPercent: 99,
            fiveHourQuotaPercent: 80,
            refreshedAt: date,
            dataSource: .real,
            quotaWindows: [
                QuotaWindow(
                    limitId: "fallback",
                    windowId: "weekly",
                    kind: .weekly,
                    remainingPercent: 40,
                    resetAt: nil
                ),
                QuotaWindow(
                    limitId: "codex",
                    windowId: "secondary",
                    kind: .weekly,
                    remainingPercent: 61,
                    resetAt: resetAt
                )
            ],
            accountBoundary: .testDefault
        )

        XCTAssertEqual(
            UsageTrendMetric.weeklySample(from: snapshot),
            sample(at: date, remaining: 61, resetAt: resetAt)
        )
    }

    func testFormattingDistinguishesInsufficientStableAndPostResetPrediction() {
        let base = Date(timeIntervalSince1970: 90_000)
        let insufficient = UsageTrendAnalysis(
            state: .insufficientData,
            samples: [sample(at: base, remaining: 90)],
            ratePercentPerHour: nil,
            exhaustionAt: nil,
            resetAt: base.addingTimeInterval(3600),
            latestNotice: .quotaReset
        )
        XCTAssertEqual(
            UsageTrendFormatting.display(for: insufficient, now: base).detailText,
            "检测到额度重置，正在重新收集"
        )

        let stable = UsageTrendAnalysis(
            state: .stable,
            samples: [],
            ratePercentPerHour: 0,
            exhaustionAt: nil,
            resetAt: nil,
            latestNotice: nil
        )
        XCTAssertEqual(
            UsageTrendFormatting.display(for: stable, now: base).exhaustionText,
            "当前速度下不会耗尽"
        )

        let afterReset = UsageTrendAnalysis(
            state: .consuming,
            samples: [],
            ratePercentPerHour: 1.25,
            exhaustionAt: base.addingTimeInterval(3 * 3600),
            resetAt: base.addingTimeInterval(2 * 3600),
            latestNotice: nil
        )
        let display = UsageTrendFormatting.display(for: afterReset, now: base)
        XCTAssertEqual(display.speedText, "1.2%/小时")
        XCTAssertEqual(display.exhaustionText, "预计重置前不会耗尽")
        XCTAssertEqual(display.resetRemainingText, "2小时")
    }

    private func sample(
        at date: Date,
        remaining: Int,
        resetAt: Date? = nil
    ) -> UsageTrendSample {
        UsageTrendSample(recordedAt: date, remainingPercent: remaining, resetAt: resetAt)
    }
}

@MainActor
final class UsageTrendAppStateTests: XCTestCase {
    func testSuccessfulRefreshesBuildTrendAndAccountChangeFailsClosed() async {
        let suiteName = "CodexMonitorNativeTests.usageTrendAppState.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let base = Date(timeIntervalSince1970: 100_000)
        let resetAt = base.addingTimeInterval(24 * 3600)
        let snapshots = [
            makeSnapshot(at: base, remaining: 80, resetAt: resetAt),
            makeSnapshot(at: base.addingTimeInterval(10 * 60), remaining: 79, resetAt: resetAt),
            makeSnapshot(at: base.addingTimeInterval(20 * 60), remaining: 78, resetAt: resetAt)
        ]
        let service = UsageTrendSequenceRefreshService(snapshots: snapshots)
        let trendStore = UsageTrendStore(defaults: defaults, key: "trend")
        var boundary = QuotaAccountBoundary.testDefault
        let appState = AppState(
            snapshotStore: SnapshotStore(defaults: defaults, key: "snapshot"),
            refreshService: service,
            now: { base.addingTimeInterval(20 * 60) },
            accountBoundaryProvider: { boundary },
            usageTrendStore: trendStore
        )
        defer { appState.shutdown() }

        await appState.refreshNow(trigger: .manual)
        await appState.refreshNow(trigger: .manual)
        await appState.refreshNow(trigger: .manual)

        XCTAssertEqual(appState.usageTrendAnalysis.state, .consuming)
        XCTAssertEqual(appState.usageTrendAnalysis.ratePercentPerHour ?? 0, 6, accuracy: 0.001)
        XCTAssertEqual(trendStore.load(matching: .testDefault)?.samples.count, 3)

        let analysisBeforeFailure = appState.usageTrendAnalysis
        await appState.refreshNow(trigger: .manual)
        XCTAssertEqual(appState.status, .networkFailed)
        XCTAssertEqual(appState.usageTrendAnalysis, analysisBeforeFailure)
        XCTAssertEqual(trendStore.load(matching: .testDefault)?.samples.count, 3)

        boundary = .testOtherAccount
        appState.accountBoundaryDidChange()

        XCTAssertEqual(appState.usageTrendAnalysis, .unavailable)
        XCTAssertNil(trendStore.load(matching: .testOtherAccount))
    }

    private func makeSnapshot(
        at date: Date,
        remaining: Int,
        resetAt: Date
    ) -> QuotaSnapshot {
        QuotaSnapshot(
            weeklyQuotaPercent: remaining,
            fiveHourQuotaPercent: 80,
            refreshedAt: date,
            dataSource: .real,
            quotaWindows: [
                QuotaWindow(
                    limitId: "codex",
                    windowId: "secondary",
                    kind: .weekly,
                    durationMinutes: 10_080,
                    remainingPercent: remaining,
                    resetAt: resetAt
                )
            ],
            accountBoundary: .testDefault
        )
    }
}

private actor UsageTrendSequenceRefreshService: QuotaRefreshing {
    private var snapshots: [QuotaSnapshot]

    init(snapshots: [QuotaSnapshot]) {
        self.snapshots = snapshots
    }

    func refresh(basedOn current: QuotaSnapshot) async throws -> QuotaSnapshot {
        guard !snapshots.isEmpty else { throw MockRefreshError.simulatedFailure }
        return snapshots.removeFirst()
    }
}
