import Foundation

enum CodexAppServerRequestID: Sendable, Equatable, Encodable {
    case integer(Int64)
    case string(String)

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .integer(let integer):
            try container.encode(integer)
        case .string(let string):
            try container.encode(string)
        }
    }
}

indirect enum CodexAppServerJSONValue: Sendable, Equatable, Encodable {
    case object([String: CodexAppServerJSONValue])
    case array([CodexAppServerJSONValue])
    case string(String)
    case integer(Int64)
    case number(Double)
    case bool(Bool)
    case null

    func encode(to encoder: Encoder) throws {
        switch self {
        case .object(let object):
            var container = encoder.container(keyedBy: DynamicCodingKey.self)
            for (key, value) in object {
                try container.encode(value, forKey: DynamicCodingKey(key))
            }
        case .array(let array):
            var container = encoder.unkeyedContainer()
            for value in array {
                try container.encode(value)
            }
        case .string(let string):
            var container = encoder.singleValueContainer()
            try container.encode(string)
        case .integer(let integer):
            var container = encoder.singleValueContainer()
            try container.encode(integer)
        case .number(let number):
            var container = encoder.singleValueContainer()
            try container.encode(number)
        case .bool(let bool):
            var container = encoder.singleValueContainer()
            try container.encode(bool)
        case .null:
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        }
    }

    func foundationObject() -> [String: Any]? {
        guard case .object(let object) = self else { return nil }
        return object.mapValues(\.foundationValue)
    }

    private var foundationValue: Any {
        switch self {
        case .object(let object):
            return object.mapValues(\.foundationValue)
        case .array(let array):
            return array.map(\.foundationValue)
        case .string(let string):
            return string
        case .integer(let integer):
            return NSNumber(value: integer)
        case .number(let number):
            return NSNumber(value: number)
        case .bool(let bool):
            return NSNumber(value: bool)
        case .null:
            return NSNull()
        }
    }
}

struct CodexAppServerRemoteError: Sendable, Equatable, Encodable {
    let code: Int64
    let message: String
    let data: CodexAppServerJSONValue?

    init(code: Int64, message: String, data: CodexAppServerJSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicCodingKey.self)
        try container.encode(code, forKey: DynamicCodingKey("code"))
        try container.encode(message, forKey: DynamicCodingKey("message"))
        try container.encodeIfPresent(data, forKey: DynamicCodingKey("data"))
    }
}

enum CodexAppServerMessage: Sendable, Equatable, Encodable {
    case response(id: CodexAppServerRequestID, result: CodexAppServerJSONValue)
    case error(id: CodexAppServerRequestID, error: CodexAppServerRemoteError)
    case request(id: CodexAppServerRequestID, method: String, params: CodexAppServerJSONValue?)
    case notification(method: String, params: CodexAppServerJSONValue?)

    func encode(to encoder: Encoder) throws {
        var object = encoder.container(keyedBy: DynamicCodingKey.self)
        switch self {
        case .response(let id, let result):
            try object.encode(id, forKey: DynamicCodingKey("id"))
            try object.encode(result, forKey: DynamicCodingKey("result"))
        case .error(let id, let error):
            try object.encode(id, forKey: DynamicCodingKey("id"))
            try object.encode(error, forKey: DynamicCodingKey("error"))
        case .request(let id, let method, let params):
            try object.encode(id, forKey: DynamicCodingKey("id"))
            try object.encode(method, forKey: DynamicCodingKey("method"))
            try object.encodeIfPresent(params, forKey: DynamicCodingKey("params"))
        case .notification(let method, let params):
            try object.encode(method, forKey: DynamicCodingKey("method"))
            try object.encodeIfPresent(params, forKey: DynamicCodingKey("params"))
        }
    }
}

enum CodexAppServerProtocolViolation: Error, Sendable, Equatable {
    case invalidJSON
    case topLevelNotObject
    case missingMessageRole
    case mixedMessageRoles
    case missingID
    case invalidID
    case malformedError
    case invalidMessage
}

