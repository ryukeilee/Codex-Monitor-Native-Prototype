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

    /// Measures one commit over an already-valid primary together with the decode
    /// work this round removed.
    ///
    /// Decode counts here are exact observations: a warm commit performs three
    /// JSON decodes per iteration, and `removedRoundDecodeCount` replays exactly
    /// the kinds and counts of decodes this round dropped (the write readback's
    /// envelope validation and payload decode, plus the newer-schema probe's
    /// legacy-shape fallback). A commit that replaced an already-valid primary
    /// used to validate that datum three separate times
    /// (`containsNewerPersistenceVersion`, `loadEnvelope`, and
    /// `isTrustedPersistenceData`) and probe it twice for a newer raw snapshot,
    /// so the pre-round path ran six decodes. That six is a constant describing
    /// the old code path rather than a measurement of it, and the wall-clock gain
    /// printed below is estimated by replaying those removed decodes instead of
    /// timing the old implementation.
    func testSnapshotStoreCommitDecodeCountIsExactAndRemovedCostIsEstimated() throws {
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

        XCTAssertEqual(removedRoundDecodeCount(of: primary), 3)

        let iterations = 200
        // The pre-round commit ran six decodes per iteration. This is an explicit
        // expectation of the removed path, not a measurement of it.
        let expectedPreRoundCommitDecodes = iterations * 6
        for round in 0..<5 {
            var start = Date()
            for _ in 0..<iterations {
                _ = removedRoundDecodeCount(of: primary)
            }
            let removedRound = Date().timeIntervalSince(start)

            let decodeBaseline = SnapshotStore.debugPersistenceDecodeCount
            start = Date()
            for _ in 0..<iterations {
                XCTAssertTrue(store.saveState(state))
            }
            let commit = Date().timeIntervalSince(start)
            let commitDecodes = SnapshotStore.debugPersistenceDecodeCount - decodeBaseline

            print(
                "BENCH snapshot-store round=\(round) iterations=\(iterations) "
                    + "expectedPreRoundCommitDecodes=\(expectedPreRoundCommitDecodes) commitDecodes=\(commitDecodes) "
                    + "removedRoundDecodeReplay=\(removedRound) commit=\(commit) "
                    + "estimatedPreRoundCommit=\(removedRound + commit)"
            )
            XCTAssertEqual(commitDecodes, iterations * 3)
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
    /// `decodeLine` now reads the message straight from the parsed object, and the production
    /// client goes further: `decodeInboundFrame` keeps the response payload as the Foundation
    /// object, so nothing builds a value tree or converts it back. This measures the whole
    /// line-to-snapshot path that both trees expose. The stage columns isolate where the work goes:
    /// `json` is one `JSONSerialization` pass, `decode` adds the typed `decodeLine`,
    /// `convert` adds `foundationObject()`, `parse` is the quota parser alone on an
    /// already-converted object, `full` is the legacy `decodeLine` → `foundationObject()` →
    /// `parseRateLimits` chain, `inbound` is the production `decodeInboundFrame`, and
    /// `productionFull` is the production `decodeInboundFrame` → `parseRateLimits` chain.
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

                start = Date()
                var inboundCount = 0
                for _ in 0..<iterations {
                    let frame = try CodexAppServerCodec.decodeInboundFrame(payload.line)
                    if case .response = frame { inboundCount += 1 }
                }
                let inbound = Date().timeIntervalSince(start)

                start = Date()
                var productionWindows = 0
                for _ in 0..<iterations {
                    let frame = try CodexAppServerCodec.decodeInboundFrame(payload.line)
                    guard case .response(_, let result) = frame,
                          let object = result as? [String: Any],
                          let snapshot = RealQuotaProvider.parseRateLimits(response: object) else {
                        continue
                    }
                    productionWindows += snapshot.quotaWindows.count
                }
                let productionFull = Date().timeIntervalSince(start)

                XCTAssertEqual(decodedCount, iterations)
                XCTAssertEqual(inboundCount, iterations)
                XCTAssertEqual(productionWindows, payload.windowCount * iterations)
                XCTAssertEqual(windows, parsedWindows)
                XCTAssertEqual(parsedWindows, payload.windowCount * iterations)
                XCTAssertEqual(weeklySum, expected.weeklyQuotaPercent * iterations)
                XCTAssertEqual(fiveHourSum, expected.fiveHourQuotaPercent * iterations)
                XCTAssertGreaterThan(jsonCount + convertedCount, 0)
                print(
                    "BENCH rpc-line[\(payload.label)] bytes=\(payload.line.count) round=\(round) "
                        + "iterations=\(iterations) json=\(json) decode=\(decode) convert=\(convert) "
                        + "parse=\(parse) full=\(full) inbound=\(inbound) productionFull=\(productionFull)"
                )
            }
        }
    }

    /// `CodexAuthBoundaryObserver` 每秒调用一次 `CodexAuthIdentityReader.currentBoundary()`，
    /// 其中绝大部分成本是重复解析一份绝大多数时候没变的 `auth.json`。
    /// `CodexAuthBoundaryPoller` 以原始字节为键跳过解析，本基准给出「每次调用都解析」与
    /// 「字节比较 + 命中即跳过」的 per-call 对比。`synthetic` 列用 ≥4 KB 的合成 payload，
    /// 任何机器都能复现，它测的是纯解析 vs 纯命中，因此用可控的固定字节手搓 poller。
    /// `real` 列测的是**生产接线本身**：被测对象是
    /// `CodexAuthBoundaryObserver.makeDefaultAuthBoundaryProvider()` 返回的闭包，也就是
    /// `AppDelegate` 装配 observer 时实际走的那条路径（工厂 + 默认 `readData`）。
    /// 两列都只输出耗时与字节数，绝不输出文件内容、账号标识或令牌。
    @MainActor
    func testAuthBoundaryPollBaseline() throws {
        guard ProcessInfo.processInfo.environment["CODEX_MONITOR_BENCHMARK"] == "1" else {
            throw XCTSkip("Opt-in performance comparison")
        }
        let iterations = 200
        func perCallMicroseconds(_ elapsed: TimeInterval) -> Double {
            elapsed / Double(iterations) * 1_000_000
        }

        let synthetic = Self.authBoundaryPayload(paddingBytes: 4_096)
        XCTAssertGreaterThan(synthetic.count, 4_096)
        let syntheticPoller = CodexAuthBoundaryPoller(readData: { synthetic })
        XCTAssertNotNil(syntheticPoller.currentBoundary())
        for round in 0..<5 {
            var start = Date()
            var parsed = 0
            for _ in 0..<iterations {
                parsed += CodexAuthIdentityReader.parse(data: synthetic) == nil ? 0 : 1
            }
            let parseEveryCall = Date().timeIntervalSince(start)

            start = Date()
            var hits = 0
            for _ in 0..<iterations {
                hits += syntheticPoller.currentBoundary() == nil ? 0 : 1
            }
            let memoizedHit = Date().timeIntervalSince(start)

            XCTAssertEqual(parsed, iterations)
            XCTAssertEqual(hits, iterations)
            print(
                "BENCH auth-boundary[synthetic] bytes=\(synthetic.count) round=\(round) iterations=\(iterations) "
                    + "parseEveryCallUs=\(perCallMicroseconds(parseEveryCall)) "
                    + "memoizedHitUs=\(perCallMicroseconds(memoizedHit)) "
                    + "ratio=\(parseEveryCall / memoizedHit)"
            )
        }

        // 生产路径：旧的每次轮询 = 读文件 + 解析；新的每次轮询 = 读文件 + 字节比较。
        // 两段跳过分支都只打印、不失败：本机没有可读 `auth.json`（未登录），或文件可读但
        // 身份不可验证（`auth_mode` 非 chatgpt、令牌形状异常、文件损坏），都属于环境状态，
        // 不是基准要证明的东西。
        guard let realData = CodexAuthIdentityReader.currentAuthData() else {
            print("BENCH auth-boundary[real] skipped: no readable auth.json in this CODEX_HOME")
            return
        }
        guard let baseline = CodexAuthIdentityReader.currentBoundary(), baseline.isValid else {
            print(
                "BENCH auth-boundary[real] skipped: readable auth.json (bytes=\(realData.count)) "
                    + "but the identity is not verifiable in this CODEX_HOME"
            )
            return
        }
        // 工厂产物：与 `AppDelegate` 装配 observer 时用的是同一个入口。若默认参数被改写成
        // 内联的 `CodexAuthBoundaryPoller().currentBoundary()`，每次求值都会新建 poller，
        // 这一列的加速比会退回 ~1×。
        let productionProvider = CodexAuthBoundaryObserver.makeDefaultAuthBoundaryProvider()
        XCTAssertEqual(productionProvider(), baseline)
        for round in 0..<5 {
            var start = Date()
            var readAndParsed = 0
            for _ in 0..<iterations {
                readAndParsed += CodexAuthIdentityReader.currentBoundary() == nil ? 0 : 1
            }
            let readAndParse = Date().timeIntervalSince(start)

            start = Date()
            var readAndCompared = 0
            for _ in 0..<iterations {
                readAndCompared += productionProvider() == nil ? 0 : 1
            }
            let readAndCompare = Date().timeIntervalSince(start)

            XCTAssertEqual(readAndParsed, iterations)
            XCTAssertEqual(readAndCompared, iterations)
            print(
                "BENCH auth-boundary[real] bytes=\(realData.count) round=\(round) iterations=\(iterations) "
                    + "oldPollReadAndParseUs=\(perCallMicroseconds(readAndParse)) "
                    + "newPollReadAndCompareUs=\(perCallMicroseconds(readAndCompare)) "
                    + "ratio=\(readAndParse / readAndCompare)"
            )
        }
    }

    /// 一份形状真实的合成 auth JSON（值全部是合成值），`padding` 用来把体积推到真实的 ~4 KB。
    private static func authBoundaryPayload(paddingBytes: Int) -> Data {
        let claims: [String: Any] = ["sub": "bench-subject", "sid": "bench-session"]
        let claimPayload = try! JSONSerialization.data(withJSONObject: claims, options: [.sortedKeys])
        let syntheticJWT = "header." + claimPayload.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "") + ".signature"
        return try! JSONSerialization.data(withJSONObject: [
            "auth_mode": "chatgpt",
            "tokens": [
                "id_token": syntheticJWT,
                "refresh_token": "bench-refresh-token",
                "account_id": "bench-account-id"
            ],
            "padding": String(repeating: "A", count: paddingBytes)
        ], options: [.sortedKeys])
    }

    /// Measures stdout framing end to end through the real `CodexRPCClient`.
    ///
    /// The `baseline`, `hoisted` and `rewrite` columns are SIMPLIFIED FRAMING MODELS, not verbatim
    /// copies of the production loop: they substitute a frame counter for the real line handler
    /// (JSON decode, request matching, completion) and omit the production init/EOF state machine.
    /// They isolate the buffer arithmetic this round touched. Because `baseline` and `hoisted` are
    /// structurally identical apart from the LF search operand, their ratio is a valid in-process
    /// measure of the LF-constant hoist. `rewrite` models the single-removal alternative that was
    /// measured and deliberately not shipped.
    ///
    /// The `production` column is a DIFFERENT CODE PATH: one whole refresh per call, including the
    /// per-iteration client and transport construction, request encoding, async scheduling, JSON
    /// decode, snapshot parse and XCTest assertions. A `framing/production` ratio is therefore NOT a
    /// production time share, and neither is a difference against a smaller workload (the removed
    /// frames also remove their JSON processing).
    func testRPCStdoutFramingBaseline() async throws {
        guard ProcessInfo.processInfo.environment["CODEX_MONITOR_BENCHMARK"] == "1" else {
            throw XCTSkip("Opt-in performance comparison")
        }
        let maxFrameBytes = 512 * 1_024

        for workload in Self.rpcFramingWorkloads() {
            for round in 0..<5 {
                var start = Date()
                for _ in 0..<workload.iterations {
                    let transport = BenchmarkRPCTransport(script: workload.script)
                    let client = CodexRPCClient(
                        transport: transport,
                        timeoutScheduler: BenchmarkTimeoutScheduler()
                    )
                    do {
                        let snapshot = try await client.fetchQuota(timeoutSeconds: 60)
                        XCTAssertNil(workload.expectedFailure, "\(workload.label) completed but must fail")
                        XCTAssertEqual(snapshot.fiveHourQuotaPercent, 50, workload.label)
                    } catch let error as RealQuotaError {
                        XCTAssertEqual(error, workload.expectedFailure, "\(workload.label) failed unexpectedly")
                    } catch {
                        XCTFail("\(workload.label) failed unexpectedly: \(error)")
                    }
                }
                let production = Date().timeIntervalSince(start) / Double(workload.iterations)

                start = Date()
                var baselineFrames = 0
                for _ in 0..<workload.iterations {
                    let result = Self.framingLoop(
                        workload.script,
                        maxFrameBytes: maxFrameBytes,
                        stopAfterFrames: workload.frames,
                        variant: .baseline
                    )
                    XCTAssertEqual(result.didFail, workload.expectedFailure != nil, workload.label)
                    baselineFrames += result.frames
                }
                let baseline = Date().timeIntervalSince(start) / Double(workload.iterations)

                start = Date()
                var hoistedFrames = 0
                for _ in 0..<workload.iterations {
                    let result = Self.framingLoop(
                        workload.script,
                        maxFrameBytes: maxFrameBytes,
                        stopAfterFrames: workload.frames,
                        variant: .hoisted
                    )
                    XCTAssertEqual(result.didFail, workload.expectedFailure != nil, workload.label)
                    hoistedFrames += result.frames
                }
                let hoisted = Date().timeIntervalSince(start) / Double(workload.iterations)

                start = Date()
                var rewriteFrames = 0
                for _ in 0..<workload.iterations {
                    let result = Self.framingLoop(
                        workload.script,
                        maxFrameBytes: maxFrameBytes,
                        stopAfterFrames: workload.frames,
                        variant: .singleRemoval
                    )
                    XCTAssertEqual(result.didFail, workload.expectedFailure != nil, workload.label)
                    rewriteFrames += result.frames
                }
                let rewrite = Date().timeIntervalSince(start) / Double(workload.iterations)

                XCTAssertEqual(baselineFrames, workload.frames * workload.iterations, workload.label)
                XCTAssertEqual(hoistedFrames, workload.frames * workload.iterations, workload.label)
                XCTAssertEqual(rewriteFrames, workload.frames * workload.iterations, workload.label)
                print(
                    "BENCH rpc-framing[\(workload.label)] bytes=\(workload.bytes) chunks=\(workload.chunkCount) "
                        + "frames=\(workload.frames) round=\(round) iterations=\(workload.iterations) "
                        + "productionPerCall=\(production) baseline=\(baseline) hoisted=\(hoisted) "
                        + "rewrite=\(rewrite) baselineOverHoisted=\(baseline / hoisted) "
                        + "baselineOverProduction=\(baseline / production) "
                        + "hoistedOverProduction=\(hoisted / production)"
                )
            }
        }
    }

    /// The stdout scripts the framing benchmark drives, in the shapes a refresh and a hostile peer
    /// can produce.
    private static func rpcFramingWorkloads() -> [RPCFramingWorkload] {
        let maxFrameBytes = 512 * 1_024
        let initializeResponse = line(
            #"{"id":1,"result":{"codexHome":"/tmp/codex","platformFamily":"unix","platformOs":"macos","userAgent":"codex-test"}}"#
        )
        let rateLimitsResponse = line(#"{"id":2,"result":{"rateLimits":{"primary":{"windowDurationMins":300,"usedPercent":50}}}}"#)
        let realisticRateLimitsResponse = line(
            #"{"id":2,"result":{"rateLimits":{"primary":{"windowDurationMins":300,"usedPercent":50}},"padding":""#
                + String(repeating: "A", count: 1_392)
                + #""}}"#
        )
        let notification = line(#"{"method":"account/rateLimits/updated","params":{}}"#)
        let completion = initializeResponse + rateLimitsResponse

        var workloads: [RPCFramingWorkload] = [
            // The realistic shape: one 16 KiB read that already holds the whole exchange.
            RPCFramingWorkload(
                label: "realistic-3frame",
                script: [.stdout(initializeResponse + notification + realisticRateLimitsResponse)],
                frames: 3,
                iterations: 300
            ),
            // The same shape with the frames that do the work removed: it bounds the fixed cost of
            // the production column, but its difference against `realistic-3frame` also mixes in
            // the removed frames' JSON processing, so that difference is not a framing share.
            RPCFramingWorkload(
                label: "floor-2frame",
                script: [.stdout(completion)],
                frames: 2,
                iterations: 300
            )
        ]

        // Saturated 16 KiB chunks: the shape that makes the loop's per-frame arithmetic visible.
        for frameSize in [19, 200, 1_024, 8_192] {
            let frame = notificationFrame(wireBytes: frameSize)
            var chunk = Data()
            for _ in 0..<(16_384 / frameSize) {
                chunk.append(frame)
            }
            workloads.append(
                RPCFramingWorkload(
                    label: "saturated-\(frameSize)b",
                    script: [.stdout(chunk), .stdout(completion)],
                    frames: 16_384 / frameSize + 2,
                    iterations: frameSize <= 32 ? 30 : (frameSize <= 256 ? 100 : 200)
                )
            )
        }

        // A single frame exactly at the limit, with no LF anywhere in it: every 16 KiB chunk grows
        // the partial frame and re-searches it.
        let largeBody = Data(
            (#"{"method":""# + String(repeating: "A", count: maxFrameBytes - 13) + #""}"#).utf8
        )
        XCTAssertEqual(largeBody.count, maxFrameBytes)
        func sixteenKiBChunks(of data: Data) -> [Data] {
            var chunks: [Data] = []
            var index = data.startIndex
            while index < data.endIndex {
                let end = data.index(index, offsetBy: 16_384, limitedBy: data.endIndex) ?? data.endIndex
                chunks.append(data[index..<end])
                index = end
            }
            return chunks
        }
        workloads.append(
            RPCFramingWorkload(
                label: "large-partial-512kib",
                script: sixteenKiBChunks(of: largeBody).map { .stdout($0) }
                    + [.stdout(Data([0x0A]) + completion)],
                frames: 3,
                iterations: 8
            )
        )

        // The same frame with one byte too many: the last chunk pushes newline-less data past the
        // limit, which rejects the request without any LF ever arriving.
        workloads.append(
            RPCFramingWorkload(
                label: "over-limit-512kib",
                script: sixteenKiBChunks(of: largeBody).map { .stdout($0) } + [.stdout(Data([0x41]))],
                frames: 0,
                iterations: 8,
                expectedFailure: .codexIncompatible
            )
        )

        // The worst case the loop can see: the limit-sized partial frame, then one 16 KiB chunk that
        // carries its LF plus many tiny frames.
        var worstCaseTail = Data([0x0A])
        for _ in 0..<800 {
            worstCaseTail.append(notificationFrame(wireBytes: 19))
        }
        worstCaseTail.append(completion)
        workloads.append(
            RPCFramingWorkload(
                label: "worst-case-512kib-plus-tiny",
                script: sixteenKiBChunks(of: largeBody).map { .stdout($0) }
                    + [.stdout(worstCaseTail)],
                frames: 803,
                iterations: 8
            )
        )

        // One frame split into one-byte chunks, then one split into seven-byte chunks.
        var fragmentedScript: [BenchmarkRPCTransport.Emission] = initializeResponse.map { .stdout(Data([$0])) }
        for chunk in strideChunks(of: rateLimitsResponse, size: 7) {
            fragmentedScript.append(.stdout(chunk))
        }
        workloads.append(
            RPCFramingWorkload(
                label: "fragmented-1b-7b",
                script: fragmentedScript,
                frames: 2,
                iterations: 300
            )
        )

        // EOF delivering a frame that never got its LF.
        workloads.append(
            RPCFramingWorkload(
                label: "eof-no-newline",
                script: [.stdout(initializeResponse.dropLast()), .stdoutEOF, .stdout(rateLimitsResponse)],
                frames: 2,
                iterations: 300
            )
        )

        return workloads
    }

    private static func line(_ body: String) -> Data {
        Data(body.utf8) + Data([0x0A])
    }

    /// A notification frame whose wire size (body plus LF) is exactly `wireBytes`.
    private static func notificationFrame(wireBytes: Int) -> Data {
        let padding = wireBytes - 14
        XCTAssertGreaterThanOrEqual(padding, 1)
        return line(#"{"method":""# + String(repeating: "A", count: padding) + #""}"#)
    }

    private static func strideChunks(of data: Data, size: Int) -> [Data] {
        var chunks: [Data] = []
        var index = data.startIndex
        while index < data.endIndex {
            let end = data.index(index, offsetBy: size, limitedBy: data.endIndex) ?? data.endIndex
            chunks.append(data[index..<end])
            index = end
        }
        return chunks
    }

    private enum FramingLoopVariant {
        case baseline
        case hoisted
        case singleRemoval
    }

    private struct FramingLoopResult {
        let frames: Int
        let didFail: Bool
    }

    private static let lineFeedData = Data([0x0A])

    /// The three simplified framing models the benchmark pushes the scripts through, each with a
    /// frame counter standing in for the production line handler so the measurement is the buffer
    /// arithmetic alone. Stops exactly where the client resumes (after the frame that completes the
    /// request, or on the first frame that exceeds the limit).
    private static func framingLoop(
        _ script: [BenchmarkRPCTransport.Emission],
        maxFrameBytes: Int,
        stopAfterFrames: Int,
        variant: FramingLoopVariant
    ) -> FramingLoopResult {
        switch variant {
        case .baseline:
            return baselineFramingLoop(
                script,
                maxFrameBytes: maxFrameBytes,
                stopAfterFrames: stopAfterFrames
            )
        case .hoisted:
            return hoistedFramingLoop(
                script,
                maxFrameBytes: maxFrameBytes,
                stopAfterFrames: stopAfterFrames
            )
        case .singleRemoval:
            return singleRemovalFramingLoop(
                script,
                maxFrameBytes: maxFrameBytes,
                stopAfterFrames: stopAfterFrames
            )
        }
    }

    /// A simplified framing model of the pre-change loop, kept so the A/B ratio is reproducible in
    /// one process. It is not a verbatim copy of the production loop: the real line handler is
    /// replaced by a frame counter and both replicas inline that counting identically, so the only
    /// difference from `hoistedFramingLoop` is the LF search operand.
    private static func baselineFramingLoop(
        _ script: [BenchmarkRPCTransport.Emission],
        maxFrameBytes: Int,
        stopAfterFrames: Int
    ) -> FramingLoopResult {
        var stdoutBuffer = Data()
        var frames = 0
        for emission in script {
            switch emission {
            case .stdout(let chunk):
                stdoutBuffer.append(chunk)
                while let newlineRange = stdoutBuffer.range(of: Data("\n".utf8)) {
                    if newlineRange.lowerBound > maxFrameBytes {
                        return FramingLoopResult(frames: frames, didFail: true)
                    }
                    let lineData = stdoutBuffer.subdata(in: 0..<newlineRange.lowerBound)
                    stdoutBuffer.removeSubrange(0...newlineRange.lowerBound)
                    _ = lineData
                    frames += 1
                    if frames == stopAfterFrames {
                        return FramingLoopResult(frames: frames, didFail: false)
                    }
                }
                if stdoutBuffer.count > maxFrameBytes {
                    return FramingLoopResult(frames: frames, didFail: true)
                }
            case .stdoutEOF:
                guard !stdoutBuffer.isEmpty else { continue }
                let trailingLine = stdoutBuffer
                stdoutBuffer.removeAll(keepingCapacity: false)
                guard trailingLine.count <= maxFrameBytes else {
                    return FramingLoopResult(frames: frames, didFail: true)
                }
                _ = trailingLine
                frames += 1
                if frames == stopAfterFrames {
                    return FramingLoopResult(frames: frames, didFail: false)
                }
            }
        }
        return FramingLoopResult(frames: frames, didFail: false)
    }

    /// A simplified framing model of the shipped loop: structurally identical to
    /// `baselineFramingLoop` apart from the LF search operand, which is the hoisted `lineFeedData`
    /// constant instead of a freshly built `Data("\n".utf8)` per search.
    private static func hoistedFramingLoop(
        _ script: [BenchmarkRPCTransport.Emission],
        maxFrameBytes: Int,
        stopAfterFrames: Int
    ) -> FramingLoopResult {
        var stdoutBuffer = Data()
        var frames = 0
        for emission in script {
            switch emission {
            case .stdout(let chunk):
                stdoutBuffer.append(chunk)
                while let newlineRange = stdoutBuffer.range(of: lineFeedData) {
                    if newlineRange.lowerBound > maxFrameBytes {
                        return FramingLoopResult(frames: frames, didFail: true)
                    }
                    let lineData = stdoutBuffer.subdata(in: 0..<newlineRange.lowerBound)
                    stdoutBuffer.removeSubrange(0...newlineRange.lowerBound)
                    _ = lineData
                    frames += 1
                    if frames == stopAfterFrames {
                        return FramingLoopResult(frames: frames, didFail: false)
                    }
                }
                if stdoutBuffer.count > maxFrameBytes {
                    return FramingLoopResult(frames: frames, didFail: true)
                }
            case .stdoutEOF:
                guard !stdoutBuffer.isEmpty else { continue }
                let trailingLine = stdoutBuffer
                stdoutBuffer.removeAll(keepingCapacity: false)
                guard trailingLine.count <= maxFrameBytes else {
                    return FramingLoopResult(frames: frames, didFail: true)
                }
                _ = trailingLine
                frames += 1
                if frames == stopAfterFrames {
                    return FramingLoopResult(frames: frames, didFail: false)
                }
            }
        }
        return FramingLoopResult(frames: frames, didFail: false)
    }

    /// A simplified framing model of the single-removal rewrite this round considered: complete
    /// frames are consumed by advancing a read offset instead of removing the front of the buffer
    /// per frame, and the consumed prefix is compacted once per chunk, so the remaining bytes are
    /// moved at most once per chunk. Measured but not shipped.
    private static func singleRemovalFramingLoop(
        _ script: [BenchmarkRPCTransport.Emission],
        maxFrameBytes: Int,
        stopAfterFrames: Int
    ) -> FramingLoopResult {
        var stdoutBuffer = Data()
        var consumed = 0
        var frames = 0
        for emission in script {
            switch emission {
            case .stdout(let chunk):
                stdoutBuffer.append(chunk)
                while let newlineRange = stdoutBuffer.range(
                    of: lineFeedData,
                    in: consumed..<stdoutBuffer.count
                ) {
                    if newlineRange.lowerBound - consumed > maxFrameBytes {
                        return FramingLoopResult(frames: frames, didFail: true)
                    }
                    let lineData = stdoutBuffer.subdata(in: consumed..<newlineRange.lowerBound)
                    consumed = newlineRange.lowerBound + 1
                    _ = lineData
                    frames += 1
                    if frames == stopAfterFrames {
                        return FramingLoopResult(frames: frames, didFail: false)
                    }
                }
                // The candidate's single removal: drop the consumed prefix once per chunk.
                if consumed > 0 {
                    stdoutBuffer.removeSubrange(0..<consumed)
                    consumed = 0
                }
                if stdoutBuffer.count > maxFrameBytes {
                    return FramingLoopResult(frames: frames, didFail: true)
                }
            case .stdoutEOF:
                // Each chunk compacts on the way out, so `consumed` is always 0 here and this EOF
                // path matches the other two replicas' value-assignment form.
                guard !stdoutBuffer.isEmpty else { continue }
                let trailingLine = stdoutBuffer
                stdoutBuffer.removeAll(keepingCapacity: false)
                guard trailingLine.count <= maxFrameBytes else {
                    return FramingLoopResult(frames: frames, didFail: true)
                }
                _ = trailingLine
                frames += 1
                if frames == stopAfterFrames {
                    return FramingLoopResult(frames: frames, didFail: false)
                }
            }
        }
        return FramingLoopResult(frames: frames, didFail: false)
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

/// Replays the kinds and counts of JSON decodes this round removed from one
/// commit of an already-valid primary: the write readback's envelope validation
/// and payload decode (the readback now compares bytes against the buffer it just
/// encoded), plus the legacy-shape fallback of the newer-schema raw-snapshot
/// probe (which could only ever report schema version 1). The current commit runs
/// three decodes per iteration and the pre-round commit ran six, so timing this
/// replay alongside a current commit estimates the pre-round cost; it is not a
/// measured duration of the removed production path. Returns how many JSON
/// decodes it performed.
private func removedRoundDecodeCount(of data: Data) -> Int {
    let decoder = JSONDecoder()
    var decodes = 0

    func count<T: Decodable>(_ decode: () -> T?) -> T? {
        decodes += 1
        return decode()
    }

    // The write readback's `loadEnvelope`: envelope, then payload.
    if let envelope = count({ try? decoder.decode(PersistenceEnvelope.self, from: data) }) {
        _ = count { try? envelope.decode(PersistedAppState.self) }
    }

    // The probe's legacy-shape fallback.
    struct LegacyProbe: Decodable {
        let weeklyQuotaPercent: Int
        let fiveHourQuotaPercent: Int
        let refreshedAt: Date
    }
    _ = count { try? decoder.decode(LegacyProbe.self, from: data) }

    return decodes
}

/// One stdout script for the framing benchmark, together with the frame count the client consumes
/// before it resumes.
private struct RPCFramingWorkload {
    let label: String
    let script: [BenchmarkRPCTransport.Emission]
    let frames: Int
    let iterations: Int
    let expectedFailure: RealQuotaError?

    init(
        label: String,
        script: [BenchmarkRPCTransport.Emission],
        frames: Int,
        iterations: Int,
        expectedFailure: RealQuotaError? = nil
    ) {
        self.label = label
        self.script = script
        self.frames = frames
        self.iterations = iterations
        self.expectedFailure = expectedFailure
    }

    var bytes: Int {
        script.reduce(0) { total, emission in
            if case .stdout(let data) = emission { return total + data.count }
            return total
        }
    }

    var chunkCount: Int {
        script.reduce(0) { total, emission in
            if case .stdout = emission { return total + 1 }
            return total
        }
    }
}

/// Scripted stdout for the real `CodexRPCClient`.
///
/// The script is delivered by the client's own first request write, so the handlers are registered
/// before anything is emitted. The whole script is emitted at that first write, which is NOT how a
/// real pipe behaves: a response can arrive while its request is still being sent in the same write
/// (the realistic script's rate-limits response is emitted that way). The emissions are queued in
/// order, so chunk boundaries and frame order reach the framing loop exactly as the workload
/// declares them without involving any scheduling.
private final class BenchmarkRPCTransport: CodexRPCTransport, @unchecked Sendable {
    enum Emission {
        case stdout(Data)
        case stdoutEOF
    }

    private let lock = NSLock()
    private var script: [Emission]
    private var stdout: (@Sendable (Data) -> Void)?
    private var stdoutEOF: (@Sendable () -> Void)?
    private var stderr: (@Sendable (Data) -> Void)?
    private var termination: (@Sendable (Int32) -> Void)?
    private var writeCount = 0

    init(script: [Emission]) {
        self.script = script
    }

    func start(
        stdout: @escaping @Sendable (Data) -> Void,
        stdoutEOF: @escaping @Sendable () -> Void,
        stderr: @escaping @Sendable (Data) -> Void,
        termination: @escaping @Sendable (Int32) -> Void
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        self.stdout = stdout
        self.stdoutEOF = stdoutEOF
        self.stderr = stderr
        self.termination = termination
    }

    func write(_ data: Data) throws {
        _ = data
        lock.lock()
        writeCount += 1
        let pending = writeCount == 1 ? script : []
        if writeCount == 1 { script = [] }
        let stdout = self.stdout
        let stdoutEOF = self.stdoutEOF
        lock.unlock()
        for emission in pending {
            switch emission {
            case .stdout(let chunk): stdout?(chunk)
            case .stdoutEOF: stdoutEOF?()
            }
        }
    }

    func shutdownAndWait() throws {
        lock.lock()
        stdout = nil
        stdoutEOF = nil
        stderr = nil
        termination = nil
        lock.unlock()
    }
}

/// Never fires: the framing benchmark always feeds a completing script, so a timeout would only
/// hide a workload that cannot complete.
private final class BenchmarkTimeoutScheduler: CodexRPCTimeoutScheduling, @unchecked Sendable {
    func schedule(after _: Double, action _: @escaping @Sendable () -> Void) -> any CodexRPCCancellable {
        BenchmarkTimeoutToken()
    }
}

private final class BenchmarkTimeoutToken: CodexRPCCancellable, @unchecked Sendable {
    func cancel() {}
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
