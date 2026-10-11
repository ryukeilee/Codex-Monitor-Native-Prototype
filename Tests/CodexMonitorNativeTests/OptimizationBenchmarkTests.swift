import XCTest
@testable import CodexMonitorNative

// Opt-in: CODEX_MONITOR_BENCHMARK=1 swift test --filter OptimizationBenchmarkTests
final class OptimizationBenchmarkTests: XCTestCase {
    func testDateFormatterCacheBaseline() throws {
        guard ProcessInfo.processInfo.environment["CODEX_MONITOR_BENCHMARK"] == "1" else {
            throw XCTSkip("Opt-in performance comparison")
        }
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let locale = Locale(identifier: "zh_CN")
        let zone = TimeZone(secondsFromGMT: 8 * 3600)!
        let format = "M/d HH:mm"
        let expected = StatusPopoverFormatting.dateString(from: date, format: format, locale: locale, timeZone: zone)
        for round in 0..<5 {
            var start = Date()
            for _ in 0..<1_000 {
                let formatter = DateFormatter()
                formatter.locale = locale
                formatter.timeZone = zone
                formatter.dateFormat = format
                XCTAssertEqual(formatter.string(from: date), expected)
            }
            let fresh = Date().timeIntervalSince(start)
            start = Date()
            for _ in 0..<1_000 {
                XCTAssertEqual(StatusPopoverFormatting.dateString(from: date, format: format, locale: locale, timeZone: zone), expected)
            }
            print("BENCH formatter round=\(round) fresh=\(fresh) cached=\(Date().timeIntervalSince(start))")
        }
    }

    func testVersionDirectorySortBaseline() throws {
        guard ProcessInfo.processInfo.environment["CODEX_MONITOR_BENCHMARK"] == "1" else {
            throw XCTSkip("Opt-in performance comparison")
        }
        // Version-manager listings are small in practice; scale the entry count to make the
        // per-comparison parse cost measurable rather than to model a real refresh.
        let paths = (0..<256).map { "/root/node-versions/v\(20 + $0 % 6).\($0 % 60).\($0 % 10)" }

        func reparsePerComparisonSort(_ paths: [String]) -> [String] {
            paths.sorted { lhs, rhs in
                let lhsComponents = CodexExecutableResolver.versionComponents(of: lhs)
                let rhsComponents = CodexExecutableResolver.versionComponents(of: rhs)
                for (left, right) in zip(lhsComponents, rhsComponents) where left != right {
                    return left > right
                }
                if lhsComponents.count != rhsComponents.count {
                    return lhsComponents.count > rhsComponents.count
                }
                return lhs > rhs
            }
        }

        let reference = reparsePerComparisonSort(paths)
        XCTAssertEqual(reference.count, paths.count)

        for round in 0..<5 {
            var start = Date()
            for _ in 0..<200 {
                XCTAssertEqual(reparsePerComparisonSort(paths), reference)
            }
            let baseline = Date().timeIntervalSince(start)
            start = Date()
            for _ in 0..<200 {
                XCTAssertEqual(
                    CodexExecutableResolver.sortedNewestVersionFirst(
                        paths,
                        versionComponents: CodexExecutableResolver.versionComponents(of:)
                    ),
                    reference
                )
            }
            print("BENCH version-sort×200 round=\(round) baseline=\(baseline) optimized=\(Date().timeIntervalSince(start))")
        }
    }

