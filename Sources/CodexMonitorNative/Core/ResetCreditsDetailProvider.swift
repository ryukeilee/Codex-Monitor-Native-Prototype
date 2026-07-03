import Foundation

protocol ResetCreditsDetailRefreshing: Sendable {
    func fetchDetails() async throws -> ResetCreditsDetailPayload
}

enum ResetCreditsDetailError: LocalizedError, Equatable {
    case authFileMissing
    case invalidAuthFile
    case tokensMissing
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
    private let dataLoader: @Sendable (URLRequest) async throws -> (Data, URLResponse)

    init(
        authFileURL: URL = URL(fileURLWithPath: NSString(string: "~/.codex/auth.json").expandingTildeInPath),
        timeoutInterval: TimeInterval = 5,
        dataLoader: (@Sendable (URLRequest) async throws -> (Data, URLResponse))? = nil
    ) {
        self.authFileURL = authFileURL
        self.timeoutInterval = timeoutInterval
        self.dataLoader = dataLoader ?? { request in
            try await URLSession.shared.data(for: request)
        }
    }

    func fetchDetails() async throws -> ResetCreditsDetailPayload {
        let authState = try loadAuthState()
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
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ResetCreditsDetailError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw ResetCreditsDetailError.unexpectedStatusCode(httpResponse.statusCode)
        }

        return try Self.parsePayload(from: data)
    }

    private func loadAuthState() throws -> AuthState {
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

        guard let accessToken = decoded.tokens.accessToken,
              !accessToken.isEmpty else {
            throw ResetCreditsDetailError.tokensMissing
        }

        return AuthState(
            accessToken: accessToken,
            accountID: decoded.tokens.accountID?.isEmpty == false ? decoded.tokens.accountID : nil
        )
    }

    static func parsePayload(from data: Data) throws -> ResetCreditsDetailPayload {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ResetCreditsDetailError.invalidJSON
        }

        return try parsePayload(from: object)
    }

    static func parsePayload(from object: [String: Any]) throws -> ResetCreditsDetailPayload {
        let availableCount = parseOptionalInt(object["available_count"] ?? object["availableCount"])
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

    private static func parseOptionalInt(_ rawValue: Any?) -> Int? {
        guard let rawValue else {
            return nil
        }

        if let value = rawValue as? Int {
            return value
        }

        if let number = rawValue as? NSNumber {
            return number.intValue
        }

        if let string = rawValue as? String {
            return Int(string)
        }

        return nil
    }

    private static func parseDate(_ rawValue: Any?) -> Date? {
        guard let rawValue else {
            return nil
        }

        if let date = rawValue as? Date {
            return date
        }

        if let seconds = rawValue as? Double {
            return dateFromTimestamp(seconds)
        }

        if let seconds = rawValue as? Int {
            return dateFromTimestamp(Double(seconds))
        }

        if let string = rawValue as? String {
            if let numeric = Double(string) {
                return dateFromTimestamp(numeric)
            }

            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: string) {
                return date
            }

            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: string)
        }

        return nil
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
