import Foundation

enum QuotaRefreshStatus: String, Equatable, Sendable {
    case normal
    case refreshing
    case failed
    case notConnected

    var displayName: String {
        switch self {
        case .normal:
            return "Normal"
        case .refreshing:
            return "Refreshing"
        case .failed:
            return "Refresh Failed"
        case .notConnected:
            return "Not Connected"
        }
    }
}
