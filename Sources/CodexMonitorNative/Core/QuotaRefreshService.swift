import Foundation

protocol QuotaRefreshing: Sendable {
    func refresh(basedOn currentSnapshot: QuotaSnapshot) async throws -> QuotaSnapshot
}

struct QuotaRefreshService: QuotaRefreshing {
    private let realProvider: RealQuotaProvider
    private let mockProvider: MockQuotaProvider

    init(realProvider: RealQuotaProvider = RealQuotaProvider(),
         mockProvider: MockQuotaProvider = MockQuotaProvider()) {
        self.realProvider = realProvider
        self.mockProvider = mockProvider
    }

    func refresh(basedOn currentSnapshot: QuotaSnapshot) async throws -> QuotaSnapshot {
        do {
            let realSnapshot = try await realProvider.fetchQuota()
            AppLogger.refresh.info("Real quota fetch succeeded")
            return realSnapshot
        } catch {
            AppLogger.refresh.error("Real quota fetch failed: \(error.localizedDescription, privacy: .public). Falling back to mock.")

            let mockSnapshot = try await mockProvider.fetchQuota(basedOn: currentSnapshot)
            return mockSnapshot
        }
    }
}
