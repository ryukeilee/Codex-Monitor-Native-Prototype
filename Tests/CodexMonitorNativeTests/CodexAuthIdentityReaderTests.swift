import Foundation
import XCTest
@testable import CodexMonitorNative

final class CodexAuthIdentityReaderTests: XCTestCase {
    func testParseCreatesStableOpaqueBoundaryForSameAccountSession() throws {
        let first = try XCTUnwrap(CodexAuthIdentityReader.parse(data: makeAuthData(
            accountID: "account-secret-a",
            subject: "user-secret-a",
            sessionID: "session-secret-a",
            refreshToken: "refresh-secret-a"
        )))
        let rotated = try XCTUnwrap(CodexAuthIdentityReader.parse(data: makeAuthData(
            accountID: "account-secret-a",
            subject: "user-secret-a",
            sessionID: "session-secret-a",
            refreshToken: "refresh-secret-b"
        )))

        XCTAssertTrue(first.isValid)
        XCTAssertEqual(first, rotated)

        let encoded = try JSONEncoder().encode(first)
        let persistedText = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertFalse(persistedText.contains("account-secret-a"))
        XCTAssertFalse(persistedText.contains("user-secret-a"))
        XCTAssertFalse(persistedText.contains("session-secret-a"))
        XCTAssertFalse(persistedText.contains("refresh-secret"))
    }

    func testParseSeparatesAccountSwitchAndReloginBoundaries() throws {
        let original = try XCTUnwrap(CodexAuthIdentityReader.parse(data: makeAuthData(
            accountID: "account-a",
            subject: "user-a",
            sessionID: "session-a"
        )))
        let switchedAccount = try XCTUnwrap(CodexAuthIdentityReader.parse(data: makeAuthData(
            accountID: "account-b",
            subject: "user-b",
            sessionID: "session-b"
        )))
        let reloggedSameAccount = try XCTUnwrap(CodexAuthIdentityReader.parse(data: makeAuthData(
            accountID: "account-a",
            subject: "user-a",
            sessionID: "session-c"
        )))

        XCTAssertNotEqual(original.accountFingerprint, switchedAccount.accountFingerprint)
        XCTAssertNotEqual(original.sessionFingerprint, switchedAccount.sessionFingerprint)
        XCTAssertEqual(original.accountFingerprint, reloggedSameAccount.accountFingerprint)
        XCTAssertNotEqual(original.sessionFingerprint, reloggedSameAccount.sessionFingerprint)
        XCTAssertFalse(original.matches(switchedAccount))
        XCTAssertFalse(original.matches(reloggedSameAccount))
    }

    func testParseRejectsUnverifiableOrNonChatGPTAuth() throws {
        XCTAssertNil(CodexAuthIdentityReader.parse(data: Data(#"{"auth_mode":"apikey","tokens":{"account_id":"a","refresh_token":"r"}}"#.utf8)))
        XCTAssertNil(CodexAuthIdentityReader.parse(data: Data(#"{"auth_mode":"chatgpt","tokens":{"account_id":"a"}}"#.utf8)))
        XCTAssertNil(CodexAuthIdentityReader.parse(data: Data(#"{"auth_mode":"chatgpt","tokens":{"refresh_token":"r"}}"#.utf8)))
        XCTAssertNil(CodexAuthIdentityReader.parse(data: Data("not-json".utf8)))
    }

    func testParseFallsBackToJWTSubjectAndRefreshToken() throws {
        let boundary = try XCTUnwrap(CodexAuthIdentityReader.parse(data: makeAuthData(
            accountID: nil,
            subject: "user-a",
            sessionID: nil,
            refreshToken: "refresh-a"
        )))

        XCTAssertTrue(boundary.isValid)
    }

    func testCurrentBoundaryHonorsCodexHomeOverride() throws {
        let codexHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexMonitorNativeTests.authHome.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: codexHome) }
        try makeAuthData(
            accountID: "account-a",
            subject: "user-a",
            sessionID: "session-a"
        ).write(to: codexHome.appendingPathComponent("auth.json"), options: .atomic)

        let boundary = CodexAuthIdentityReader.currentBoundary(
            environment: ["CODEX_HOME": codexHome.path]
        )

        XCTAssertTrue(try XCTUnwrap(boundary).isValid)
    }

    private func makeAuthData(
        accountID: String?,
        subject: String,
        sessionID: String?,
        refreshToken: String = "refresh-token"
    ) -> Data {
        var claims: [String: Any] = ["sub": subject]
        if let sessionID {
            claims["sid"] = sessionID
        }
        let payload = try! JSONSerialization.data(withJSONObject: claims, options: [.sortedKeys])
        let syntheticJWT = "header.\(base64URL(payload)).signature"

        var tokens: [String: Any] = [
            "id_token": syntheticJWT,
            "refresh_token": refreshToken
        ]
        if let accountID {
            tokens["account_id"] = accountID
        }
        return try! JSONSerialization.data(withJSONObject: [
            "auth_mode": "chatgpt",
            "tokens": tokens
        ], options: [.sortedKeys])
    }

    private func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
