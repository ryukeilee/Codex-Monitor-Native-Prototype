import Foundation

struct QuotaSnapshot: Codable, Equatable {
    let weeklyQuotaPercent: Int
    let fiveHourQuotaPercent: Int
    let fiveHourResetAt: Date?
    let refreshedAt: Date
    let dataSource: QuotaDataSource
    let errorMessage: String?
    let schemaVersion: Int

    init(
        weeklyQuotaPercent: Int,
        fiveHourQuotaPercent: Int,
        fiveHourResetAt: Date? = nil,
        refreshedAt: Date,
        dataSource: QuotaDataSource,
        errorMessage: String? = nil,
        schemaVersion: Int = QuotaSnapshot.currentSchemaVersion
    ) {
        self.weeklyQuotaPercent = max(0, min(100, weeklyQuotaPercent))
        self.fiveHourQuotaPercent = max(0, min(100, fiveHourQuotaPercent))
        self.fiveHourResetAt = fiveHourResetAt
        self.refreshedAt = refreshedAt
        self.dataSource = dataSource
        self.errorMessage = errorMessage
        self.schemaVersion = schemaVersion
    }

    static let currentSchemaVersion = 3

    static let fallback = QuotaSnapshot(
        weeklyQuotaPercent: 0,
        fiveHourQuotaPercent: 0,
        fiveHourResetAt: nil,
        refreshedAt: .now,
        dataSource: .mock,
        errorMessage: nil
    )

    static let notConnected = QuotaSnapshot(
        weeklyQuotaPercent: 0,
        fiveHourQuotaPercent: 0,
        fiveHourResetAt: nil,
        refreshedAt: .now,
        dataSource: .mock,
        errorMessage: "Not connected to Codex"
    )
}
