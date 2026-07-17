@testable import CodexMonitorNative

extension QuotaAccountBoundary {
    static let testDefault = test(account: "a", session: "b")
    static let testOtherAccount = test(account: "c", session: "d")
    static let testRelogin = test(account: "a", session: "e")

    static func test(account: String, session: String) -> QuotaAccountBoundary {
        QuotaAccountBoundary(
            accountFingerprint: String(repeating: account, count: 64),
            sessionFingerprint: String(repeating: session, count: 64)
        )
    }
}