/// One inbound protocol frame read straight from the object `JSONSerialization` produced.
///
/// This is the representation the production client consumes: a response payload stays the
/// Foundation object the single parse already built, so `RealQuotaProvider` reads it without an
/// intermediate typed value tree or a `foundationObject()` conversion back. `message()` builds the
/// typed `CodexAppServerMessage` the wire-contract tests assert, from the same validated values.
enum CodexAppServerInboundFrame {
    case response(id: CodexAppServerRequestID, result: Any)
    case error(id: CodexAppServerRequestID, error: CodexAppServerRemoteError)
    case request(id: CodexAppServerRequestID, method: String, params: CodexAppServerJSONValue?)
    case notification(method: String, params: CodexAppServerJSONValue?)
}

extension CodexAppServerInboundFrame {
    /// Builds the typed protocol message. Only the raw response payload still needs converting; the
    /// other roles keep the typed values the frame decoder already built from the single parse.
    func message() throws -> CodexAppServerMessage {
        switch self {
        case .response(let id, let result):
            return .response(id: id, result: try CodexAppServerMessageDecoder.value(from: result))
        case .error(let id, let error):
            return .error(id: id, error: error)
        case .request(let id, let method, let params):
            return .request(id: id, method: method, params: params)
        case .notification(let method, let params):
            return .notification(method: method, params: params)
        }
    }
}

enum CodexAppServerCodec {
    /// Decodes one newline-delimited protocol frame into the inbound representation.
    ///
    /// The line is parsed once and a response payload is kept as the Foundation object that pass
    /// produced: no value tree is constructed and nothing is converted back. The same pass rejects
    /// a non-finite number anywhere in a payload, because `JSONSerialization` accepts `-1e400` as
    /// `-infinity` where the pre-change `JSONDecoder` refused non-finite numbers. See
    /// `CodexAppServerMessageDecoder` for the numeric typing that is the wire contract inherited
    /// from the previous decoder, and `docs/optimization-2026-10-11-rpc-parse.md` plus
    /// `CodexAppServerProtocolTests` for the measured bound and the pinned cases.
    static func decodeInboundFrame(_ data: Data) throws -> CodexAppServerInboundFrame {
        try decodeFrame(from: data, validating: true)
    }

    /// Decodes one newline-delimited protocol frame.
    ///
    /// The previous implementation parsed every line twice (a `JSONSerialization` probe for the
    /// top-level shape followed by `JSONDecoder`) and paid the decoder's per-node `try?` cascade
    /// for values it immediately discarded. This shares the single `JSONSerialization` pass with
    /// `decodeInboundFrame`; `message()` validates the payload while it converts it to the value
    /// tree, so the frame extraction skips its own scan and the typed path keeps one traversal.
    static func decodeLine(_ data: Data) throws -> CodexAppServerMessage {
        try decodeFrame(from: data, validating: false).message()
    }

    /// The Foundation number the typed value tree exposes for one raw JSON number.
    ///
    /// A raw payload keeps the storage `JSONSerialization` chose, while the typed tree maps an
    /// integral number that fits `Int64` to that integer and every other finite number to its
    /// double image. Callers that read raw numbers use this to see the value the decoded tree held,
    /// which is what the removed `foundationObject()` handed the parser.
    static func foundationNumber(from rawNumber: NSNumber) -> NSNumber {
        CodexAppServerMessageDecoder.foundationNumber(from: rawNumber)
    }

    /// Compares two raw JSON values the way the typed value tree compared them.
    ///
    /// `NSObject.isEqual` alone compares an integer-stored and a floating-stored number after a
    /// lossy conversion (so `9007199254740993` would equal `9007199254740993.0`), while the typed
    /// tree mapped them to different integers. This applies the same numeric contract recursively
    /// so a caller comparing raw payloads sees the decoded tree's equality.
    static func rawValuesAreEqual(_ lhs: Any, _ rhs: Any) -> Bool {
        CodexAppServerMessageDecoder.rawValuesAreEqual(lhs, rhs)
    }

    private static func decodeFrame(
        from data: Data,
        validating: Bool
    ) throws -> CodexAppServerInboundFrame {
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw CodexAppServerProtocolViolation.invalidJSON
        }

