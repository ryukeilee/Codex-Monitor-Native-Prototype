import Foundation

enum QuotaRefreshStatus: String, Codable, Equatable, Sendable {
    case idle
    case refreshing
    case success
    case stale
    case networkFailed
    case authRequired
    case parseFailed
    case noSnapshot
    case demoMode
}
