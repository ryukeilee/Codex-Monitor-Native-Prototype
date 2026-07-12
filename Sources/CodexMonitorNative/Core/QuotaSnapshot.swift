import Foundation

struct ResetBankRawField: Codable, Equatable {
    let name: String
    let value: String
}

struct ResetCreditRawField: Codable, Equatable {
    let path: String
    let value: String
}

struct ResetCreditDiagnosticSnapshot: Codable, Equatable {
    let summary: String
}

enum ResetCreditDetailsState: String, Codable, Equatable {
    case unavailable
    case appServerCountOnly
    case detailed
}

struct ResetCreditStatusSummary: Codable, Equatable, Identifiable {
    let status: String
    let count: Int

    var id: String { status }
}

struct ResetCreditDetailSnapshot: Codable, Equatable, Identifiable {
    let ordinal: Int
    let status: String
    let grantedAt: Date?
    let expiresAt: Date?

    var id: String {
        "reset-credit-\(ordinal)"
    }
}

struct ResetCreditTimeSnapshot: Codable, Equatable, Identifiable {
    let label: String
    let date: Date
    let sourcePath: String

    var id: String {
        "\(label):\(sourcePath)"
    }
}

enum ResetBankResetTimeStatus: String, Codable, Equatable {
    case actual
    case unexposed
    case parseFailed
}

/// Trust state for a quota window returned by the RPC response.
///
/// A quota value is kept as an integer for source and persistence
/// compatibility, while this state prevents an unavailable field from being
/// mistaken for a real 100% remaining value.
enum QuotaFieldState: String, Codable, Equatable, Sendable {
    case live
    case cached
    case unavailable
    case invalid

    var isDisplayable: Bool {
        switch self {
        case .live, .cached:
            return true
        case .unavailable, .invalid:
            return false
        }
    }

    var isCurrent: Bool {
        self == .live
    }
}

struct ResetBankSnapshot: Codable, Equatable, Identifiable {
    let limitId: String
    let windowId: String
    let displayName: String
    let remainingPercent: Int
    let resetAt: Date?
    let resolvedResetFieldName: String?
    let resetTimeStatus: ResetBankResetTimeStatus
    let rawResetFields: [ResetBankRawField]

    init(
        limitId: String,
        windowId: String,
        displayName: String,
        remainingPercent: Int,
        resetAt: Date?,
        resolvedResetFieldName: String? = nil,
        resetTimeStatus: ResetBankResetTimeStatus? = nil,
        rawResetFields: [ResetBankRawField]
    ) {
        self.limitId = limitId
        self.windowId = windowId
        self.displayName = displayName
        self.remainingPercent = remainingPercent
        self.resetAt = resetAt
        self.resolvedResetFieldName = resolvedResetFieldName
        self.resetTimeStatus = resetTimeStatus ?? {
            if resetAt != nil {
                return .actual
            }
            return rawResetFields.isEmpty ? .unexposed : .parseFailed
        }()
        self.rawResetFields = rawResetFields
    }

    var id: String {
        "\(limitId).\(windowId)"
    }

    private enum CodingKeys: String, CodingKey {
        case limitId
        case windowId
        case displayName
        case remainingPercent
        case resetAt
        case resolvedResetFieldName
        case resetTimeStatus
        case rawResetFields
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let limitId = try container.decode(String.self, forKey: .limitId)
        let windowId = try container.decode(String.self, forKey: .windowId)
        let displayName = try container.decode(String.self, forKey: .displayName)
        let remainingPercent = try container.decode(Int.self, forKey: .remainingPercent)
        let resetAt = try container.decodeIfPresent(Date.self, forKey: .resetAt)
        let resolvedResetFieldName = try container.decodeIfPresent(String.self, forKey: .resolvedResetFieldName)
        let rawResetFields = try container.decodeIfPresent([ResetBankRawField].self, forKey: .rawResetFields) ?? []
        let resetTimeStatus = try container.decodeIfPresent(ResetBankResetTimeStatus.self, forKey: .resetTimeStatus)

        self.init(
            limitId: limitId,
            windowId: windowId,
            displayName: displayName,
            remainingPercent: remainingPercent,
            resetAt: resetAt,
            resolvedResetFieldName: resolvedResetFieldName,
            resetTimeStatus: resetTimeStatus,
            rawResetFields: rawResetFields
        )
    }
}

struct QuotaSnapshot: Codable, Equatable {
    let weeklyQuotaPercent: Int
    let fiveHourQuotaPercent: Int
    let weeklyQuotaState: QuotaFieldState
    let fiveHourQuotaState: QuotaFieldState
    let resetAvailableCount: Int?
    let resetCreditDetailsState: ResetCreditDetailsState
    let resetCreditDiagnostic: ResetCreditDiagnosticSnapshot?
    let resetCreditDetails: [ResetCreditDetailSnapshot]
    let resetCreditStatusSummary: [ResetCreditStatusSummary]
    let resetCreditTimeEntries: [ResetCreditTimeSnapshot]
    let resetCreditRawFields: [ResetCreditRawField]
    let fiveHourResetAt: Date?
    let resetBanks: [ResetBankSnapshot]
    let refreshedAt: Date
    let dataSource: QuotaDataSource
    let errorMessage: String?
    let schemaVersion: Int

