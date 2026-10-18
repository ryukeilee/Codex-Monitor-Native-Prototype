import Foundation
import XCTest
@testable import CodexMonitorNative

@MainActor
final class CodexAuthBoundaryPollerTests: XCTestCase {
    func testIdenticalBytesAreParsedOnce() throws {
        let bytes = makeAuthData(accountID: "account-a", subject: "user-a", sessionID: "session-a")
        var parseCount = 0
        let poller = CodexAuthBoundaryPoller(
            readData: { bytes },
            parse: { data in
                parseCount += 1
                return CodexAuthIdentityReader.parse(data: data)
            }
        )

        let first = poller.currentBoundary()
        let second = poller.currentBoundary()
        let third = poller.currentBoundary()

        XCTAssertNotNil(first)
        XCTAssertEqual(parseCount, 1)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first, third)
    }

    func testChangedBytesAreReparsedAndReportANewBoundary() throws {
        var bytes: Data? = makeAuthData(accountID: "account-a", subject: "user-a", sessionID: "session-a")
        var parseCount = 0
        let poller = CodexAuthBoundaryPoller(
            readData: { bytes },
            parse: { data in
                parseCount += 1
                return CodexAuthIdentityReader.parse(data: data)
            }
        )

        let original = try XCTUnwrap(poller.currentBoundary())
        XCTAssertEqual(poller.currentBoundary(), original)
        XCTAssertEqual(parseCount, 1)

        // 同一账号换会话：字节变，边界必须变，所以不允许任何按文件元数据的提前返回。
        bytes = makeAuthData(accountID: "account-a", subject: "user-a", sessionID: "session-b")
        let relogged = try XCTUnwrap(poller.currentBoundary())

        XCTAssertEqual(parseCount, 2)
        XCTAssertEqual(original.accountFingerprint, relogged.accountFingerprint)
        XCTAssertNotEqual(original.sessionFingerprint, relogged.sessionFingerprint)
    }

    func testUnreadableFileReturnsNilInsteadOfTheCachedBoundary() throws {
        var bytes: Data? = makeAuthData(accountID: "account-a", subject: "user-a", sessionID: "session-a")
        var parseCount = 0
        let poller = CodexAuthBoundaryPoller(
            readData: { bytes },
            parse: { data in
                parseCount += 1
                return CodexAuthIdentityReader.parse(data: data)
            }
        )

        XCTAssertNotNil(poller.currentBoundary())

        bytes = nil

        XCTAssertNil(poller.currentBoundary())
        XCTAssertNil(poller.currentBoundary())
        XCTAssertNil(poller.currentBoundary())
        XCTAssertEqual(parseCount, 1)
    }

    /// 真实转换是「用户登录」：`auth.json` 从不存到存在。首调用必须返回 nil 且不解析，
    /// 字节出现后必须立即返回有效边界并解析恰一次，此后同样字节命中、不再解析。
    func testUnreadableFileThatBecomesReadableIsParsedOnceAndThenMemoized() throws {
        let bytes = makeAuthData(accountID: "account-a", subject: "user-a", sessionID: "session-a")
        var currentData: Data?
        var parseCount = 0
        let poller = CodexAuthBoundaryPoller(
            readData: { currentData },
            parse: { data in
                parseCount += 1
                return CodexAuthIdentityReader.parse(data: data)
            }
        )

        XCTAssertNil(poller.currentBoundary())
        XCTAssertEqual(parseCount, 0)

        currentData = bytes
        let boundary = try XCTUnwrap(poller.currentBoundary())

        XCTAssertTrue(boundary.isValid)
        XCTAssertEqual(parseCount, 1)

        // 同一份字节再次轮询：命中，不再解析，也不改变结果。
        XCTAssertEqual(poller.currentBoundary(), boundary)
        XCTAssertEqual(parseCount, 1)
    }

    /// 畸形字节也是「未变化的字节」：第一次解析得到 nil，之后仍然返回 nil 且只解析一次。
    /// 不允许因为结果是 nil 就每次重试解析，也不允许因此退回任何缓存边界。
    func testMalformedBytesAreParsedOnceAndKeepReturningNil() {
        let bytes = Data("not-json".utf8)
        var parseCount = 0
        let poller = CodexAuthBoundaryPoller(
            readData: { bytes },
            parse: { data in
                parseCount += 1
                return CodexAuthIdentityReader.parse(data: data)
            }
        )

        XCTAssertNil(poller.currentBoundary())
        XCTAssertNil(poller.currentBoundary())
        XCTAssertNil(poller.currentBoundary())
        XCTAssertEqual(parseCount, 1)
    }

    /// 命中时也必须真实读取文件：这是等价性的前提，文件内容变了只有在每次读到时才能被发现。
    func testEveryCallReadsTheFileEvenWhenTheBytesAreUnchanged() {
        let bytes = makeAuthData(accountID: "account-a", subject: "user-a", sessionID: "session-a")
        var readCount = 0
        var parseCount = 0
        let poller = CodexAuthBoundaryPoller(
            readData: {
                readCount += 1
                return bytes
            },
            parse: { data in
                parseCount += 1
                return CodexAuthIdentityReader.parse(data: data)
            }
        )

        for _ in 0..<4 {
            XCTAssertNotNil(poller.currentBoundary())
        }

        XCTAssertEqual(readCount, 4)
        XCTAssertEqual(parseCount, 1)
    }

    func testRepeatedUnreadableReadsNeverParse() {
        var parseCount = 0
        let poller = CodexAuthBoundaryPoller(
            readData: { nil },
            parse: { _ in
                parseCount += 1
                return nil
            }
        )

        XCTAssertNil(poller.currentBoundary())
        XCTAssertNil(poller.currentBoundary())
        XCTAssertNil(poller.currentBoundary())
        XCTAssertEqual(parseCount, 0)
    }

    /// 与其他测试文件一样，这里刻意保留一份私有构造器而不共享类型：它只生成形状真实的
    /// auth JSON（内容全部是合成值），不涉及任何真实账号数据。
    private func makeAuthData(
        accountID: String?,
        subject: String,
        sessionID: String?
    ) -> Data {
        var claims: [String: Any] = ["sub": subject]
        if let sessionID {
            claims["sid"] = sessionID
        }
        let payload = try! JSONSerialization.data(withJSONObject: claims, options: [.sortedKeys])
        let syntheticJWT = "header.\(base64URL(payload)).signature"

        var tokens: [String: Any] = [
            "id_token": syntheticJWT,
            "refresh_token": "refresh-token"
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
