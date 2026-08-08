import CoreFoundation
import Foundation

protocol ResetCreditsDetailRefreshing: Sendable {
    func fetchDetails(
        for accountBoundary: QuotaAccountBoundary
    ) async throws -> ResetCreditsDetailPayload
}

enum ResetCreditsDetailError: LocalizedError, Equatable {
    case authFileMissing
    case invalidAuthFile
    case tokensMissing
    case accountBoundaryMismatch
    case invalidResponse
    case invalidJSON
    case unexpectedStatusCode(Int)
    case missingCreditsField
    case noAvailableCredits
    case missingExpiresAt

    var errorDescription: String? {
        switch self {
        case .authFileMissing:
            return "auth 文件不存在"
        case .invalidAuthFile:
            return "auth 文件不可解析"
        case .tokensMissing:
            return "tokens 缺失"
        case .accountBoundaryMismatch:
            return "账号或登录会话与额度快照不一致"
        case .invalidResponse:
            return "响应不是有效 HTTP"
        case .invalidJSON:
            return "返回非 JSON"
        case .unexpectedStatusCode(let statusCode):
            return "HTTP 状态码 \(statusCode)"
        case .missingCreditsField:
            return "字段缺失：credits"
        case .noAvailableCredits:
            return "没有 available credits"
        case .missingExpiresAt:
            return "字段缺失：expires_at"
        }
    }
}

struct ResetCreditsDetailPayload: Equatable {
    let availableCount: Int?
    let availableCredits: [ResetCreditDetailSnapshot]
    let statusSummary: [ResetCreditStatusSummary]
}

struct ResetCreditsDetailProvider: ResetCreditsDetailRefreshing {
    private let authFileURL: URL
    private let timeoutInterval: TimeInterval
    private let authBoundaryReader: @Sendable (Data) -> QuotaAccountBoundary?
    private let dataLoader: @Sendable (URLRequest) async throws -> (Data, URLResponse)

    init(
        authFileURL: URL? = nil,
        timeoutInterval: TimeInterval = 5,
        authBoundaryReader: @escaping @Sendable (Data) -> QuotaAccountBoundary? = {
            CodexAuthIdentityReader.parse(data: $0)
        },
        dataLoader: (@Sendable (URLRequest) async throws -> (Data, URLResponse))? = nil
    ) {
        self.authFileURL = authFileURL ?? Self.defaultAuthFileURL()
        self.timeoutInterval = timeoutInterval
        self.authBoundaryReader = authBoundaryReader
        self.dataLoader = dataLoader ?? { request in
            try await URLSession.shared.data(for: request)
        }
    }

    static func defaultAuthFileURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL {
        CodexAuthIdentityReader.defaultCodexHomeURL(
            environment: environment,
            fileManager: fileManager
        )
        .appendingPathComponent("auth.json", isDirectory: false)
    }

    func fetchDetails(
        for accountBoundary: QuotaAccountBoundary
    ) async throws -> ResetCreditsDetailPayload {
        guard accountBoundary.isValid else {
            throw ResetCreditsDetailError.accountBoundaryMismatch
        }
        let authState = try loadAuthState(matching: accountBoundary)
        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")!)
        request.httpMethod = "GET"
        request.timeoutInterval = timeoutInterval
        request.setValue("Bearer \(authState.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("codex-1", forHTTPHeaderField: "OpenAI-Beta")
        request.setValue("Codex Desktop", forHTTPHeaderField: "originator")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if let accountID = authState.accountID, !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-ID")
        }

        let (data, response) = try await dataLoader(request)
        try validateCurrentAccountBoundary(accountBoundary)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ResetCreditsDetailError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw ResetCreditsDetailError.unexpectedStatusCode(httpResponse.statusCode)
        }

