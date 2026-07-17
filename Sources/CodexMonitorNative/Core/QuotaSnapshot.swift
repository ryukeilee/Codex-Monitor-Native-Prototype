import Foundation

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

/// Shared wall-clock semantics for persisted quota timestamps.
///
/// Dates describe server-visible instants, while tasks only provide a wake-up
/// hint. Callers must re-evaluate these rules with a fresh `now` whenever a
/// task wakes or the system clock changes.
enum QuotaTemporalSemantics {
    static let defaultStaleAfterInterval: TimeInterval = 20 * 60

    struct Freshness: Equatable {
        let isFresh: Bool
        let recheckAfter: TimeInterval?
    }

    struct Transition: Equatable {
        enum Kind: Equatable {
            case freshness
            case quotaRecovery
            case resetCreditExpiry
            case displayOnly
        }

        let date: Date
        let kind: Kind

        var requiresRefresh: Bool {
            kind == .quotaRecovery || kind == .resetCreditExpiry
        }
    }

    static func isPending(deadline: Date, at now: Date) -> Bool {
        now < deadline
    }

    static func freshness(
        lastSuccessAt: Date,
        now: Date,
        staleAfterInterval: TimeInterval
    ) -> Freshness {
        guard staleAfterInterval.isFinite, staleAfterInterval > 0 else {
            return Freshness(isFresh: false, recheckAfter: nil)
        }

        // A wall-clock rollback must not produce a negative age or make the
        // one-shot scheduler disappear. Recheck after one full freshness
        // interval; a system-clock notification also requests fresh data.
        let age = max(0, now.timeIntervalSince(lastSuccessAt))
        guard age.isFinite, age < staleAfterInterval else {
            return Freshness(isFresh: false, recheckAfter: nil)
        }

        return Freshness(
            isFresh: true,
            recheckAfter: staleAfterInterval - age
        )
    }

    static func isAvailableResetCredit(
        _ detail: ResetCreditDetailSnapshot,
        at now: Date
    ) -> Bool {
        detail.status
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "available" &&
        detail.expiresAt.map { isPending(deadline: $0, at: now) } == true
    }

    static func upcomingTransitions(
        snapshot: QuotaSnapshot,
        status: QuotaRefreshStatus,
        lastSuccessAt: Date?,
        now: Date,
        staleAfterInterval: TimeInterval = defaultStaleAfterInterval
    ) -> [Transition] {
        guard snapshot.dataSource == .real else { return [] }
        var transitions: [Transition] = []

        if status == .success, let lastSuccessAt {
            let freshness = freshness(
                lastSuccessAt: lastSuccessAt,
                now: now,
                staleAfterInterval: staleAfterInterval
            )
            if let recheckAfter = freshness.recheckAfter {
                transitions.append(
                    Transition(
                        date: now.addingTimeInterval(recheckAfter),
                        kind: .freshness
                    )
                )
            }
        }

        func append(_ date: Date?, kind: Transition.Kind) {
            guard let date, isPending(deadline: date, at: now) else { return }
            transitions.append(Transition(date: date, kind: kind))
        }

        for window in snapshot.quotaWindows where window.state.isCurrent {
            append(window.resetAt, kind: .quotaRecovery)
        }
        if snapshot.fiveHourQuotaState.isCurrent {
            append(snapshot.fiveHourResetAt, kind: .quotaRecovery)
        }
        for bank in snapshot.resetBanks {
            append(bank.resetAt, kind: .quotaRecovery)
        }
        for detail in snapshot.resetCreditDetails
            where isAvailableResetCredit(detail, at: now) {
            append(detail.expiresAt, kind: .resetCreditExpiry)
        }
        for entry in snapshot.resetCreditTimeEntries {
            append(entry.date, kind: .displayOnly)
        }

        return transitions.sorted { lhs, rhs in
            if lhs.date != rhs.date { return lhs.date < rhs.date }
            return transitionRank(lhs.kind) < transitionRank(rhs.kind)
        }
    }

