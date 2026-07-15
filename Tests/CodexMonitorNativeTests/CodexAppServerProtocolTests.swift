import Foundation
import XCTest
@testable import CodexMonitorNative

final class CodexAppServerProtocolTests: XCTestCase {
    func testDecodesResponseWithIntegerIDAndNullResult() throws {
        let message = try decode(#"{"id":42,"result":null}"#)

        XCTAssertEqual(message, .response(id: .integer(42), result: .null))
    }

    func testDecodesResponseWithStringIDAndAdditionalFields() throws {
        let message = try decode(#"{"id":"request-1","result":{"ok":true},"trace":"ignored"}"#)

        XCTAssertEqual(
            message,
            .response(id: .string("request-1"), result: .object(["ok": .bool(true)]))
        )
    }

    func testDecodesErrorMessage() throws {
        let message = try decode(#"{"id":7,"error":{"code":-32001,"message":"Denied","data":{"reason":"auth"}}}"#)

        XCTAssertEqual(
            message,
            .error(
                id: .integer(7),
                error: CodexAppServerRemoteError(
                    code: -32_001,
                    message: "Denied",
                    data: .object(["reason": .string("auth")])
                )
            )
        )
    }

    func testDecodesRequestAndNotification() throws {
        XCTAssertEqual(
            try decode(#"{"id":"a","method":"initialize","params":{"capability":1}}"#),
            .request(
                id: .string("a"),
                method: "initialize",
                params: .object(["capability": .integer(1)])
            )
        )
        XCTAssertEqual(
            try decode(#"{"method":"initialized","params":[true,2.5,null]}"#),
            .notification(
                method: "initialized",
                params: .array([.bool(true), .number(2.5), .null])
            )
        )
    }

    func testRejectsInvalidOrMissingIDs() {
        assertViolation(.missingID, line: #"{"result":{}}"#)
        assertViolation(.invalidID, line: #"{"id":1.5,"result":{}}"#)
        assertViolation(.invalidID, line: #"{"id":true,"result":{}}"#)
    }

    func testRejectsMalformedErrors() {
        assertViolation(.malformedError, line: #"{"id":1,"error":{"message":"no code"}}"#)
        assertViolation(.malformedError, line: #"{"id":1,"error":{"code":1}}"#)
    }

    func testRejectsMixedRolesAndMessagesWithoutRoles() {
        assertViolation(.mixedMessageRoles, line: #"{"id":1,"result":{},"error":{"code":1,"message":"x"}}"#)
        assertViolation(.mixedMessageRoles, line: #"{"id":1,"method":"x","result":{}}"#)
        assertViolation(.missingMessageRole, line: #"{"id":1,"extra":true}"#)
    }

    func testRejectsNonObjectAndInvalidJSON() {
        assertViolation(.topLevelNotObject, line: #"[1,2,3]"#)
        assertViolation(.invalidJSON, line: #"{"id":1,"result":}"#)
        XCTAssertThrowsError(try CodexAppServerCodec.decodeLine(Data([0xFF]))) { error in
            XCTAssertEqual(error as? CodexAppServerProtocolViolation, .invalidJSON)
        }
    }

    func testEncodesRequestWithoutJSONRPCHeaderOrNewline() throws {
        let data = try CodexAppServerCodec.encodeRequest(
            id: .integer(3),
            method: "account/rateLimits/read",
            params: .object(["verbose": .bool(true)])
        )

        XCTAssertFalse(data.contains(0x0A))
        let object = try jsonObject(from: data)
        XCTAssertEqual(object["id"] as? Int, 3)
        XCTAssertEqual(object["method"] as? String, "account/rateLimits/read")
        XCTAssertNil(object["jsonrpc"])
        XCTAssertEqual((object["params"] as? [String: Any])?["verbose"] as? Bool, true)
    }

    func testEncodesNotificationWithoutID() throws {
        let data = try CodexAppServerCodec.encodeNotification(method: "initialized")

        let object = try jsonObject(from: data)
        XCTAssertEqual(object["method"] as? String, "initialized")
        XCTAssertNil(object["id"])
        XCTAssertNil(object["params"])
    }

    func testEncodesErrorResponse() throws {
        let data = try CodexAppServerCodec.encodeErrorResponse(
            id: .string("request-7"),
            error: CodexAppServerRemoteError(code: 123, message: "Failed", data: .null)
        )

        let object = try jsonObject(from: data)
        XCTAssertEqual(object["id"] as? String, "request-7")
        let error = try XCTUnwrap(object["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, 123)
        XCTAssertEqual(error["message"] as? String, "Failed")
        XCTAssertTrue(error["data"] is NSNull)
    }

    private func decode(_ line: String) throws -> CodexAppServerMessage {
        try CodexAppServerCodec.decodeLine(Data(line.utf8))
    }

    private func assertViolation(
        _ expected: CodexAppServerProtocolViolation,
        line: String,
        file: StaticString = #filePath,
        lineNumber: UInt = #line
    ) {
        XCTAssertThrowsError(try decode(line), file: file, line: lineNumber) { error in
            XCTAssertEqual(error as? CodexAppServerProtocolViolation, expected, file: file, line: lineNumber)
        }
    }

    private func jsonObject(from data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
