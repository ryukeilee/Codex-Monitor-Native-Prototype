import Foundation

struct QuotaSnapshot: Codable, Equatable {
    let weeklyQuotaPercent: Int
    let fiveHourQuotaPercent: Int
    let refreshedAt: Date

    static let fallback = QuotaSnapshot(
        weeklyQuotaPercent: 72,
        fiveHourQuotaPercent: 69,
        refreshedAt: .now
    )
}
