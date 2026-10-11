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
}
