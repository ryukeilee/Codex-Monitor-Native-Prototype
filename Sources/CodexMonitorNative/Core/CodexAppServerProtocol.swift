import Foundation

enum CodexAppServerRequestID: Sendable, Equatable, Codable {
    case integer(Int64)
    case string(String)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let integer = try? container.decode(Int64.self) {
            self = .integer(integer)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else {
            throw CodexAppServerProtocolViolation.invalidID
        }
    }

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

indirect enum CodexAppServerJSONValue: Sendable, Equatable, Codable {
    case object([String: CodexAppServerJSONValue])
    case array([CodexAppServerJSONValue])
    case string(String)
    case integer(Int64)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let singleValue = try decoder.singleValueContainer()
        if singleValue.decodeNil() {
            self = .null
        } else if let bool = try? singleValue.decode(Bool.self) {
            self = .bool(bool)
        } else if let integer = try? singleValue.decode(Int64.self) {
            self = .integer(integer)
        } else if let number = try? singleValue.decode(Double.self) {
            self = .number(number)
        } else if let string = try? singleValue.decode(String.self) {
            self = .string(string)
        } else if let object = try? decoder.container(keyedBy: DynamicCodingKey.self) {
            var values: [String: CodexAppServerJSONValue] = [:]
            for key in object.allKeys {
                values[key.stringValue] = try object.decode(CodexAppServerJSONValue.self, forKey: key)
            }
            self = .object(values)
        } else if var array = try? decoder.unkeyedContainer() {
            var values: [CodexAppServerJSONValue] = []
            while !array.isAtEnd {
                values.append(try array.decode(CodexAppServerJSONValue.self))
            }
            self = .array(values)
        } else {
            throw DecodingError.typeMismatch(
                CodexAppServerJSONValue.self,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unsupported JSON value")
            )
        }
    }

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

struct CodexAppServerRemoteError: Sendable, Equatable, Codable {
    let code: Int64
    let message: String
    let data: CodexAppServerJSONValue?

    init(code: Int64, message: String, data: CodexAppServerJSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    init(from decoder: Decoder) throws {
        let container: KeyedDecodingContainer<DynamicCodingKey>
        do {
            container = try decoder.container(keyedBy: DynamicCodingKey.self)
        } catch {
            throw CodexAppServerProtocolViolation.malformedError
        }
        guard let code = try? container.decode(Int64.self, forKey: DynamicCodingKey("code")),
              let message = try? container.decode(String.self, forKey: DynamicCodingKey("message")) else {
            throw CodexAppServerProtocolViolation.malformedError
        }

        self.code = code
        self.message = message
        self.data = try container.decodeIfPresent(CodexAppServerJSONValue.self, forKey: DynamicCodingKey("data"))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicCodingKey.self)
        try container.encode(code, forKey: DynamicCodingKey("code"))
        try container.encode(message, forKey: DynamicCodingKey("message"))
        try container.encodeIfPresent(data, forKey: DynamicCodingKey("data"))
    }
}

enum CodexAppServerMessage: Sendable, Equatable, Codable {
    case response(id: CodexAppServerRequestID, result: CodexAppServerJSONValue)
    case error(id: CodexAppServerRequestID, error: CodexAppServerRemoteError)
    case request(id: CodexAppServerRequestID, method: String, params: CodexAppServerJSONValue?)
    case notification(method: String, params: CodexAppServerJSONValue?)

    init(from decoder: Decoder) throws {
        let object = try decoder.container(keyedBy: DynamicCodingKey.self)
        let resultKey = DynamicCodingKey("result")
        let errorKey = DynamicCodingKey("error")
        let methodKey = DynamicCodingKey("method")
        let idKey = DynamicCodingKey("id")
        let paramsKey = DynamicCodingKey("params")

        let hasResult = object.contains(resultKey)
        let hasError = object.contains(errorKey)
        let hasMethod = object.contains(methodKey)

        if (hasResult && hasError) || (hasMethod && (hasResult || hasError)) {
            throw CodexAppServerProtocolViolation.mixedMessageRoles
        }

        if hasResult {
            guard object.contains(idKey) else {
                throw CodexAppServerProtocolViolation.missingID
            }
            self = .response(
                id: try object.decode(CodexAppServerRequestID.self, forKey: idKey),
                result: try object.decode(CodexAppServerJSONValue.self, forKey: resultKey)
            )
        } else if hasError {
            guard object.contains(idKey) else {
                throw CodexAppServerProtocolViolation.missingID
            }
            self = .error(
                id: try object.decode(CodexAppServerRequestID.self, forKey: idKey),
                error: try object.decode(CodexAppServerRemoteError.self, forKey: errorKey)
            )
        } else if hasMethod {
            let method: String
            do {
                method = try object.decode(String.self, forKey: methodKey)
            } catch {
                throw CodexAppServerProtocolViolation.invalidMessage
            }
            let params = try object.decodeIfPresent(CodexAppServerJSONValue.self, forKey: paramsKey)
            if object.contains(idKey) {
                self = .request(
                    id: try object.decode(CodexAppServerRequestID.self, forKey: idKey),
                    method: method,
                    params: params
                )
            } else {
                self = .notification(method: method, params: params)
            }
        } else {
            throw CodexAppServerProtocolViolation.missingMessageRole
        }
    }

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

enum CodexAppServerCodec {
    static func decodeLine(_ data: Data) throws -> CodexAppServerMessage {
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw CodexAppServerProtocolViolation.invalidJSON
        }

        guard json is [String: Any] else {
            throw CodexAppServerProtocolViolation.topLevelNotObject
        }

        do {
            return try JSONDecoder().decode(CodexAppServerMessage.self, from: data)
        } catch let violation as CodexAppServerProtocolViolation {
            throw violation
        } catch {
            throw CodexAppServerProtocolViolation.invalidMessage
        }
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