        return try Self.parsePayload(from: data)
    }

    private func loadAuthState(
        matching accountBoundary: QuotaAccountBoundary
    ) throws -> AuthState {
        let data: Data
        do {
            data = try Data(contentsOf: authFileURL)
        } catch {
            throw ResetCreditsDetailError.authFileMissing
        }

        let decoder = JSONDecoder()
        let decoded: AuthEnvelope
        do {
            decoded = try decoder.decode(AuthEnvelope.self, from: data)
        } catch {
            throw ResetCreditsDetailError.invalidAuthFile
        }

        guard let accessToken = normalizedHeaderValue(decoded.tokens.accessToken) else {
            throw ResetCreditsDetailError.tokensMissing
        }
        guard accountBoundary.matches(authBoundaryReader(data)) else {
            throw ResetCreditsDetailError.accountBoundaryMismatch
        }

        return AuthState(
            accessToken: accessToken,
            accountID: normalizedHeaderValue(decoded.tokens.accountID)
        )
    }

    private func validateCurrentAccountBoundary(
        _ expectedBoundary: QuotaAccountBoundary
    ) throws {
        guard let data = try? Data(contentsOf: authFileURL),
              expectedBoundary.matches(authBoundaryReader(data)) else {
            throw ResetCreditsDetailError.accountBoundaryMismatch
        }
    }

    private func normalizedHeaderValue(_ value: String?) -> String? {
        guard let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !normalized.isEmpty else {
            return nil
        }
        return normalized
    }

    static func parsePayload(from data: Data) throws -> ResetCreditsDetailPayload {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ResetCreditsDetailError.invalidJSON
        }

        return try parsePayload(from: object)
    }

    static func parsePayload(from object: [String: Any]) throws -> ResetCreditsDetailPayload {
        let availableCount = parseAvailableCount(from: object)
        guard let credits = object["credits"] as? [Any] else {
            throw ResetCreditsDetailError.missingCreditsField
        }

        var availableCredits: [ResetCreditDetailSnapshot] = []
        var statusCounts: [String: Int] = [:]
        var sawAvailableCreditWithoutExpiresAt = false

        for (index, rawCredit) in credits.enumerated() {
            guard let credit = rawCredit as? [String: Any] else {
                continue
            }

            let status = normalizedStatus(from: credit["status"] ?? credit["state"])
            statusCounts[status] = statusCounts[status, default: 0] + 1

            guard status == "available" else {
                continue
            }

            let expiresAt = parseDate(credit["expires_at"] ?? credit["expiresAt"])
            guard let expiresAt else {
                sawAvailableCreditWithoutExpiresAt = true
                continue
            }

            availableCredits.append(
                ResetCreditDetailSnapshot(
                    ordinal: index + 1,
                    status: status,
                    grantedAt: parseDate(credit["granted_at"] ?? credit["grantedAt"]),
                    expiresAt: expiresAt
                )
            )
        }

        if availableCredits.isEmpty {
            if sawAvailableCreditWithoutExpiresAt {
                throw ResetCreditsDetailError.missingExpiresAt
            }
            throw ResetCreditsDetailError.noAvailableCredits
        }

        let sortedAvailableCredits = availableCredits.sorted(by: compareAvailableCredits)
        let statusSummary = statusCounts
            .map { ResetCreditStatusSummary(status: $0.key, count: $0.value) }
            .sorted { lhs, rhs in
                if lhs.count != rhs.count {
                    return lhs.count > rhs.count
                }
                return lhs.status < rhs.status
            }

        return ResetCreditsDetailPayload(
            availableCount: availableCount,
            availableCredits: sortedAvailableCredits,
            statusSummary: statusSummary
        )
    }

    private static func compareAvailableCredits(_ lhs: ResetCreditDetailSnapshot, _ rhs: ResetCreditDetailSnapshot) -> Bool {
        switch (lhs.expiresAt, rhs.expiresAt) {
        case let (left?, right?):
            if left != right {
                return left < right
            }
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case (nil, nil):
            break
        }

        switch (lhs.grantedAt, rhs.grantedAt) {
        case let (left?, right?):
            if left != right {
                return left < right
            }
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case (nil, nil):
            break
        }

        return lhs.ordinal < rhs.ordinal
    }

    private static func normalizedStatus(from rawValue: Any?) -> String {
        guard let rawValue else {
            return "unknown"
        }

        if let string = rawValue as? String {
            let normalized = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return normalized.isEmpty ? "unknown" : normalized
        }

        return String(describing: rawValue).lowercased()
    }

    private static func parseAvailableCount(from object: [String: Any]) -> Int? {
        var counts: [Int] = []
        var hasInvalidValue = false

        for key in ["available_count", "availableCount"] {
            guard let rawValue = object[key], !(rawValue is NSNull) else { continue }
            guard let count = parseNonnegativeInteger(rawValue) else {
                hasInvalidValue = true
                continue
            }
            counts.append(count)
        }

        guard !hasInvalidValue,
              let count = counts.first,
              counts.allSatisfy({ $0 == count }) else {
            return nil
        }
        return count
    }

    private static func parseNonnegativeInteger(_ rawValue: Any) -> Int? {
        guard !isBooleanJSONValue(rawValue) else { return nil }

        if let number = rawValue as? NSNumber {
            let value = number.doubleValue
            guard value.isFinite,
                  value >= 0,
                  value.rounded() == value,
                  let integer = Int(exactly: value) else {
                return nil
            }
            return integer
        }

        if let string = rawValue as? String,
           let integer = Int(string.trimmingCharacters(in: .whitespacesAndNewlines)),
           integer >= 0 {
            return integer
        }

        return nil
    }

    private static func parseDate(_ rawValue: Any?) -> Date? {
        guard let rawValue, !isBooleanJSONValue(rawValue) else {
            return nil
        }

        if let date = rawValue as? Date {
            return date
        }

        if let number = rawValue as? NSNumber {
            return dateFromTimestamp(number.doubleValue)
        }

        if let string = rawValue as? String {
            let normalized = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if let numeric = Double(normalized) {
                return dateFromTimestamp(numeric)
            }

            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: normalized) {
                return date
            }

            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: normalized)
        }

        return nil
    }

    private static func isBooleanJSONValue(_ rawValue: Any) -> Bool {
        guard let number = rawValue as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    private static func dateFromTimestamp(_ rawValue: Double) -> Date? {
        guard rawValue.isFinite, rawValue > 0 else {
            return nil
        }

        let seconds = rawValue > 10_000_000_000 ? rawValue / 1_000 : rawValue
        return Date(timeIntervalSince1970: seconds)
    }
}

private struct AuthState {
    let accessToken: String
    let accountID: String?
}

private struct AuthEnvelope: Decodable {
    let tokens: Tokens

    struct Tokens: Decodable {
        let accessToken: String?
        let accountID: String?

        private enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case accountID = "account_id"
        }
    }
}
