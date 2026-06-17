import Foundation

protocol QuotaRefreshing: Sendable {
    func refresh(basedOn currentSnapshot: QuotaSnapshot) async throws -> QuotaSnapshot
}

struct QuotaRefreshService: QuotaRefreshing {
    private let realProvider: RealQuotaProvider
    private let mockProvider: MockQuotaProvider
    private let forceMock: Bool

    init(realProvider: RealQuotaProvider = RealQuotaProvider(),
         mockProvider: MockQuotaProvider = MockQuotaProvider()) {
        self.realProvider = realProvider
        self.mockProvider = mockProvider
        self.forceMock = ProcessInfo.processInfo.environment["CODEX_MONITOR_FORCE_MOCK"] == "1"
    }

    func refresh(basedOn currentSnapshot: QuotaSnapshot) async throws -> QuotaSnapshot {
        if forceMock {
            AppLogger.refresh.info("CODEX_MONITOR_FORCE_MOCK=1; using mock data")
            let mockSnapshot = try await mockProvider.fetchQuota(basedOn: currentSnapshot)
            return mockSnapshot
        }

        // Try real data; do NOT fall back to mock on failure.
        // The caller (AppState) will classify the error and preserve
        // the last successful real snapshot.
        let realSnapshot = try await realProvider.fetchQuota()
        AppLogger.refresh.info("Real quota fetch succeeded")
        return realSnapshot
    }
}