        guard let object = json as? [String: Any] else {
            throw CodexAppServerProtocolViolation.topLevelNotObject
        }

        return try CodexAppServerMessageDecoder.frame(from: object, validating: validating)
    }

    static func encodeRequest(
        id: CodexAppServerRequestID,
        method: String,
        params: CodexAppServerJSONValue? = nil
    ) throws -> Data {
        try JSONEncoder().encode(CodexAppServerMessage.request(id: id, method: method, params: params))
    }

    static func encodeNotification(
        method: String,
        params: CodexAppServerJSONValue? = nil
    ) throws -> Data {
        try JSONEncoder().encode(CodexAppServerMessage.notification(method: method, params: params))
    }

    static func encodeErrorResponse(
        id: CodexAppServerRequestID,
        error: CodexAppServerRemoteError
    ) throws -> Data {
        try JSONEncoder().encode(CodexAppServerMessage.error(id: id, error: error))
    }
}

/// Builds protocol messages from the object `JSONSerialization` produced for one frame.
///
/// The numeric typing below is the wire contract inherited from the previous `JSONDecoder`-based
/// decode and has to stay in place:
///
/// - `JSONSerialization` returns every number as an `NSNumber` whose `objCType` names the storage
///   its parser chose. Integer storage keeps its exact `Int64` when it fits and otherwise becomes
///   `.number`; floating-point storage becomes `.integer` only when its double is exactly the
///   `Int64` it denotes, and `Int64.min` is excepted because that double image is shared with
///   out-of-range neighbours; every other finite value becomes `.number`. A non-finite value is
///   rejected because `JSONDecoder` refused such numbers while `JSONSerialization` accepts
///   `-1e400` as `-infinity`.
/// - An identifier or remote-error code follows the same rule, so a JSON string stays `.string`
///   and any other number is not an identifier.
/// - A key that is absent, or present with JSON `null`, is not a value (`data`, `params`), while a
///   `null` `result` is the response payload because the response role makes it one.
/// - Decimal-stored numbers are read through their exact decimal text (`double(from:)`) so they
///   keep the written value as a double, because `NSDecimalNumber.doubleValue` is not correctly
///   rounded for them; that is what keeps ordinary percentages exact.
/// - Floating-point storage is read as the double's image: an integral double becomes `.integer`
///   when it denotes an `Int64`. A double does not always carry the digits that were written
///   (`1.152921504606847e+18` denotes `1152921504606847000` but is the double
///   `1152921504606846976`), and the pre-change `JSONDecoder` pass converted those written digits,
///   so the two decoders differ for a float-syntax literal with more significant digits than a
///   double carries. The bound is measured by magnitude: `[2^50,2^54)` showed no difference in
///   80000 sampled shortest-round-trip texts and differences appear from 2^54 upward; the quota
///   path consumes no value of that size, so no quota decision can be affected. Those inputs are
///   pinned by `CodexAppServerProtocolTests` and measured in
///   `docs/optimization-2026-10-11-rpc-parse.md`.
private enum CodexAppServerMessageDecoder {
    static func frame(
        from object: [String: Any],
        validating: Bool
    ) throws -> CodexAppServerInboundFrame {
        let hasResult = object["result"] != nil
        let hasError = object["error"] != nil
        let hasMethod = object["method"] != nil

        if (hasResult && hasError) || (hasMethod && (hasResult || hasError)) {
            throw CodexAppServerProtocolViolation.mixedMessageRoles
        }

        if hasResult {
            guard let id = object["id"] else {
                throw CodexAppServerProtocolViolation.missingID
            }
            let requestID = try requestID(from: id)
            let result = object["result"]!
            return .response(
                id: requestID,
                result: validating ? try finiteValue(from: result) : result
            )
        }

        if hasError {
            guard let id = object["id"] else {
                throw CodexAppServerProtocolViolation.missingID
            }
            let requestID = try requestID(from: id)
            return .error(id: requestID, error: try remoteError(from: object["error"]!))
        }

        if hasMethod {
            guard let method = object["method"] as? String else {
                throw CodexAppServerProtocolViolation.invalidMessage
            }
            // Params are decoded to the value tree before the id, exactly as the previous decoder
            // did. The typed message reuses this value, so the payload is traversed once.
            let params = try optionalValue(from: object["params"])
            guard let id = object["id"] else {
                return .notification(method: method, params: params)
            }
            return .request(id: try requestID(from: id), method: method, params: params)
        }

        throw CodexAppServerProtocolViolation.missingMessageRole
    }