    func testQuotaWindowCacheMergeBaseline() throws {
        guard ProcessInfo.processInfo.environment["CODEX_MONITOR_BENCHMARK"] == "1" else {
            throw XCTSkip("Opt-in performance comparison")
        }
        // Real snapshots expose only a handful of windows; scale the counts so the
        // per-window cache scan cost is measurable rather than to model a refresh.
        let windowCount = 512
        let cachedWindows = (0..<windowCount).map { index in
            QuotaWindow(
                limitId: "codex",
                windowId: "w\(index)",
                kind: .unknown,
                remainingPercent: 100 - index % 100,
                state: .live
            )
        }
        let currentWindows = (0..<windowCount).map { index in
            QuotaWindow(
                limitId: "codex",
                windowId: "w\(index)",
                kind: .unknown,
                remainingPercent: 0,
                state: .unavailable
            )
        }

        func linearScanMerge(current: [QuotaWindow], cached: [QuotaWindow]) -> [QuotaWindow] {
            var merged = current
            for index in merged.indices {
                let window = merged[index]
                guard !window.state.isCurrent,
                      let match = cached.first(where: {
                          $0.semanticIdentity == window.semanticIdentity && $0.state.isDisplayable
                      })
                else { continue }
                merged[index] = QuotaWindow(
                    limitId: window.limitId,
                    windowId: window.windowId,
                    kind: window.kind,
                    durationMinutes: window.durationMinutes ?? match.durationMinutes,
                    remainingPercent: match.remainingPercent,
                    state: .cached,
                    resetAt: window.resetAt ?? match.resetAt
                )
            }
            let identities = Set(merged.map(\.semanticIdentity))
            for cachedWindow in cached
                where cachedWindow.state.isDisplayable && !identities.contains(cachedWindow.semanticIdentity) {
                merged.append(
                    QuotaWindow(
                        limitId: cachedWindow.limitId,
                        windowId: cachedWindow.windowId,
                        kind: cachedWindow.kind,
                        durationMinutes: cachedWindow.durationMinutes,
                        remainingPercent: cachedWindow.remainingPercent,
                        state: .cached,
                        resetAt: cachedWindow.resetAt
                    )
                )
            }
            return merged.sorted { $0.id < $1.id }
        }

        func snapshot(_ windows: [QuotaWindow]) -> QuotaSnapshot {
            QuotaSnapshot(
                weeklyQuotaPercent: 0,
                fiveHourQuotaPercent: 0,
                weeklyQuotaState: .unavailable,
                fiveHourQuotaState: .unavailable,
                refreshedAt: Date(timeIntervalSince1970: 100),
                dataSource: .real,
                quotaWindows: windows,
                accountBoundary: .testDefault
            )
        }

        let current = snapshot(currentWindows)
        let cached = snapshot(cachedWindows)
        let reference = linearScanMerge(current: currentWindows, cached: cachedWindows)
        XCTAssertEqual(current.mergingPartial(with: cached).quotaWindows, reference)

        for round in 0..<5 {
            var start = Date()
            var baselineWindows = 0
            for _ in 0..<20 {
                baselineWindows += linearScanMerge(current: currentWindows, cached: cachedWindows).count
            }
            let baseline = Date().timeIntervalSince(start)
            start = Date()
            var indexedWindows = 0
            for _ in 0..<20 {
                indexedWindows += current.mergingPartial(with: cached).quotaWindows.count
            }
            let indexed = Date().timeIntervalSince(start)
            XCTAssertEqual(baselineWindows, indexedWindows)
            print(
                "BENCH quota-window-merge×20 round=\(round) windows=\(windowCount) "
                    + "baseline=\(baseline) indexed=\(indexed)"
            )
        }
    }

    func testPersistenceAndTrendBaseline() throws {
        guard ProcessInfo.processInfo.environment["CODEX_MONITOR_BENCHMARK"] == "1" else {
            throw XCTSkip("Opt-in performance comparison")
        }
        let suite = "OptimizationBenchmarkTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SnapshotStore(defaults: defaults, key: "benchmark")
        let snapshot = QuotaSnapshot.notConnected
        let base = Date(timeIntervalSince1970: 10_000)
        let histories = [60.0, 600.0, 3600.0].map { interval in
            UsageTrendHistory(accountBoundary: nil, samples: (0..<96).map {
                UsageTrendSample(recordedAt: base.addingTimeInterval(Double($0) * interval),
                                 remainingPercent: 100 - $0, resetAt: nil)
            })
        }
        for round in 0..<5 {
            var start = Date()
            for _ in 0..<500 {
                XCTAssertTrue(store.saveSnapshot(snapshot))
                XCTAssertEqual(store.loadSnapshot(), snapshot)
            }
            let persistence = Date().timeIntervalSince(start)
            start = Date()
            var rateSum = 0.0
            var consuming = 0
            for _ in 0..<10_000 {
                for history in histories {
                    let result = UsageTrendAnalyzer.analyze(history: history, currentResetAt: nil)
                    rateSum += result.ratePercentPerHour ?? 0
                    if result.state == .consuming { consuming += 1 }
                }
            }
            XCTAssertEqual(rateSum, 670_000)
            XCTAssertEqual(consuming, 30_000)
            print("BENCH round=\(round) persistence=\(persistence) trend=\(Date().timeIntervalSince(start)) rateSum=\(rateSum) consuming=\(consuming)")
        }
    }

