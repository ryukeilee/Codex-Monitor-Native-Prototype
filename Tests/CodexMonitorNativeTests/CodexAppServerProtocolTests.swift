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

    /// The deviation family, pinned so the contract stays honest rather than aspirational.
    ///
    /// A float-syntax literal that needs more significant digits than a double carries is already
    /// rounded when `JSONSerialization` stores it, so the decoder reads the double image where the
    /// pre-change `JSONDecoder` pass converted the written digits. Those texts are ordinary
    /// shortest-round-trip output of f64 writers (`serde_json`, Ryu, Python `repr`), so the family
    /// is reachable in principle; it is bounded by magnitude, and
    /// `testShortestRoundTripTextsBelowTheDeviationBoundaryMatchTheLegacyConversion` plus the
    /// measurement in `docs/optimization-2026-10-11-rpc-parse.md` place the first observed
    /// divergence at 2^54, far above every number the quota path consumes or the real app-server
    /// emits. A floating-point number also never becomes `Int64.min`, whose double image is shared
    /// with out-of-range neighbours.
    func testDecodesNumbersBeyondDoublePrecisionAtDoublePrecision() throws {
        // `1.152921504606847e+18` denotes the digits 1152921504606847000; its double image is
        // 1152921504606846976.
        XCTAssertEqual(
            try decode(#"{"id":1,"result":1.152921504606847e+18}"#),
            .response(id: .integer(1), result: .integer(1152921504606846976))
        )
        // The same value written with a decimal point: `JSONSerialization` keeps the written
        // digits in its decimal storage, but the integer conversion reads the double image either
        // way, because that is the value the floating-point storage carries.
        XCTAssertEqual(
            try decode(#"{"id":1,"result":1152921504606847000.0}"#),
            .response(id: .integer(1), result: .integer(1152921504606846976))
        )
        XCTAssertEqual(
            try decode(#"{"id":1,"result":8.039664034419501e+17}"#),
            .response(id: .integer(1), result: .integer(803966403441950080))
        )
        // A fractional literal above 2^52 rounds to an integral double, and that double is what
        // the value tree carries. Ordinary fractions below it stay numbers.
        XCTAssertEqual(
            try decode(#"{"id":1,"result":9007199254740991.5}"#),
            .response(id: .integer(1), result: .integer(9007199254740992))
        )
        XCTAssertEqual(
            try decode(#"{"id":1,"result":1.5}"#),
            .response(id: .integer(1), result: .number(1.5))
        )
        XCTAssertEqual(
            try decode(#"{"id":1,"result":43.75}"#),
            .response(id: .integer(1), result: .number(43.75))
        )
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

    /// Pins how a large float-syntax number maps to a value and when it is rejected.
    ///
    /// The mapping reads the double image, so the accepted cases decode with the double's integer
    /// value and keep the pre-change decoder's classification. The two `-9223372036854775807.0`
    /// cases are the family-4 exception: the pre-change decoder accepted the written digits, while
    /// this decoder rejects them because the double image is exactly `Int64.min`, whose image is
    /// shared with out-of-range neighbours. `Int64.min` itself still arrives through integer
    /// storage, and the out-of-range and non-finite cases keep their pre-change classification.
    func testFloatSyntaxBoundaryNumbersPinValuesAndTheInt64MinRejection() throws {
        XCTAssertEqual(
            try decode(#"{"id":1152921504606847000.0,"result":null}"#),
            .response(id: .integer(1152921504606846976), result: .null)
        )
        XCTAssertEqual(
            try decode(#"{"id":1,"error":{"code":803966403441950100.0,"message":"m"}}"#),
            .error(
                id: .integer(1),
                error: CodexAppServerRemoteError(code: 803966403441950080, message: "m")
            )
        )
        assertViolation(.invalidID, line: #"{"id":-9223372036854775807.0,"result":null}"#)
        assertViolation(
            .malformedError,
            line: #"{"id":1,"error":{"code":-9223372036854775807.0,"message":"m"}}"#
        )
        assertViolation(.invalidID, line: #"{"id":-9223372036854775809.0,"result":null}"#)
        assertViolation(.invalidMessage, line: #"{"id":1,"result":-1e400}"#)
    }

    /// The deviation family is bounded by magnitude as well as by digits.
    ///
    /// For shortest-round-trip texts below 2^54 the decoded integer is exactly the value the
    /// pre-change `JSONDecoder` conversion produced, so the family cannot be reached by any of the
    /// magnitudes the quota path consumes (percentages, window durations, reset counts, epoch
    /// seconds) or by anything the real app-server was observed to emit.
    func testShortestRoundTripTextsBelowTheDeviationBoundaryMatchTheLegacyConversion() throws {
        var state: UInt64 = 0x2545_F491_4F6C_DD1D
        func nextRandom() -> UInt64 {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return state
        }

        var checked = 0
        for shift in 50...53 {
            let lower = UInt64(1) << UInt64(shift)
            for _ in 0..<500 {
                let text = "\(Double(lower + nextRandom() % lower))"
                guard let double = Double(text), double.rounded() == double else { continue }
                // The legacy conversion must really produce an `Int64` here, otherwise the
                // comparison below would fall back to `.number` and prove nothing.
                let legacy = try XCTUnwrap(
                    try? JSONDecoder().decode(Int64.self, from: Data(text.utf8)),
                    "the pre-change cascade stopped converting \(text) to Int64"
                )
                XCTAssertEqual(
                    try decode(#"{"id":1,"result":\#(text)}"#),
                    .response(id: .integer(1), result: .integer(legacy)),
                    "text: \(text)"
                )
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 1_900, "the sample loop should cover every binade")
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

    /// The representation difference for values beyond double precision lives inside the value
    /// tree; the quota reader consumes the same double either way, so the decision is unchanged
    /// even for an absurd duration.
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