    /// Validates that every number in a raw payload is finite and returns the value unchanged.
    ///
    /// `JSONSerialization` accepts `-1e400` as `-infinity` where the pre-change `JSONDecoder`
    /// refused non-finite numbers, so the payload is walked without rebuilding containers and the
    /// frame is rejected exactly as before. This walk replaces the removed value-tree construction
    /// on the production path.
    static func finiteValue(from value: Any) throws -> Any {
        if let number = value as? NSNumber {
            if !isBoolean(number),
               numberType(of: number) == .floatingPoint,
               !double(from: number).isFinite {
                throw CodexAppServerProtocolViolation.invalidMessage
            }
            return value
        }

        // `JSONSerialization` hands back Objective-C containers below the top level. Iterating them
        // directly keeps the scan free of the `as? [String: Any]` bridge that would copy each
        // container; the quota parser still bridges what it reads.
        if let dictionary = value as? NSDictionary {
            for (_, nested) in dictionary {
                _ = try finiteValue(from: nested)
            }
            return value
        }

        if let array = value as? NSArray {
            for element in array {
                _ = try finiteValue(from: element)
            }
            return value
        }

        return value
    }

    static func requestID(from value: Any) throws -> CodexAppServerRequestID {
        if let string = value as? String {
            return .string(string)
        }
        guard let number = value as? NSNumber,
              !isBoolean(number),
              let integer = integer(from: number) else {
            throw CodexAppServerProtocolViolation.invalidID
        }
        return .integer(integer)
    }

    static func remoteError(from value: Any) throws -> CodexAppServerRemoteError {
        guard let object = value as? [String: Any],
              let codeNumber = object["code"] as? NSNumber,
              !isBoolean(codeNumber),
              let code = integer(from: codeNumber),
              let message = object["message"] as? String else {
            throw CodexAppServerProtocolViolation.malformedError
        }
        return CodexAppServerRemoteError(
            code: code,
            message: message,
            data: try optionalValue(from: object["data"])
        )
    }

    /// Reads an optional value the way `decodeIfPresent` does: a key that is absent, or present
    /// with JSON `null`, has no value.
    static func optionalValue(from value: Any?) throws -> CodexAppServerJSONValue? {
        guard let value, !(value is NSNull) else {
            return nil
        }
        return try self.value(from: value)
    }

    /// The Foundation number the typed value tree exposes for one raw JSON number.
    static func foundationNumber(from number: NSNumber) -> NSNumber {
        if isBoolean(number) {
            return NSNumber(value: number.boolValue)
        }
        if let integer = integer(from: number) {
            return NSNumber(value: integer)
        }
        return NSNumber(value: double(from: number))
    }

    /// Recursive counterpart of `foundationNumber(from:)` for whole payload values.
    ///
    /// Numbers are compared through their decoded representation, while nested containers keep the
    /// value equality Foundation's `NSArray` / `NSDictionary` applied to the converted tree (so a
    /// boolean nested in an array still equals the number `1`). The top-level boolean/number
    /// mismatch is enforced by `mergeAliasedValues` before it calls this.
    static func rawValuesAreEqual(_ lhs: Any, _ rhs: Any) -> Bool {
        if let lhsNumber = lhs as? NSNumber, let rhsNumber = rhs as? NSNumber {
            return foundationNumber(from: lhsNumber).isEqual(foundationNumber(from: rhsNumber))
        }

        if let lhsObject = lhs as? NSDictionary, let rhsObject = rhs as? NSDictionary {
            guard lhsObject.count == rhsObject.count else { return false }
            for (key, value) in lhsObject {
                guard let rhsValue = rhsObject.object(forKey: key),
                      rawValuesAreEqual(value, rhsValue) else {
                    return false
                }
            }
            return true
        }

        if let lhsArray = lhs as? NSArray, let rhsArray = rhs as? NSArray {
            guard lhsArray.count == rhsArray.count else { return false }
            for index in 0..<lhsArray.count where !rawValuesAreEqual(lhsArray[index], rhsArray[index]) {
                return false
            }
            return true
        }

        guard let lhsObject = lhs as? NSObject, let rhsObject = rhs as? NSObject else {
            return false
        }
        return lhsObject.isEqual(rhsObject)
    }