    /// A refresh commits the same quota state twice (refreshing + settled) and
    /// repeated refusals re-commit the last accepted snapshot, so the trend
    /// analyzer used to run once per commit for an unchanged sample. This
    /// measures the analyzer work that repetition used to perform against the
    /// end-to-end cost of the same commits after memoizing the analysis input.
    @MainActor
    func testRepeatedCommitTrendAnalysisBaseline() async throws {
        guard ProcessInfo.processInfo.environment["CODEX_MONITOR_BENCHMARK"] == "1" else {
            throw XCTSkip("Opt-in performance comparison")
        }
        let suite = "OptimizationBenchmarkTests.trend.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let base = Date(timeIntervalSince1970: 20_000)
        let resetAt = base.addingTimeInterval(6 * 24 * 3600)
        // A saturated history makes the analyzer's per-call cost measurable;
        // its sample values match the refreshes replayed below.
        let snapshots = (0..<96).map { index in
            QuotaSnapshot(
                weeklyQuotaPercent: 96 - index,
                fiveHourQuotaPercent: 80,
                refreshedAt: base.addingTimeInterval(Double(index) * 600),
                dataSource: .real,
                quotaWindows: [
                    QuotaWindow(
                        limitId: "codex",
                        windowId: "secondary",
                        kind: .weekly,
                        durationMinutes: 10_080,
                        remainingPercent: 96 - index,
                        resetAt: resetAt
                    )
                ],
                accountBoundary: .testDefault
            )
        }
        let appState = AppState(
            snapshotStore: SnapshotStore(defaults: defaults, key: "benchmark"),
            refreshService: RepeatingTailRefreshService(snapshots: snapshots),
            now: { base.addingTimeInterval(95 * 600) },
            sleep: { _ in throw CancellationError() },
            accountBoundaryProvider: { .testDefault },
            usageTrendStore: UsageTrendStore(defaults: defaults, key: "trend")
        )
        defer { appState.shutdown() }
        for _ in 0..<96 {
            await appState.refreshNow(trigger: .manual)
        }
        let history = try XCTUnwrap(
            UsageTrendStore(defaults: defaults, key: "trend").load(matching: .testDefault)
        )
        XCTAssertEqual(history.samples.count, 96)

        let refreshes = 100
        let commits = refreshes * 2
        for round in 0..<5 {
            var start = Date()
            var rateSum = 0.0
            for _ in 0..<commits {
                rateSum += UsageTrendAnalyzer.analyze(history: history, currentResetAt: resetAt).ratePercentPerHour ?? 0
            }
            let redundant = Date().timeIntervalSince(start)

            let invocationBaseline = UsageTrendAnalyzer.debugAnalysisInvocationCount
            start = Date()
            for _ in 0..<refreshes {
                await appState.refreshNow(trigger: .manual)
            }
            let memoized = Date().timeIntervalSince(start)
            let invocations = UsageTrendAnalyzer.debugAnalysisInvocationCount - invocationBaseline
            XCTAssertEqual(invocations, 0)
            print(
                "BENCH trend-redundancy round=\(round) commits=\(commits) redundantAnalyze=\(redundant) "
                    + "memoizedCommits=\(memoized) analyzeInvocations=\(invocations) rateSum=\(rateSum)"
            )
        }
    }

