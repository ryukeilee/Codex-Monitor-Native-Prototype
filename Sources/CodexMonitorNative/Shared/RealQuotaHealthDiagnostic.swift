import Foundation

struct RealQuotaHealthDiagnostic: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case waitingForFirstRequest
        case requestInProgress
        case requestSucceeded
        case executableMissing
        case executableNotRunnable
        case versionIncompatible
        case appServerStartFailed
        case codexUnavailable
        case requestTimedOut
        case loginRequired
        case responseInvalid
        case rpcRejected
    }

    let kind: Kind
    let isUsingCachedSnapshot: Bool
}
