import Foundation

enum QuotaRefreshStatus: String, Equatable, Sendable {
    case idle
    case refreshing
    case success
    case networkFailed
    case authRequired
    case parseFailed
    case noSnapshot
    case demoMode

    var displayName: String {
        switch self {
        case .idle:
            return "Idle"
        case .refreshing:
            return "Refreshing"
        case .success:
            return "Connected"
        case .networkFailed:
            return "Network Failed"
        case .authRequired:
            return "Auth Required"
        case .parseFailed:
            return "Parse Failed"
        case .noSnapshot:
            return "Not Connected"
        case .demoMode:
            return "Demo Mode"
        }
    }

    var isError: Bool {
        switch self {
        case .networkFailed, .authRequired, .parseFailed, .noSnapshot:
            return true
        case .idle, .refreshing, .success, .demoMode:
            return false
        }
    }
}