    /// A commit that replaced an already-valid primary used to validate that
    /// datum three separate times (`containsNewerPersistenceVersion`,
    /// `loadEnvelope`, and `isTrustedPersistenceData`). The single-pass audit now
    /// performs the first of those validation passes plus the write readback, so
    /// this replays exactly the second and third envelope validations and their
    /// payload decodes — the four decode passes that were removed. Because the
    /// old commit performed the same audit-equivalent and write work, its cost
    /// is `commit + removedValidation`.
    func testSnapshotStoreRedundantValidationBaseline() throws {
        guard ProcessInfo.processInfo.environment["CODEX_MONITOR_BENCHMARK"] == "1" else {
            throw XCTSkip("Opt-in performance comparison")
        }
        let suite = "OptimizationBenchmarkTests.snapshot.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SnapshotStore(defaults: defaults, key: "benchmark")
        let snapshot = QuotaSnapshot(
            weeklyQuotaPercent: 72,
            fiveHourQuotaPercent: 69,
            resetAvailableCount: 2,
            resetCreditDetails: (0..<4).map {
                ResetCreditDetailSnapshot(
                    ordinal: $0,
                    status: "available",
                    grantedAt: Date(timeIntervalSince1970: 800),
                    expiresAt: Date(timeIntervalSince1970: 4_000 + Double($0) * 600)
                )
            },
            resetBanks: (0..<3).map {
                ResetBankSnapshot(
                    limitId: "codex",
                    windowId: "w\($0)",
                    displayName: "Bank \($0)",
                    remainingPercent: 72 - $0,
                    resetAt: Date(timeIntervalSince1970: 5_000)
                )
            },
            refreshedAt: Date(timeIntervalSince1970: 1_000),
            dataSource: .real,
            quotaWindows: (0..<4).map {
                QuotaWindow(
                    limitId: "codex",
                    windowId: "w\($0)",
                    kind: .weekly,
                    durationMinutes: 10_080,
                    remainingPercent: 72 - $0,
                    resetAt: Date(timeIntervalSince1970: 5_000)
                )
            },
            accountBoundary: .testDefault
        )
        let state = PersistedAppState(
            snapshot: snapshot,
            status: .success,
            lastSuccessAt: snapshot.refreshedAt,
            lastAttemptAt: nil,
            failureCount: 0
        )
        XCTAssertTrue(store.saveState(state))
        let primary = try XCTUnwrap(defaults.data(forKey: "benchmark"))

        XCTAssertEqual(removedValidationDecodeCount(of: primary), 4)

        let iterations = 200
        for round in 0..<5 {
            var start = Date()
            for _ in 0..<iterations {
                _ = removedValidationDecodeCount(of: primary)
            }
            let removedValidation = Date().timeIntervalSince(start)

            let decodeBaseline = SnapshotStore.debugPersistenceDecodeCount
            start = Date()
            for _ in 0..<iterations {
                XCTAssertTrue(store.saveState(state))
            }
            let commit = Date().timeIntervalSince(start)
            let commitDecodes = SnapshotStore.debugPersistenceDecodeCount - decodeBaseline

            print(
                "BENCH snapshot-store round=\(round) iterations=\(iterations) "
                    + "legacyCommitDecodes=\(iterations * 10) commitDecodes=\(commitDecodes) "
                    + "removedValidation=\(removedValidation) commit=\(commit) "
                    + "estimatedLegacyCommit=\(removedValidation + commit)"
            )
            XCTAssertEqual(commitDecodes, iterations * 6)
        }
    }