    private static func transitionRank(_ kind: Transition.Kind) -> Int {
        switch kind {
        case .freshness: return 0
        case .quotaRecovery: return 1
        case .resetCreditExpiry: return 2
        case .displayOnly: return 3
        }
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

/// Semantic classification for a server-provided quota window.  The server
/// may expose more than the two windows used by the original UI, so unknown
/// durations are retained instead of being guessed as a familiar window.
enum QuotaWindowKind: String, Codable, Equatable, Sendable {
    case fiveHour
    case weekly
    case monthly
    case unknown

    var displayName: String {
        switch self {
        case .fiveHour:
            return "5小时额度"
        case .weekly:
            return "周额度"
        case .monthly:
            return "月额度"
        case .unknown:
            return "未知额度"
        }
    }

    static func from(durationMinutes: Int?) -> QuotaWindowKind {
        switch durationMinutes {
        case 300:
            return .fiveHour
        case 10080:
            return .weekly
        case 43200:
            return .monthly
        default:
            return .unknown
        }
    }
}

/// Dynamic quota data shared by the app and widget.  `id` remains stable for
/// the server's source identity, while `semanticIdentity` lets cache merging
/// treat a weekly fallback bank and the canonical weekly bank as one window.
struct QuotaWindow: Codable, Equatable, Identifiable, Sendable {
    let limitId: String
    let windowId: String
    let kind: QuotaWindowKind
    let durationMinutes: Int?
    let remainingPercent: Int
    let state: QuotaFieldState
    let resetAt: Date?

    var id: String { "\(limitId).\(windowId)" }
    var displayName: String { kind.displayName }
    var semanticIdentity: String {
        kind == .unknown ? id : kind.rawValue
    }

    init(
        limitId: String,
        windowId: String,
        kind: QuotaWindowKind,
        durationMinutes: Int? = nil,
        remainingPercent: Int,
        state: QuotaFieldState = .live,
        resetAt: Date? = nil
    ) {
        self.limitId = limitId
        self.windowId = windowId
        self.kind = kind
        self.durationMinutes = durationMinutes
        self.remainingPercent = max(0, min(100, remainingPercent))
        self.state = state
        self.resetAt = resetAt
    }

    private enum CodingKeys: String, CodingKey {
        case limitId
        case windowId
        case kind
        case durationMinutes
        case remainingPercent
        case state
        case resetAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let limitId = try container.decodeIfPresent(String.self, forKey: .limitId) ?? "unknown"
        let windowId = try container.decodeIfPresent(String.self, forKey: .windowId) ?? "unknown"
        let durationMinutes = try container.decodeIfPresent(Int.self, forKey: .durationMinutes)
        let kindRaw = try container.decodeIfPresent(String.self, forKey: .kind)
        let kind = kindRaw.flatMap(QuotaWindowKind.init(rawValue:))
            ?? QuotaWindowKind.from(durationMinutes: durationMinutes)
        let rawRemaining = try container.decodeIfPresent(Int.self, forKey: .remainingPercent) ?? 0
        let state = try container.decodeIfPresent(QuotaFieldState.self, forKey: .state)
            ?? ((0...100).contains(rawRemaining) ? .live : .invalid)
        self.init(
            limitId: limitId,
            windowId: windowId,
            kind: kind,
            durationMinutes: durationMinutes,
            remainingPercent: rawRemaining,
            state: state,
            resetAt: try container.decodeIfPresent(Date.self, forKey: .resetAt)
        )
    }
}

struct ResetBankSnapshot: Codable, Equatable, Identifiable {
    let limitId: String
    let windowId: String
    let displayName: String
    let remainingPercent: Int
    let resetAt: Date?
    let resetTimeStatus: ResetBankResetTimeStatus
    let windowKind: QuotaWindowKind
    let durationMinutes: Int?

    init(
        limitId: String,
        windowId: String,
        displayName: String,
        remainingPercent: Int,
        resetAt: Date?,
        resetTimeStatus: ResetBankResetTimeStatus? = nil,
        windowKind: QuotaWindowKind? = nil,
        durationMinutes: Int? = nil
    ) {
        self.limitId = limitId
        self.windowId = windowId
        self.displayName = displayName
        self.remainingPercent = remainingPercent
        self.resetAt = resetAt
        self.resetTimeStatus = resetTimeStatus ?? (resetAt == nil ? .unexposed : .actual)
        self.windowKind = windowKind ?? Self.legacyWindowKind(limitId: limitId, windowId: windowId)
        self.durationMinutes = durationMinutes
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
        case windowKind
        case durationMinutes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let limitId = try container.decode(String.self, forKey: .limitId)
        let windowId = try container.decode(String.self, forKey: .windowId)
        let displayName = try container.decode(String.self, forKey: .displayName)
        let remainingPercent = try container.decode(Int.self, forKey: .remainingPercent)
        let resetAt = try container.decodeIfPresent(Date.self, forKey: .resetAt)
        let legacyRawFields = try container.decodeIfPresent([LegacyRawField].self, forKey: .rawResetFields) ?? []
        let resetTimeStatus = try container.decodeIfPresent(ResetBankResetTimeStatus.self, forKey: .resetTimeStatus)
            ?? (resetAt != nil ? .actual : (legacyRawFields.isEmpty ? .unexposed : .parseFailed))
        let durationMinutes = try container.decodeIfPresent(Int.self, forKey: .durationMinutes)
        let windowKindRaw = try container.decodeIfPresent(String.self, forKey: .windowKind)
        let windowKind = windowKindRaw.flatMap(QuotaWindowKind.init(rawValue:))

        self.init(
            limitId: limitId,
            windowId: windowId,
            displayName: displayName,
            remainingPercent: remainingPercent,
            resetAt: resetAt,
            resetTimeStatus: resetTimeStatus,
            windowKind: windowKind,
            durationMinutes: durationMinutes
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(limitId, forKey: .limitId)
        try container.encode(windowId, forKey: .windowId)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(remainingPercent, forKey: .remainingPercent)
        try container.encodeIfPresent(resetAt, forKey: .resetAt)
        try container.encode(resetTimeStatus, forKey: .resetTimeStatus)
        try container.encode(windowKind, forKey: .windowKind)
        try container.encodeIfPresent(durationMinutes, forKey: .durationMinutes)
    }

    private struct LegacyRawField: Decodable {}

    private static func legacyWindowKind(limitId: String, windowId: String) -> QuotaWindowKind {
        switch (limitId, windowId) {
        case ("codex", "primary"):
            return .fiveHour
        case ("codex", "secondary"), ("codex_other", "primary"):
            return .weekly
        default:
            return .unknown
        }
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
    let quotaWindows: [QuotaWindow]

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
        schemaVersion: Int = QuotaSnapshot.currentSchemaVersion,
        quotaWindows: [QuotaWindow] = []
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
        self.quotaWindows = quotaWindows
    }

    static let currentSchemaVersion = 8

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
        case quotaWindows
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
        let quotaWindows = Self.decodeQuotaWindowsLossy(from: container)

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
            schemaVersion: schemaVersion,
            quotaWindows: quotaWindows
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

        let mergedWindows = mergeQuotaWindows(with: cachedSnapshot)
        let projectedWeekly = mergedWindows.first(where: { $0.kind == .weekly && $0.state.isDisplayable })
        let projectedFiveHour = mergedWindows.first(where: { $0.kind == .fiveHour && $0.state.isDisplayable })
        let weeklyProjection = weekly.state == .live
            ? (value: weekly.value, state: weekly.state)
            : (value: projectedWeekly?.remainingPercent ?? weekly.value, state: projectedWeekly?.state ?? weekly.state)
        let fiveHourProjection = fiveHour.state == .live
            ? (value: fiveHour.value, state: fiveHour.state)
            : (value: projectedFiveHour?.remainingPercent ?? fiveHour.value, state: projectedFiveHour?.state ?? fiveHour.state)

        return QuotaSnapshot(
            weeklyQuotaPercent: weeklyProjection.value,
            fiveHourQuotaPercent: fiveHourProjection.value,
            weeklyQuotaState: weeklyProjection.state,
            fiveHourQuotaState: fiveHourProjection.state,
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
            schemaVersion: schemaVersion,
            quotaWindows: mergedWindows
        )
    }

    private func mergeQuotaWindows(with cachedSnapshot: QuotaSnapshot) -> [QuotaWindow] {
        guard !quotaWindows.isEmpty || !cachedSnapshot.quotaWindows.isEmpty else {
            return []
        }

        var merged = quotaWindows
        for index in merged.indices {
            let current = merged[index]
            guard !current.state.isCurrent,
                  let cached = cachedSnapshot.quotaWindows.first(where: {
                      $0.semanticIdentity == current.semanticIdentity && $0.state.isDisplayable
                  }) else {
                continue
            }
            merged[index] = QuotaWindow(
                limitId: current.limitId,
                windowId: current.windowId,
                kind: current.kind,
                durationMinutes: current.durationMinutes ?? cached.durationMinutes,
                remainingPercent: cached.remainingPercent,
                state: .cached,
                resetAt: current.resetAt ?? cached.resetAt
            )
        }

        let identities = Set(merged.map(\.semanticIdentity))
        for cached in cachedSnapshot.quotaWindows where cached.state.isDisplayable && !identities.contains(cached.semanticIdentity) {
            merged.append(
                QuotaWindow(
                    limitId: cached.limitId,
                    windowId: cached.windowId,
                    kind: cached.kind,
                    durationMinutes: cached.durationMinutes,
                    remainingPercent: cached.remainingPercent,
                    state: .cached,
                    resetAt: cached.resetAt
                )
            )
        }
        return merged.sorted { $0.id < $1.id }
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

    private static func decodeQuotaWindowsLossy(from container: KeyedDecodingContainer<CodingKeys>) -> [QuotaWindow] {
        guard var windowsContainer = try? container.nestedUnkeyedContainer(forKey: .quotaWindows) else {
            return []
        }

        var windows: [QuotaWindow] = []
        while !windowsContainer.isAtEnd {
            if let window = try? windowsContainer.decode(QuotaWindow.self) {
                windows.append(window)
            } else {
                _ = try? windowsContainer.decode(DiscardedDecodable.self)
            }
        }
        return windows
    }
}

private struct DiscardedDecodable: Decodable {}
