import Foundation

protocol QuotaRefreshing: Sendable {
    func refresh(basedOn currentSnapshot: QuotaSnapshot) async throws -> QuotaSnapshot
}

enum RefreshFailure: LocalizedError {
    case simulatedFailure

    var errorDescription: String? {
        switch self {
        case .simulatedFailure:
            return "Simulated refresh failure"
        }
    }
}

struct QuotaRefreshService: QuotaRefreshing {
    func refresh(basedOn currentSnapshot: QuotaSnapshot) async throws -> QuotaSnapshot {
        try await Task.sleep(for: .seconds(1.2))

        let environment = ProcessInfo.processInfo.environment
        if environment["CODEX_MONITOR_FORCE_REFRESH_FAILURE"] == "1" {
            throw RefreshFailure.simulatedFailure
        }

        let shouldFail = environment["CODEX_MONITOR_FORCE_REFRESH_SUCCESS"] == "1"
            ? false
            : Int.random(in: 0..<5) == 0

        if shouldFail {
            throw RefreshFailure.simulatedFailure
        }

        let weeklyBaseline = max(0, min(100, currentSnapshot.weeklyQuotaPercent + Int.random(in: -3...2)))
        let fiveHourBaseline = max(0, min(100, currentSnapshot.fiveHourQuotaPercent + Int.random(in: -6...4)))

        return QuotaSnapshot(
            weeklyQuotaPercent: weeklyBaseline,
            fiveHourQuotaPercent: fiveHourBaseline,
            refreshedAt: .now
        )
    }
}
