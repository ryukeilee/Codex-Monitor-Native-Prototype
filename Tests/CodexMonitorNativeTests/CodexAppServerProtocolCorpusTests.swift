import Foundation
import XCTest
@testable import CodexMonitorNative

/// Golden wire outcomes for one newline-delimited protocol frame.
///
/// Every expectation was produced by running this same canonical dump through the pre-change
/// decoder (`git archive` of the commit before this change), so the table pins wire compatibility
/// rather than the current implementation, and it passes on both trees. The five live captures at
/// the end were sanitized from a real `codex-cli 0.162.1` `app-server` session. The deviation
/// families that differ (float-syntax literals whose decimal integer differs from the double's
/// exact integer, observed only from magnitude 2^54 upward, plus the hand-crafted and fractional
/// texts listed in the doc) are pinned by
/// `CodexAppServerProtocolTests.testDecodesNumbersBeyondDoublePrecisionAtDoublePrecision`,
/// `testShortestRoundTripTextsBelowTheDeviationBoundaryMatchTheLegacyConversion`, and
/// `testFloatSyntaxBoundaryNumbersPinValuesAndTheInt64MinRejection`, and measured in
/// `docs/optimization-2026-10-11-rpc-parse.md`.
final class CodexAppServerProtocolCorpusTests: XCTestCase {
    func testFrameOutcomesMatchRecordedWireBehaviour() {
        for entry in Self.frames {
            let outcome: String
            do {
                outcome = Self.dump(try CodexAppServerCodec.decodeLine(Data(entry.line.utf8)))
            } catch let violation as CodexAppServerProtocolViolation {
                outcome = "violation:\(violation)"
            } catch {
                return XCTFail("unexpected error \(error) for \(entry.line)")
            }
            XCTAssertEqual(outcome, entry.outcome, "line: \(entry.line)")
        }
    }

    private static func dump(_ message: CodexAppServerMessage) -> String {
        switch message {
        case .response(let id, let result):
            return "message:response(id:\(dump(id)),result:\(dump(result)))"
        case .error(let id, let error):
            return "message:error(id:\(dump(id)),code:\(error.code),message:\(error.message),"
                + "data:\(error.data.map(dump) ?? "<absent>"))"
        case .request(let id, let method, let params):
            return "message:request(id:\(dump(id)),method:\(method),"
                + "params:\(params.map(dump) ?? "<absent>"))"
        case .notification(let method, let params):
            return "message:notification(method:\(method),params:\(params.map(dump) ?? "<absent>"))"
        }
    }

    private static func dump(_ id: CodexAppServerRequestID) -> String {
        switch id {
        case .integer(let value): return "int(\(value))"
        case .string(let value): return "str(\(value))"
        }
    }

    private static func dump(_ value: CodexAppServerJSONValue) -> String {
        switch value {
        case .object(let object):
            let body = object.keys.sorted().map { "\($0):\(dump(object[$0]!))" }.joined(separator: ",")
            return "{\(body)}"
        case .array(let array):
            return "[\(array.map(dump).joined(separator: ","))]"
        case .string(let string):
            return "str(\(string))"
        case .integer(let integer):
            return "int(\(integer))"
        case .number(let number):
            return "num(\(number))"
        case .bool(let bool):
            return "bool(\(bool))"
        case .null:
            return "null"
        }
    }

