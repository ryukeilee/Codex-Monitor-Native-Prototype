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
        // Its digits round to 2^63, which no longer fits `Int64`; the pre-change decoder also
        // rejected it instead of accepting the double image.
        assertViolation(.invalidID, line: #"{"id":9223372036854775670.0,"result":null}"#)
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

    /// The codec reads the message from the object `JSONSerialization` produced, so the wire
    /// storage `JSONSerialization` chose decides the value type. This pins that mapping for every
    /// numeric kind, including booleans (which also report an integer `objCType`).
    func testDecodesWireNumberStorageIntoValueTypes() throws {
        let message = try decode(
            #"{"id":1,"result":{"int":1,"double":1.5,"exponent":1e2,"negativeZero":-0.0,"tiny":1e-320,"maxInt64":9223372036854775807,"aboveInt64":9223372036854775808,"uint64Overflow":18446744073709551615,"decimalOverflow":18446744073709551616,"yes":true,"no":false,"none":null}}"#
        )

        XCTAssertEqual(
            message,
            .response(id: .integer(1), result: .object([
                "int": .integer(1),
                "double": .number(1.5),
                "exponent": .integer(100),
                "negativeZero": .integer(0),
                "tiny": .number(1e-320),
                "maxInt64": .integer(.max),
                "aboveInt64": .number(9.223372036854776e18),
                "uint64Overflow": .number(1.8446744073709552e19),
                "decimalOverflow": .number(1.8446744073709552e19),
                "yes": .bool(true),
                "no": .bool(false),
                "none": .null
            ]))
        )
    }

    /// `JSONSerialization` keeps most decimal texts in a correctly rounded double: the numbers it
    /// stores as `NSDecimalNumber` are read back through their exact decimal text, which restores
    /// the written value the previous `JSONDecoder` pass produced. These are the cases the previous
    /// decoder also read exactly, including the smallest magnitudes where `doubleValue` alone is
    /// not correctly rounded.
    func testDecodesDecimalStoredNumbersAtTheirWrittenPrecision() throws {
        XCTAssertEqual(
            try decode(#"{"id":1,"result":1.49999999999999985}"#),
            .response(id: .integer(1), result: .number(1.4999999999999998))
        )
        XCTAssertEqual(
            try decode(#"{"id":1,"result":0.0077740401686756605}"#),
            .response(id: .integer(1), result: .number(0.0077740401686756605))
        )
        XCTAssertEqual(
            try decode(#"{"id":1,"result":0.0004929510820052052}"#),
            .response(id: .integer(1), result: .number(0.0004929510820052052))
        )
    }

    /// A decimal percentage is read at its written value, so the quota decision matches the
    /// pre-change decoder even below one percent.
    func testDecimalPercentagesKeepTheirWrittenDecision() throws {
        let line = #"{"id":2,"result":{"rateLimits":{"secondary":{"windowDurationMins":10080,"remainingPercent":1.49999999999999985}}}}"#
        let message = try decode(line)
        guard case .response(_, let result) = message,
              let object = result.foundationObject(),
              let snapshot = RealQuotaProvider.parseRateLimits(response: object) else {
            return XCTFail("expected a rate limit snapshot")
        }

        XCTAssertEqual(snapshot.weeklyQuotaPercent, 1)
        XCTAssertEqual(snapshot.weeklyQuotaState, .live)
    }

    /// A JSON integer written with more digits than a double can carry is already rounded when
    /// `JSONSerialization` stores it as a plain double, so the value keeps that double image where
    /// the previous `JSONDecoder` pass read the written digits. This is the one documented
    /// deviation family. A floating-point number also never becomes `Int64.min`, whose double image
    /// is shared with out-of-range neighbours.
    func testDecodesNumbersBeyondDoublePrecisionAtDoublePrecision() throws {
        XCTAssertEqual(
            try decode(#"{"id":1,"result":9007199254740993.0}"#),
            .response(id: .integer(1), result: .integer(9007199254740992))
        )
        XCTAssertEqual(
            try decode(#"{"id":9007199254740993.0,"result":{}}"#),
            .response(id: .integer(9007199254740992), result: .object([:]))
        )
        XCTAssertEqual(
            try decode(#"{"id":1,"result":1152921504606846976.0}"#),
            .response(id: .integer(1), result: .integer(1152921504606846976))
        )
        XCTAssertEqual(
            try decode(#"{"id":1,"result":-9223372036854775808.0}"#),
            .response(id: .integer(1), result: .number(-9.223372036854776e18))
        )
        XCTAssertEqual(
            try decode(#"{"id":1,"result":-9223372036854775809}"#),
            .response(id: .integer(1), result: .number(-9.223372036854776e18))
        )
        XCTAssertEqual(
            try decode(#"{"id":1,"result":-9223372036854775808}"#),
            .response(id: .integer(1), result: .integer(.min))
        )
    }

    /// A key that is present with JSON `null` is not a value, matching `decodeIfPresent`; only
    /// `result` keeps `.null` because the response role makes it the payload.
    func testTreatsNullOptionalPayloadsAsAbsent() throws {
        XCTAssertEqual(
            try decode(#"{"id":1,"error":{"code":1,"message":"m","data":null}}"#),
            .error(
                id: .integer(1),
                error: CodexAppServerRemoteError(code: 1, message: "m", data: nil)
            )
        )
        XCTAssertEqual(
            try decode(#"{"id":1,"method":"m","params":null}"#),
            .request(id: .integer(1), method: "m", params: nil)
        )
        XCTAssertEqual(
            try decode(#"{"method":"m","params":null}"#),
            .notification(method: "m", params: nil)
        )
    }

    /// `JSONSerialization` accepts `-1e400` as `-infinity` while `JSONDecoder` refused non-finite
    /// numbers; the rejection stays so a non-finite payload cannot enter the value tree.
    func testRejectsNonFiniteWireNumbers() {
        assertViolation(.invalidMessage, line: #"{"id":1,"result":-1e400}"#)
        assertViolation(.invalidMessage, line: #"{"id":1,"result":{"x":-1e400}}"#)
        assertViolation(.invalidMessage, line: #"{"id":1,"method":"m","params":-1e400}"#)
        assertViolation(.invalidMessage, line: #"{"id":1,"error":{"code":1,"message":"m","data":-1e400}}"#)
        assertViolation(.invalidID, line: #"{"id":-1e400,"result":{}}"#)
        assertViolation(.invalidJSON, line: #"{"id":1,"result":1e400}"#)
    }

    /// A frame is parsed once with `JSONSerialization`; the previous implementation parsed the
    /// same bytes a second time with `JSONDecoder`. The removed pass is structural, so this pins
    /// the shape the benchmark is built on: invalid frames and non-object top levels still fail
    /// before any message is built.
    func testRejectsFramesBeforeBuildingAnyMessage() {
        assertViolation(.invalidJSON, line: #"{"id":1,"result":}"#)
        assertViolation(.topLevelNotObject, line: #"[1,2,3]"#)
        assertViolation(.topLevelNotObject, line: #"5"#)
        assertViolation(.missingMessageRole, line: #"{}"#)
    }

    /// Counting fields read through `parseInteger` follow the same double-precision limit as any
    /// other number: a written count a double cannot carry is read through its double image, and
    /// two alias spellings of such a count no longer agree. Real reset-credit counts are small
    /// integers, and the aligned spellings still agree.
    func testExtremeCountingFieldsFollowTheirDoubleImage() throws {
        func resetCount(_ payload: String) throws -> Int? {
            let message = try decode(#"{"id":1,"result":\#(payload)}"#)
            guard case .response(_, let result) = message,
                  let object = result.foundationObject(),
                  let snapshot = RealQuotaProvider.parseRateLimits(response: object) else {
                return nil
            }
            return snapshot.resetAvailableCount
        }

        let window = #""rateLimits":{"primary":{"windowDurationMins":300,"usedPercent":10},"secondary":{"windowDurationMins":10080,"usedPercent":25}}"#
        XCTAssertEqual(
            try resetCount(#"{\#(window),"rateLimitResetCredits":{"availableCount":9007199254740993.0}}"#),
            9007199254740992
        )
        XCTAssertEqual(
            try resetCount(#"{\#(window),"rateLimitResetCredits":{"availableCount":9007199254740993,"available_count":9007199254740993.0}}"#),
            nil
        )
        XCTAssertEqual(
            try resetCount(#"{\#(window),"rateLimitResetCredits":{"availableCount":3,"available_count":3.0}}"#),
            3
        )
    }

    /// The only representation difference for values beyond double precision lives inside the
    /// value tree; the quota reader consumes the same double either way, so the decision is
    /// unchanged even for an absurd duration.
    func testExtremeWireNumbersDoNotChangeRateLimitDecisions() throws {
        let line = #"{"id":2,"result":{"rateLimitsByLimitId":{"codex":{"primary":{"windowDurationMins":9007199254740993.0,"usedPercent":10},"secondary":{"windowDurationMins":10080,"remainingPercent":50}}}}}"#
        let message = try decode(line)
        guard case .response(_, let result) = message,
              let object = result.foundationObject() else {
            return XCTFail("expected a response payload object")
        }

        let snapshot = try XCTUnwrap(RealQuotaProvider.parseRateLimits(response: object))

        XCTAssertEqual(snapshot.weeklyQuotaPercent, 50)
        XCTAssertEqual(snapshot.weeklyQuotaState, .live)
        XCTAssertEqual(snapshot.fiveHourQuotaState, .unavailable)
        XCTAssertEqual(snapshot.quotaWindows.map(\.id), ["codex.primary", "codex.secondary"])
        XCTAssertEqual(snapshot.quotaWindows.map(\.kind), [.unknown, .weekly])
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