    /// One widget-state load used to classify the same primary bytes through
    /// `containsNewerPersistenceVersion` and `decodeEnvelope`, and one commit
    /// classified them four more times before encoding the same
    /// `WidgetDisplayState` twice. This measures save+load pairs end to end, so
    /// the same benchmark can be run against the pre-change store in an isolated
    /// copy of the repository. The `scaled` payload makes the JSON work
    /// measurable; the `realistic` payload is roughly what a refresh publishes,
    /// where file I/O dominates.
    func testWidgetDisplayStateStoreBaseline() throws {
        guard ProcessInfo.processInfo.environment["CODEX_MONITOR_BENCHMARK"] == "1" else {
            throw XCTSkip("Opt-in performance comparison")
        }
        let groupURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("OptimizationBenchmarkTests.widgetState.\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: groupURL) }
        let fileManager = BenchmarkWidgetStateFileManager(groupURL: groupURL)
        let now = Date(timeIntervalSince1970: 1_000)

        func makeState(windowCount: Int, creditCount: Int, bankCount: Int) -> WidgetDisplayState {
            WidgetDisplayState.make(
                snapshot: QuotaSnapshot(
                    weeklyQuotaPercent: 72,
                    fiveHourQuotaPercent: 69,
                    resetAvailableCount: 3,
                    resetCreditDetailsState: .detailed,
                    resetCreditDetails: (0..<creditCount).map {
                        ResetCreditDetailSnapshot(
                            ordinal: $0,
                            status: "available",
                            grantedAt: now,
                            expiresAt: now.addingTimeInterval(Double($0) * 600 + 600)
                        )
                    },
                    resetBanks: (0..<bankCount).map {
                        ResetBankSnapshot(
                            limitId: "codex",
                            windowId: "bank-\($0)",
                            displayName: "Bank \($0)",
                            remainingPercent: 72 - $0,
                            resetAt: now.addingTimeInterval(3_600)
                        )
                    },
                    refreshedAt: now,
                    dataSource: .real,
                    quotaWindows: (0..<windowCount).map {
                        QuotaWindow(
                            limitId: "codex",
                            windowId: "window-\($0)",
                            kind: $0.isMultiple(of: 2) ? .weekly : .fiveHour,
                            durationMinutes: 10_080 + $0,
                            remainingPercent: 100 - $0 % 100,
                            resetAt: now.addingTimeInterval(Double($0) * 60)
                        )
                    },
                    accountBoundary: .testDefault
                ),
                status: .success,
                lastSuccessAt: now,
                lastAttemptAt: now,
                effectiveFiveHourResetAt: now,
                savedAt: now
            )
        }

        let payloads = [
            (label: "scaled", state: makeState(windowCount: 256, creditCount: 64, bankCount: 8)),
            (label: "realistic", state: makeState(windowCount: 4, creditCount: 3, bankCount: 2))
        ]
        for payload in payloads {
            XCTAssertTrue(WidgetDisplayStateStore.save(payload.state, fileManager: fileManager))
        }

        let iterations = 100
        for payload in payloads {
            for round in 0..<5 {
                var start = Date()
                for _ in 0..<iterations {
                    XCTAssertTrue(WidgetDisplayStateStore.save(payload.state, fileManager: fileManager))
                }
                let save = Date().timeIntervalSince(start)

                start = Date()
                for _ in 0..<iterations {
                    XCTAssertEqual(WidgetDisplayStateStore.load(fileManager: fileManager), payload.state)
                }
                let load = Date().timeIntervalSince(start)
                print(
                    "BENCH widget-state[\(payload.label)] round=\(round) iterations=\(iterations) "
                        + "save=\(save) load=\(load) combined=\(save + load)"
                )
            }
        }
    }

    /// A rate-limit response used to be parsed twice: `JSONSerialization` validated the top-level
    /// shape and `JSONDecoder` then decoded the same line into `CodexAppServerMessage`, whose value
    /// tree `handleRateLimitsResponse` immediately converted back to a Foundation object.
    /// `decodeLine` now reads the message straight from the parsed object, so this measures the
    /// whole line-to-snapshot path that both trees expose: the shared codec entry point plus the
    /// quota parser. The stage columns isolate where the work goes: `json` is one
    /// `JSONSerialization` pass, `decode` adds `decodeLine`, `convert` adds `foundationObject()`,
    /// `parse` is the quota parser alone on an already-converted object, and `full` is the
    /// complete `decodeLine` → `foundationObject()` → `parseRateLimits` path.
    func testRPCLineDecodeBaseline() throws {
        guard ProcessInfo.processInfo.environment["CODEX_MONITOR_BENCHMARK"] == "1" else {
            throw XCTSkip("Opt-in performance comparison")
        }

        let payloads = [
            (label: "realistic", line: Self.realisticRateLimitLine, windowCount: 2),
            (label: "scaled", line: Self.scaledRateLimitLine, windowCount: 3)
        ]
        let iterations = 200
        for payload in payloads {
            let expected = try Self.snapshot(fromRateLimitLine: payload.line)
            XCTAssertEqual(expected.quotaWindows.count, payload.windowCount)

            for round in 0..<5 {
                var start = Date()
                var jsonCount = 0
                for _ in 0..<iterations {
                    let object = try JSONSerialization.jsonObject(
                        with: payload.line,
                        options: [.fragmentsAllowed]
                    ) as? [String: Any]
                    jsonCount += object?.count ?? 0
                }
                let json = Date().timeIntervalSince(start)

                start = Date()
                var decodedCount = 0
                for _ in 0..<iterations {
                    let message = try CodexAppServerCodec.decodeLine(payload.line)
                    if case .response = message { decodedCount += 1 }
                }
                let decode = Date().timeIntervalSince(start)

                let message = try CodexAppServerCodec.decodeLine(payload.line)
                guard case .response(_, let result) = message else {
                    throw BenchmarkFailure.unexpectedMessage
                }
                let converted = try XCTUnwrap(result.foundationObject())

                start = Date()
                var convertedCount = 0
                for _ in 0..<iterations {
                    convertedCount += result.foundationObject()?.count ?? 0
                }
                let convert = Date().timeIntervalSince(start)

                start = Date()
                var parsedWindows = 0
                for _ in 0..<iterations {
                    parsedWindows += RealQuotaProvider.parseRateLimits(response: converted)?
                        .quotaWindows.count ?? 0
                }
                let parse = Date().timeIntervalSince(start)

                start = Date()
                var windows = 0
                var weeklySum = 0
                var fiveHourSum = 0
                for _ in 0..<iterations {
                    let message = try CodexAppServerCodec.decodeLine(payload.line)
                    guard case .response(_, let result) = message,
                          let object = result.foundationObject(),
                          let snapshot = RealQuotaProvider.parseRateLimits(response: object) else {
                        continue
                    }
                    windows += snapshot.quotaWindows.count
                    weeklySum += snapshot.weeklyQuotaPercent
                    fiveHourSum += snapshot.fiveHourQuotaPercent
                }
                let full = Date().timeIntervalSince(start)

                XCTAssertEqual(decodedCount, iterations)
                XCTAssertEqual(windows, parsedWindows)
                XCTAssertEqual(parsedWindows, payload.windowCount * iterations)
                XCTAssertEqual(weeklySum, expected.weeklyQuotaPercent * iterations)
                XCTAssertEqual(fiveHourSum, expected.fiveHourQuotaPercent * iterations)
                XCTAssertGreaterThan(jsonCount + convertedCount, 0)
                print(
                    "BENCH rpc-line[\(payload.label)] bytes=\(payload.line.count) round=\(round) "
                        + "iterations=\(iterations) json=\(json) decode=\(decode) convert=\(convert) "
                        + "parse=\(parse) full=\(full)"
                )
            }
        }
    }

    private static func snapshot(fromRateLimitLine line: Data) throws -> QuotaSnapshot {
        let message = try CodexAppServerCodec.decodeLine(line)
        guard case .response(_, let result) = message,
              let object = result.foundationObject() else {
            throw BenchmarkFailure.unexpectedMessage
        }
        return try XCTUnwrap(RealQuotaProvider.parseRateLimits(response: object))
    }

    private static let realisticRateLimitLine = Data(
        #"{"id":2,"result":{"rateLimitsByLimitId":{"codex":{"primary":{"windowDurationMins":300,"usedPercent":50},"secondary":{"windowDurationMins":10080,"usedPercent":25}}}}}"#.utf8
    )

    private static let scaledRateLimitLine = Data(
        """
        {"id":2,"result":{"rateLimits":{"primary":{"windowDurationMins":300,"usedPercent":12.5,"resetAt":1800000000.123},"secondary":{"windowDurationMins":10080,"usedPercent":43.75,"resetAt":1800500000.5},"credits":{"hasCredits":true,"unlimited":false,"balance":"12.50"},"planType":"plus"},"rateLimitsByLimitId":{"codex":{"primary":{"windowDurationMins":300,"usedPercent":12.5,"resetAt":1800000000.123},"secondary":{"windowDurationMins":10080,"usedPercent":43.75,"resetAt":1800500000.5},"limitId":"codex","limitName":"Codex"},"codex_other":{"primary":{"windowDurationMins":10080,"usedPercent":7.25,"resetAt":1800900000.25},"limitId":"codex_other","limitName":"Codex Other"}},"rateLimitResetCredits":{"availableCount":3,"credits":[{"status":"available","granted_at":"2026-01-01T03:04:05.000Z","expires_at":"2026-02-01T03:04:05.000Z","id":"credit-0"},{"status":"redeemed","granted_at":"2026-01-02T03:04:05.000Z","expires_at":"2026-02-02T03:04:05.000Z","id":"credit-1"},{"status":"available","granted_at":"2026-01-03T03:04:05.000Z","expires_at":"2026-02-03T03:04:05.000Z","id":"credit-2"},{"status":"redeemed","granted_at":"2026-01-04T03:04:05.000Z","expires_at":"2026-02-04T03:04:05.000Z","id":"credit-3"},{"status":"available","granted_at":"2026-01-05T03:04:05.000Z","expires_at":"2026-02-05T03:04:05.000Z","id":"credit-4"},{"status":"redeemed","granted_at":"2026-01-06T03:04:05.000Z","expires_at":"2026-02-06T03:04:05.000Z","id":"credit-5"}]},"rateLimitResetCreditsSummary":{"availableCredits":3,"totalCredits":6}}}
        """.utf8
    )

    private enum BenchmarkFailure: Error {
        case unexpectedMessage
    }
}

/// Routes the widget state store at an isolated directory, like the other
/// widget-state test file managers, without sharing their private types.
private final class BenchmarkWidgetStateFileManager: FileManager {
    private let groupURL: URL