    private static let frames: [(line: String, outcome: String)] = [
        (#"{"id":42,"result":null}"#, "message:response(id:int(42),result:null)"),
        (#"{"id":"request-1","result":{"ok":true},"trace":"ignored"}"#, "message:response(id:str(request-1),result:{ok:bool(true)})"),
        (#"{"id":7,"error":{"code":-32001,"message":"Denied","data":{"reason":"auth"}}}"#, "message:error(id:int(7),code:-32001,message:Denied,data:{reason:str(auth)})"),
        (#"{"id":1,"error":{"code":1,"message":"m"}}"#, "message:error(id:int(1),code:1,message:m,data:<absent>)"),
        (#"{"id":1,"error":{"code":1,"message":"m","data":null}}"#, "message:error(id:int(1),code:1,message:m,data:<absent>)"),
        (#"{"id":"a","method":"initialize","params":{"capability":1}}"#, "message:request(id:str(a),method:initialize,params:{capability:int(1)})"),
        (#"{"method":"initialized","params":[true,2.5,null]}"#, "message:notification(method:initialized,params:[bool(true),num(2.5),null])"),
        (#"{"method":"initialized"}"#, "message:notification(method:initialized,params:<absent>)"),
        (#"{"id":1,"result":{"rateLimits":{"primary":{"usedPercent":12.5}}}}"#, "message:response(id:int(1),result:{rateLimits:{primary:{usedPercent:num(12.5)}}})"),
        (#"{"id":1,"notification":true,"result":{}}"#, "message:response(id:int(1),result:{})"),
        (#"{"id":1,"result":}"#, "violation:invalidJSON"),
        (#"{"id":1,"result":{} }"#, "message:response(id:int(1),result:{})"),
        (#"tail {"id":1,"result":{}}"#, "violation:invalidJSON"),
        (#"[1,2,3]"#, "violation:topLevelNotObject"),
        (#""x""#, "violation:topLevelNotObject"),
        (#"5"#, "violation:topLevelNotObject"),
        (#"true"#, "violation:topLevelNotObject"),
        (#"null"#, "violation:topLevelNotObject"),
        (#"{"id":1,"result":{},"error":{"code":1,"message":"x"}}"#, "violation:mixedMessageRoles"),
        (#"{"id":1,"method":"x","result":{}}"#, "violation:mixedMessageRoles"),
        (#"{"id":1,"method":"x","error":{"code":1,"message":"x"}}"#, "violation:mixedMessageRoles"),
        (#"{"id":1,"extra":true}"#, "violation:missingMessageRole"),
        (#"{"result":{}}"#, "violation:missingID"),
        (#"{"error":{"code":1,"message":"m"}}"#, "violation:missingID"),
        (#"{"method":7,"params":{}}"#, "violation:invalidMessage"),
        (#"{"method":null}"#, "violation:invalidMessage"),
        (#"{"id":1.5,"result":{}}"#, "violation:invalidID"),
        (#"{"id":true,"result":{}}"#, "violation:invalidID"),
        (#"{"id":false,"result":{}}"#, "violation:invalidID"),
        (#"{"id":null,"result":{}}"#, "violation:invalidID"),
        (#"{"id":[1],"result":{}}"#, "violation:invalidID"),
        (#"{"id":{},"result":{}}"#, "violation:invalidID"),
        (#"{"id":"42","result":{}}"#, "message:response(id:str(42),result:{})"),
        (#"{"id":1.0,"result":{}}"#, "message:response(id:int(1),result:{})"),
        (#"{"id":-0.0,"result":{}}"#, "message:response(id:int(0),result:{})"),
        (#"{"id":1e2,"result":{}}"#, "message:response(id:int(100),result:{})"),
        (#"{"id":9223372036854775807,"result":{}}"#, "message:response(id:int(9223372036854775807),result:{})"),
        (#"{"id":9223372036854775808,"result":{}}"#, "violation:invalidID"),
        (#"{"id":18446744073709551615,"result":{}}"#, "violation:invalidID"),
        (#"{"id":18446744073709551616,"result":{}}"#, "violation:invalidID"),
        (#"{"id":-1e400,"result":{}}"#, "violation:invalidID"),
        (#"{"id":1,"notification":1}"#, "violation:missingMessageRole"),
        (#"{"id":1,"error":{"message":"no code"}}"#, "violation:malformedError"),
        (#"{"id":1,"error":{"code":1}}"#, "violation:malformedError"),
        (#"{"id":1,"error":"x"}"#, "violation:malformedError"),
        (#"{"id":1,"error":[1]}"#, "violation:malformedError"),
        (#"{"id":1,"error":null}"#, "violation:malformedError"),
        (#"{"id":1,"error":{"code":"1","message":"m"}}"#, "violation:malformedError"),
        (#"{"id":1,"error":{"code":1.5,"message":"m"}}"#, "violation:malformedError"),
        (#"{"id":1,"error":{"code":1.0,"message":"m"}}"#, "message:error(id:int(1),code:1,message:m,data:<absent>)"),
        (#"{"id":1,"error":{"code":true,"message":"m"}}"#, "violation:malformedError"),
        (#"{"id":1,"error":{"code":null,"message":"m"}}"#, "violation:malformedError"),
        (#"{"id":1,"error":{"code":18446744073709551615,"message":"m"}}"#, "violation:malformedError"),
        (#"{"id":1,"error":{"code":1,"message":7}}"#, "violation:malformedError"),
        (#"{"id":1,"error":{"code":1,"message":"m","data":-1e400}}"#, "violation:invalidMessage"),
        (#"{"id":1,"error":{"code":1,"message":"m","data":{"deep":[{"a":1}]}}}"#, "message:error(id:int(1),code:1,message:m,data:{deep:[{a:int(1)}]})"),
        (#"{"id":1,"result":1}"#, "message:response(id:int(1),result:int(1))"),
        (#"{"id":1,"result":1.0}"#, "message:response(id:int(1),result:int(1))"),
        (#"{"id":1,"result":1e2}"#, "message:response(id:int(1),result:int(100))"),
        (#"{"id":1,"result":-0.0}"#, "message:response(id:int(1),result:int(0))"),
        (#"{"id":1,"result":1.5}"#, "message:response(id:int(1),result:num(1.5))"),
        (#"{"id":1,"result":1e-320}"#, "message:response(id:int(1),result:num(1e-320))"),
        (#"{"id":1,"result":9223372036854775807}"#, "message:response(id:int(1),result:int(9223372036854775807))"),
        (#"{"id":1,"result":9223372036854775808}"#, "message:response(id:int(1),result:num(9.223372036854776e+18))"),
        (#"{"id":1,"result":18446744073709551615}"#, "message:response(id:int(1),result:num(1.8446744073709552e+19))"),
        (#"{"id":1,"result":18446744073709551616}"#, "message:response(id:int(1),result:num(1.8446744073709552e+19))"),
        (#"{"id":1,"result":3.141592653589793238462643383279}"#, "message:response(id:int(1),result:num(3.141592653589793))"),
        (#"{"id":1,"result":1e400}"#, "violation:invalidJSON"),
        (#"{"id":1,"result":-1e400}"#, "violation:invalidMessage"),
        (#"{"id":1,"result":true}"#, "message:response(id:int(1),result:bool(true))"),
        (#"{"id":1,"result":false}"#, "message:response(id:int(1),result:bool(false))"),
        (#"{"id":1,"result":{}}"#, "message:response(id:int(1),result:{})"),
        (#"{"id":1,"result":[]}"#, "message:response(id:int(1),result:[])"),
        (#"{"id":1,"result":{"a":1,"b":1.0,"c":true,"d":null,"e":[1,"x"],"f":{"g":-2.5}}}"#, "message:response(id:int(1),result:{a:int(1),b:int(1),c:bool(true),d:null,e:[int(1),str(x)],f:{g:num(-2.5)}})"),
        (#"{"id":1,"result":"\u00e9\u0041\/ text"}"#, "message:response(id:int(1),result:str(éA/ text))"),
        (#"{"id":1,"result":"line\nbreak\ttab"}"#, "message:response(id:int(1),result:str(line\nbreak\ttab))"),
        (#"{"id":1,"method":"m","params":1.0}"#, "message:request(id:int(1),method:m,params:int(1))"),
        (#"{"id":1,"method":"m","params":18446744073709551616}"#, "message:request(id:int(1),method:m,params:num(1.8446744073709552e+19))"),
        (#"{"id":1,"method":"m","params":-1e400}"#, "violation:invalidMessage"),
        (#"{"id":1,"method":"m","params":null}"#, "message:request(id:int(1),method:m,params:<absent>)"),
        (#"{"method":"m","params":[{"nested":[true,false,null]}]}"#, "message:notification(method:m,params:[{nested:[bool(true),bool(false),null]}])"),
        (#"{"id":1,"result":1152921504606846976.0}"#, "message:response(id:int(1),result:int(1152921504606846976))"),
        (#"{"id":1,"result":1152921504606846976}"#, "message:response(id:int(1),result:int(1152921504606846976))"),
        (#"{"id":1,"result":-9223372036854775808.0}"#, "message:response(id:int(1),result:num(-9.223372036854776e+18))"),
        (#"{"id":1,"result":-9223372036854776832}"#, "message:response(id:int(1),result:num(-9.223372036854776e+18))"),
        (#"{"id":1,"result":-9.223372036854776e18}"#, "message:response(id:int(1),result:num(-9.223372036854776e+18))"),
        (#"{"id":1,"result":4503599627370496.0}"#, "message:response(id:int(1),result:int(4503599627370496))"),
        (#"{"id":1,"result":-4503599627370497.0}"#, "message:response(id:int(1),result:int(-4503599627370497))"),
        (#"{"id":1,"result":9007199254740994.0}"#, "message:response(id:int(1),result:int(9007199254740994))"),
        (#"{"id":1,"result":9007199254740992}"#, "message:response(id:int(1),result:int(9007199254740992))"),
        (#"{"id":1,"result":9007199254740992.0}"#, "message:response(id:int(1),result:int(9007199254740992))"),
        (#"{"id":1,"result":9007199254740993}"#, "message:response(id:int(1),result:int(9007199254740993))"),
        (#"{"id":1,"result":10000000000000000000}"#, "message:response(id:int(1),result:num(1e+19))"),
        (#"{"id":1,"result":1e19}"#, "message:response(id:int(1),result:num(1e+19))"),
        (#"{"id":1,"result":-9223372036854775808}"#, "message:response(id:int(1),result:int(-9223372036854775808))"),
        (#"{"id":1,"result":-9223372036854775809}"#, "message:response(id:int(1),result:num(-9.223372036854776e+18))"),
        (#"{"id":1,"result":-9223372036854775809.0}"#, "message:response(id:int(1),result:num(-9.223372036854776e+18))"),
        (#"{"id":1,"result":-9223372036854776320}"#, "message:response(id:int(1),result:num(-9.223372036854776e+18))"),
        (#"{"id":1,"result":9223372036854775806}"#, "message:response(id:int(1),result:int(9223372036854775806))"),
        (#"{"id":1,"result":9223372036854775807.0}"#, "message:response(id:int(1),result:num(9.223372036854776e+18))"),
        (#"{"id":1,"result":0.30000000000000004}"#, "message:response(id:int(1),result:num(0.30000000000000004))"),
        (#"{"id":1,"result":5e-324}"#, "message:response(id:int(1),result:num(5e-324))"),
        (#"{"id":1,"result":1.7976931348623157e308}"#, "message:response(id:int(1),result:num(1.7976931348623157e+308))"),
        (#"{"id":1,"result":1e309}"#, "violation:invalidJSON"),
        (#"{"id":1,"result":{"x":-1e400}}"#, "violation:invalidMessage"),
        (#"{"id":null,"method":"x","params":-1e400}"#, "violation:invalidMessage"),
        (#"{"id":9223372036854775670.0,"result":null}"#, "violation:invalidID"),
        (#"{"id":1152921504606846976.0,"result":null}"#, "message:response(id:int(1152921504606846976),result:null)"),
        (#"{"id":9223372036854774784.0,"result":null}"#, "message:response(id:int(9223372036854774784),result:null)"),
        (#"{"id":1,"result":1.49999999999999985}"#, "message:response(id:int(1),result:num(1.4999999999999998))"),
        (#"{"id":1,"result":2.4999999999999996}"#, "message:response(id:int(1),result:num(2.4999999999999996))"),
        // Sanitized captures from a live `codex-cli 0.162.1` `app-server` session
        // (real frame shapes, account and installation identifiers replaced). They pin the
        // envelope fields the model ignores (`emittedAtMs` beside `method`/`params`), the
        // handshake payload, the real quota schema, and a real `-32600` rejection.
        (#"{"id":1,"result":{"userAgent":"codex-monitor-native/0.162.1 (Mac OS 27.0.1; arm64) unknown (codex-monitor-native; 0.2.0)","codexHome":"/Users/example/.codex","platformFamily":"unix","platformOs":"macos"}}"#, "message:response(id:int(1),result:{codexHome:str(/Users/example/.codex),platformFamily:str(unix),platformOs:str(macos),userAgent:str(codex-monitor-native/0.162.1 (Mac OS 27.0.1; arm64) unknown (codex-monitor-native; 0.2.0))})"),
        (#"{"method":"remoteControl/status/changed","params":{"status":"disabled","serverName":"example.local","installationId":"00000000-0000-0000-0000-000000000000","environmentId":null},"emittedAtMs":1791715296696}"#, "message:notification(method:remoteControl/status/changed,params:{environmentId:null,installationId:str(00000000-0000-0000-0000-000000000000),serverName:str(example.local),status:str(disabled)})"),
        (#"{"method":"account/updated","params":{"authMode":"chatgpt","planType":"plus"},"emittedAtMs":1791715297765}"#, "message:notification(method:account/updated,params:{authMode:str(chatgpt),planType:str(plus)})"),
        (#"{"id":2,"result":{"ordinaryUsageAllowed":true,"rateLimits":{"limitId":"codex","limitName":null,"normalModelSlug":null,"primary":{"usedPercent":36,"windowDurationMins":300,"resetsAt":1791715803},"secondary":{"usedPercent":6,"windowDurationMins":10080,"resetsAt":1792302603},"credits":{"hasCredits":false,"unlimited":false,"balance":"0"},"individualLimit":null,"spendControlReached":false,"planType":"plus","rateLimitReachedType":null},"rateLimitsByLimitId":{"codex":{"limitId":"codex","limitName":null,"normalModelSlug":null,"primary":{"usedPercent":36,"windowDurationMins":300,"resetsAt":1791715803},"secondary":{"usedPercent":6,"windowDurationMins":10080,"resetsAt":1792302603},"credits":{"hasCredits":false,"unlimited":false,"balance":"0"},"individualLimit":null,"spendControlReached":false,"planType":"plus","rateLimitReachedType":null}},"rateLimitResetCredits":{"availableCount":3,"credits":[{"id":"RateLimitResetCredit_00000000000000000000000000000001","resetType":"codexRateLimits","status":"available","grantedAt":1790107270,"expiresAt":1792699270,"title":"Full reset (Weekly + 5 hr)","description":"Thanks for using Codex! You've been granted one free rate limit reset."},{"id":"RateLimitResetCredit_00000000000000000000000000000002","resetType":"codexRateLimits","status":"available","grantedAt":1790701617,"expiresAt":1793293617,"title":"Full reset (Weekly + 5 hr)","description":"Thanks for using Codex! You've been granted one free rate limit reset."},{"id":"RateLimitResetCredit_00000000000000000000000000000003","resetType":"codexRateLimits","status":"available","grantedAt":1791410478,"expiresAt":1794002478,"title":"Full reset (Weekly + 5 hr)","description":"Thanks for using Codex! You've been granted one free rate limit reset."}]},"accountId":"00000000-0000-0000-0000-000000000000","rateLimitUpsell":null}}"#, "message:response(id:int(2),result:{accountId:str(00000000-0000-0000-0000-000000000000),ordinaryUsageAllowed:bool(true),rateLimitResetCredits:{availableCount:int(3),credits:[{description:str(Thanks for using Codex! You've been granted one free rate limit reset.),expiresAt:int(1792699270),grantedAt:int(1790107270),id:str(RateLimitResetCredit_00000000000000000000000000000001),resetType:str(codexRateLimits),status:str(available),title:str(Full reset (Weekly + 5 hr))},{description:str(Thanks for using Codex! You've been granted one free rate limit reset.),expiresAt:int(1793293617),grantedAt:int(1790701617),id:str(RateLimitResetCredit_00000000000000000000000000000002),resetType:str(codexRateLimits),status:str(available),title:str(Full reset (Weekly + 5 hr))},{description:str(Thanks for using Codex! You've been granted one free rate limit reset.),expiresAt:int(1794002478),grantedAt:int(1791410478),id:str(RateLimitResetCredit_00000000000000000000000000000003),resetType:str(codexRateLimits),status:str(available),title:str(Full reset (Weekly + 5 hr))}]},rateLimitUpsell:null,rateLimits:{credits:{balance:str(0),hasCredits:bool(false),unlimited:bool(false)},individualLimit:null,limitId:str(codex),limitName:null,normalModelSlug:null,planType:str(plus),primary:{resetsAt:int(1791715803),usedPercent:int(36),windowDurationMins:int(300)},rateLimitReachedType:null,secondary:{resetsAt:int(1792302603),usedPercent:int(6),windowDurationMins:int(10080)},spendControlReached:bool(false)},rateLimitsByLimitId:{codex:{credits:{balance:str(0),hasCredits:bool(false),unlimited:bool(false)},individualLimit:null,limitId:str(codex),limitName:null,normalModelSlug:null,planType:str(plus),primary:{resetsAt:int(1791715803),usedPercent:int(36),windowDurationMins:int(300)},rateLimitReachedType:null,secondary:{resetsAt:int(1792302603),usedPercent:int(6),windowDurationMins:int(10080)},spendControlReached:bool(false)}}})"),
        (#"{"error":{"code":-32600,"message":"Invalid request: unknown variant `nonexistent/probe`"},"id":4}"#, "message:error(id:int(4),code:-32600,message:Invalid request: unknown variant `nonexistent/probe`,data:<absent>)"),
    ]
}