    init(
        weeklyQuotaPercent: Int,
        fiveHourQuotaPercent: Int,
        weeklyQuotaState: QuotaFieldState = .live,
        fiveHourQuotaState: QuotaFieldState = .live,
        resetAvailableCount: Int? = nil,
        resetCreditDetailsState: ResetCreditDetailsState = .appServerCountOnly,
        resetCreditDiagnostic: ResetCreditDiagnosticSnapshot? = nil,
        resetCreditDetails: [ResetCreditDetailSnapshot] = [],
        resetCreditStatusSummary: [ResetCreditStatusSummary] = [],
        resetCreditTimeEntries: [ResetCreditTimeSnapshot] = [],
        resetCreditRawFields: [ResetCreditRawField] = [],
        fiveHourResetAt: Date? = nil,
        resetBanks: [ResetBankSnapshot] = [],
        refreshedAt: Date,
        dataSource: QuotaDataSource,
        errorMessage: String? = nil,
        schemaVersion: Int = QuotaSnapshot.currentSchemaVersion
    ) {
        self.weeklyQuotaPercent = max(0, min(100, weeklyQuotaPercent))
        self.fiveHourQuotaPercent = max(0, min(100, fiveHourQuotaPercent))
        self.weeklyQuotaState = weeklyQuotaState
        self.fiveHourQuotaState = fiveHourQuotaState
        self.resetAvailableCount = resetAvailableCount
        self.resetCreditDetailsState = resetCreditDetailsState
        self.resetCreditDiagnostic = resetCreditDiagnostic
        self.resetCreditDetails = resetCreditDetails
        self.resetCreditStatusSummary = resetCreditStatusSummary
        self.resetCreditTimeEntries = resetCreditTimeEntries
        self.resetCreditRawFields = resetCreditRawFields
        self.fiveHourResetAt = fiveHourResetAt
        self.resetBanks = resetBanks
        self.refreshedAt = refreshedAt
        self.dataSource = dataSource
        self.errorMessage = errorMessage
        self.schemaVersion = schemaVersion
    }

    static let currentSchemaVersion = 7

    static let fallback = QuotaSnapshot(
        weeklyQuotaPercent: 0,
        fiveHourQuotaPercent: 0,
        weeklyQuotaState: .unavailable,
        fiveHourQuotaState: .unavailable,
        resetAvailableCount: nil,
        resetCreditDetailsState: .appServerCountOnly,
        resetCreditDiagnostic: nil,
        resetCreditDetails: [],
        resetCreditStatusSummary: [],
        resetCreditTimeEntries: [],
        resetCreditRawFields: [],
        fiveHourResetAt: nil,
        resetBanks: [],
        refreshedAt: .now,
        dataSource: .mock,
        errorMessage: nil
    )

    static let notConnected = QuotaSnapshot(
        weeklyQuotaPercent: 0,
        fiveHourQuotaPercent: 0,
        weeklyQuotaState: .unavailable,
        fiveHourQuotaState: .unavailable,
        resetAvailableCount: nil,
        resetCreditDetailsState: .appServerCountOnly,
        resetCreditDiagnostic: nil,
        resetCreditDetails: [],
        resetCreditStatusSummary: [],
        resetCreditTimeEntries: [],
        resetCreditRawFields: [],
        fiveHourResetAt: nil,
        resetBanks: [],
        refreshedAt: .now,
        dataSource: .mock,
        errorMessage: "Not connected to Codex"
    )

    private enum CodingKeys: String, CodingKey {
        case weeklyQuotaPercent
        case fiveHourQuotaPercent
        case weeklyQuotaState
        case fiveHourQuotaState
        case resetAvailableCount
        case resetCreditDetailsState
        case resetCreditDiagnostic
        case resetCreditDetails
        case resetCreditStatusSummary
        case resetCreditTimeEntries
        case resetCreditRawFields
        case fiveHourResetAt
        case resetBanks
        case refreshedAt
        case dataSource
        case errorMessage
        case schemaVersion
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let weeklyQuotaPercent = try container.decode(Int.self, forKey: .weeklyQuotaPercent)
        let fiveHourQuotaPercent = try container.decode(Int.self, forKey: .fiveHourQuotaPercent)
        let weeklyQuotaState = Self.normalizedState(
            rawValue: weeklyQuotaPercent,
            explicitState: try container.decodeIfPresent(QuotaFieldState.self, forKey: .weeklyQuotaState)
        )
        let fiveHourQuotaState = Self.normalizedState(
            rawValue: fiveHourQuotaPercent,
            explicitState: try container.decodeIfPresent(QuotaFieldState.self, forKey: .fiveHourQuotaState)
        )
        let resetAvailableCount = try container.decodeIfPresent(Int.self, forKey: .resetAvailableCount)
        let resetCreditDetailsState = try container.decodeIfPresent(ResetCreditDetailsState.self, forKey: .resetCreditDetailsState) ?? .appServerCountOnly
        let resetCreditDiagnostic = try container.decodeIfPresent(ResetCreditDiagnosticSnapshot.self, forKey: .resetCreditDiagnostic)
        let resetCreditDetails = try container.decodeIfPresent([ResetCreditDetailSnapshot].self, forKey: .resetCreditDetails) ?? []
        let resetCreditStatusSummary = try container.decodeIfPresent([ResetCreditStatusSummary].self, forKey: .resetCreditStatusSummary) ?? []
        let resetCreditTimeEntries = try container.decodeIfPresent([ResetCreditTimeSnapshot].self, forKey: .resetCreditTimeEntries) ?? []
        let resetCreditRawFields = try container.decodeIfPresent([ResetCreditRawField].self, forKey: .resetCreditRawFields) ?? []
        let fiveHourResetAt = try container.decodeIfPresent(Date.self, forKey: .fiveHourResetAt)
        let resetBanks = Self.decodeResetBanksLossy(from: container)
        let refreshedAt = try container.decode(Date.self, forKey: .refreshedAt)
        let dataSource = try container.decode(QuotaDataSource.self, forKey: .dataSource)
        let errorMessage = try container.decodeIfPresent(String.self, forKey: .errorMessage)
        let schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1

