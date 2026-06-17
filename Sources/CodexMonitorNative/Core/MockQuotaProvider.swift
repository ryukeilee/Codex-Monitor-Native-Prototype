import Foundation

enum MockRefreshError: LocalizedError {
    case simulatedFailure

    var errorDescription: String? {
        "Simulated refresh failure"
    }
}

struct MockQuotaProvider {
    func fetchQuota(basedOn currentSnapshot: QuotaSnapshot) async throws -> QuotaSnapshot {
        try await Task.sleep(for: .seconds(1.2))

        let environment = ProcessInfo.processInfo.environment
        if environment["CODEX_MONITOR_FORCE_REFRESH_FAILURE"] == "1" {
            throw MockRefreshError.simulatedFailure
        }

        let shouldFail = environment["CODEX_MONITOR_FORCE_REFRESH_SUCCESS"] == "1"
            ? false
            : Int.random(in: 0..<5) == 0

        if shouldFail {
            throw MockRefreshError.simulatedFailure
        }

        let weeklyBaseline = max(0, min(100, currentSnapshot.weeklyQuotaPercent + Int.random(in: -3...2)))
        let fiveHourBaseline = max(0, min(100, currentSnapshot.fiveHourQuotaPercent + Int.random(in: -6...4)))

        return QuotaSnapshot(
            weeklyQuotaPercent: weeklyBaseline,
            fiveHourQuotaPercent: fiveHourBaseline,
            refreshedAt: .now,
            dataSource: .mock
        )
    }
}