    init(groupURL: URL) {
        self.groupURL = groupURL
        super.init()
    }

    override func containerURL(forSecurityApplicationGroupIdentifier groupIdentifier: String) -> URL? {
        groupURL
    }
}

/// Replays the decode passes the pre-change commit performed beyond the single
/// audit and the write readback that remain: the second envelope validation from
/// `loadEnvelope`, the third from `isTrustedPersistenceData`, and both payload
/// decodes. Returns how many JSON decodes it performed.
private func removedValidationDecodeCount(of data: Data) -> Int {
    let decoder = JSONDecoder()
    var decodes = 0

    func count<T: Decodable>(_ decode: () -> T?) -> T? {
        decodes += 1
        return decode()
    }

    // `loadEnvelope` followed by `isTrustedPersistenceData`'s `loadEnvelope`.
    for _ in 0..<2 {
        if let envelope = count({ try? decoder.decode(PersistenceEnvelope.self, from: data) }) {
            _ = count { try? envelope.decode(PersistedAppState.self) }
        }
    }
    return decodes
}

/// Yields the given snapshots once, then keeps returning the last one so the
/// benchmark can replay commits of an unchanged sample.
private actor RepeatingTailRefreshService: QuotaRefreshing {
    private var pending: [QuotaSnapshot]
    private let repeating: QuotaSnapshot

    init(snapshots: [QuotaSnapshot]) {
        self.pending = snapshots
        self.repeating = snapshots[snapshots.count - 1]
    }

    func refresh(basedOn current: QuotaSnapshot) async throws -> QuotaSnapshot {
        if pending.isEmpty { return repeating }
        return pending.removeFirst()
    }
}