    static func value(from value: Any) throws -> CodexAppServerJSONValue {
        if let number = value as? NSNumber {
            if isBoolean(number) {
                return .bool(number.boolValue)
            }
            if let integer = integer(from: number) {
                return .integer(integer)
            }
            let double = double(from: number)
            guard double.isFinite else {
                throw CodexAppServerProtocolViolation.invalidMessage
            }
            return .number(double)
        }

        if let string = value as? String {
            return .string(string)
        }

        if value is NSNull {
            return .null
        }

        if let object = value as? [String: Any] {
            var values: [String: CodexAppServerJSONValue] = [:]
            values.reserveCapacity(object.count)
            for (key, nested) in object {
                values[key] = try self.value(from: nested)
            }
            return .object(values)
        }

        if let array = value as? [Any] {
            var values: [CodexAppServerJSONValue] = []
            values.reserveCapacity(array.count)
            for element in array {
                values.append(try self.value(from: element))
            }
            return .array(values)
        }

        throw CodexAppServerProtocolViolation.invalidMessage
    }

    /// Reads the double a JSON number denotes.
    ///
    /// `JSONSerialization` stores some decimal texts as `NSDecimalNumber`, whose `doubleValue` is
    /// not correctly rounded for them; re-reading that number's exact decimal text keeps the double
    /// the written digits denote (`Double(text)` is correctly rounded).
    private static func double(from number: NSNumber) -> Double {
        if let decimal = number as? NSDecimalNumber, let exact = Double(decimal.stringValue) {
            return exact
        }
        return number.doubleValue
    }

    private static func isBoolean(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    /// The `Int64` a JSON number denotes when it is integral and fits `Int64`, and `nil` for
    /// fractional, non-finite, or out-of-range numbers.
    private static func integer(from number: NSNumber) -> Int64? {
        switch numberType(of: number) {
        case .signedInteger:
            return number.int64Value
        case .unsignedInteger:
            return Int64(exactly: number.uint64Value)
        case .floatingPoint:
            let double = double(from: number)
            guard double.isFinite, double.rounded() == double else {
                return nil
            }
            // The double image, not the written digits: floating-point storage has already lost
            // whatever precision the written number had beyond the double, so the digits are not
            // available here. See `CodexAppServerMessageDecoder` for the affected family and its
            // measured bound.
            //
            // Every written value in (-9223372036854776832, -9223372036854775809] shares
            // `Int64.min`'s double image, so a floating-point number is never read as
            // `Int64.min`; that exact value still arrives through integer storage.
            guard let integer = Int64(exactly: double), integer != .min else {
                return nil
            }
            return integer
        }
    }

    private enum JSONNumberType {
        case signedInteger
        case unsignedInteger
        case floatingPoint
    }

    /// `JSONSerialization` returns an integral number through the narrowest `NSNumber` storage its
    /// parser selected; every other kind (including the decimal it uses for out-of-range integers)
    /// reports a floating-point `objCType`.
    private static func numberType(of number: NSNumber) -> JSONNumberType {
        switch number.objCType.pointee {
        case CChar(UInt8(ascii: "c")), CChar(UInt8(ascii: "s")), CChar(UInt8(ascii: "i")),
             CChar(UInt8(ascii: "l")), CChar(UInt8(ascii: "q")):
            return .signedInteger
        case CChar(UInt8(ascii: "C")), CChar(UInt8(ascii: "S")), CChar(UInt8(ascii: "I")),
             CChar(UInt8(ascii: "L")), CChar(UInt8(ascii: "Q")):
            return .unsignedInteger
        default:
            return .floatingPoint
        }
    }
}

private struct DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init(_ stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(stringValue: String) {
        self.init(stringValue)
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}