        self.init(
            weeklyQuotaPercent: weeklyQuotaPercent,
            fiveHourQuotaPercent: fiveHourQuotaPercent,
            weeklyQuotaState: weeklyQuotaState,
            fiveHourQuotaState: fiveHourQuotaState,
            resetAvailableCount: resetAvailableCount,
            resetCreditDetailsState: resetCreditDetailsState,
            resetCreditDiagnostic: resetCreditDiagnostic,
            resetCreditDetails: resetCreditDetails,
            resetCreditStatusSummary: resetCreditStatusSummary,
            resetCreditTimeEntries: resetCreditTimeEntries,
            resetCreditRawFields: resetCreditRawFields,
            fiveHourResetAt: fiveHourResetAt,
            resetBanks: resetBanks,
            refreshedAt: refreshedAt,
            dataSource: dataSource,
            errorMessage: errorMessage,
            schemaVersion: schemaVersion
        )
    }

    private static func normalizedState(
        rawValue: Int,
        explicitState: QuotaFieldState?
    ) -> QuotaFieldState {
        guard (0...100).contains(rawValue) else {
            return .invalid
        }
        return explicitState ?? .live
    }

    /// Replaces unavailable or invalid fields with the last trusted values,
    /// marking those values as historical cache data. Valid fields from the
    /// current response always win.
    func mergingPartial(with cachedSnapshot: QuotaSnapshot?) -> QuotaSnapshot {
        guard dataSource == .real,
              let cachedSnapshot,
              cachedSnapshot.dataSource == .real else {
            return self
        }

        let weekly = mergedField(
            value: weeklyQuotaPercent,
            state: weeklyQuotaState,
            cachedValue: cachedSnapshot.weeklyQuotaPercent,
            cachedState: cachedSnapshot.weeklyQuotaState
        )
        let fiveHour = mergedField(
            value: fiveHourQuotaPercent,
            state: fiveHourQuotaState,
            cachedValue: cachedSnapshot.fiveHourQuotaPercent,
            cachedState: cachedSnapshot.fiveHourQuotaState
        )

        return QuotaSnapshot(
            weeklyQuotaPercent: weekly.value,
            fiveHourQuotaPercent: fiveHour.value,
            weeklyQuotaState: weekly.state,
            fiveHourQuotaState: fiveHour.state,
            resetAvailableCount: resetAvailableCount,
            resetCreditDetailsState: resetCreditDetailsState,
            resetCreditDiagnostic: resetCreditDiagnostic,
            resetCreditDetails: resetCreditDetails,
            resetCreditStatusSummary: resetCreditStatusSummary,
            resetCreditTimeEntries: resetCreditTimeEntries,
            resetCreditRawFields: resetCreditRawFields,
            fiveHourResetAt: fiveHourResetAt,
            resetBanks: resetBanks,
            refreshedAt: refreshedAt,
            dataSource: dataSource,
            errorMessage: errorMessage,
            schemaVersion: schemaVersion
        )
    }

    private func mergedField(
        value: Int,
        state: QuotaFieldState,
        cachedValue: Int,
        cachedState: QuotaFieldState
    ) -> (value: Int, state: QuotaFieldState) {
        guard state != .live else {
            return (value, state)
        }

        guard cachedState.isDisplayable else {
            return (value, state)
        }

        return (cachedValue, .cached)
    }

    private static func decodeResetBanksLossy(from container: KeyedDecodingContainer<CodingKeys>) -> [ResetBankSnapshot] {
        guard var banksContainer = try? container.nestedUnkeyedContainer(forKey: .resetBanks) else {
            return []
        }

        var banks: [ResetBankSnapshot] = []
        while !banksContainer.isAtEnd {
            if let bank = try? banksContainer.decode(ResetBankSnapshot.self) {
                banks.append(bank)
            } else {
                _ = try? banksContainer.decode(DiscardedDecodable.self)
            }
        }

        return banks
    }
}

private struct DiscardedDecodable: Decodable {}
