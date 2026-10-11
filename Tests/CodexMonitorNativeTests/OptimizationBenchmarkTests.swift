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
