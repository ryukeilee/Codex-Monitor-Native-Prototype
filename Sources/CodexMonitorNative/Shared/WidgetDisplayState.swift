import Foundation

enum CodexMonitorWidgetConstants {
    static let kind = "CodexMonitorQuotaWidget"
    static let appGroupIdentifier = "group.com.ryukeilee.CodexMonitorNativePrototype"
    static let stateFileName = "WidgetDisplayState.json"
}

struct WidgetDisplayState: Codable, Equatable {
    let snapshot: QuotaSnapshot
    let status: QuotaRefreshStatus
    let lastSuccessAt: Date?
    let lastAttemptAt: Date?
    let effectiveFiveHourResetAt: Date?
    let resetCreditFooterLine: String?
    let savedAt: Date

    private enum CodingKeys: String, CodingKey {
        case snapshot
        case status
        case lastSuccessAt
        case lastAttemptAt
        case effectiveFiveHourResetAt
        case resetCreditFooterLine
        case savedAt
    }

    static func make(
        snapshot: QuotaSnapshot,
        status: QuotaRefreshStatus,
        lastSuccessAt: Date?,
        lastAttemptAt: Date?,
        effectiveFiveHourResetAt: Date?,
        resetCreditFooterLine: String? = nil,
        savedAt: Date = .now
    ) -> WidgetDisplayState {
        WidgetDisplayState(
            snapshot: snapshot,
            status: status,
            lastSuccessAt: lastSuccessAt,
            lastAttemptAt: lastAttemptAt,
            effectiveFiveHourResetAt: effectiveFiveHourResetAt,
            resetCreditFooterLine: resetCreditFooterLine ?? Self.makeResetCreditFooterLine(for: snapshot),
            savedAt: savedAt
        )
    }

    init(
        snapshot: QuotaSnapshot,
        status: QuotaRefreshStatus,
        lastSuccessAt: Date?,
        lastAttemptAt: Date?,
        effectiveFiveHourResetAt: Date?,
        resetCreditFooterLine: String?,
        savedAt: Date
    ) {
        self.snapshot = snapshot
        self.status = status
        self.lastSuccessAt = lastSuccessAt
        self.lastAttemptAt = lastAttemptAt
        self.effectiveFiveHourResetAt = effectiveFiveHourResetAt
        self.resetCreditFooterLine = resetCreditFooterLine
        self.savedAt = savedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let snapshot = try container.decode(QuotaSnapshot.self, forKey: .snapshot)
        self.init(
            snapshot: snapshot,
            status: try container.decode(QuotaRefreshStatus.self, forKey: .status),
            lastSuccessAt: try container.decodeIfPresent(Date.self, forKey: .lastSuccessAt),
            lastAttemptAt: try container.decodeIfPresent(Date.self, forKey: .lastAttemptAt),
            effectiveFiveHourResetAt: try container.decodeIfPresent(Date.self, forKey: .effectiveFiveHourResetAt),
            resetCreditFooterLine: try container.decodeIfPresent(String.self, forKey: .resetCreditFooterLine) ?? Self.makeResetCreditFooterLine(for: snapshot),
            savedAt: try container.decode(Date.self, forKey: .savedAt)
        )
    }

    static let placeholder = WidgetDisplayState(
        snapshot: .notConnected,
        status: .noSnapshot,
        lastSuccessAt: nil,
        lastAttemptAt: nil,
        effectiveFiveHourResetAt: nil,
        resetCreditFooterLine: nil,
        savedAt: .now
    )

    var statusText: String {
        StatusPopoverFormatting.titleSummary(for: status)
    }

    var fiveHourQuotaText: String {
        StatusPopoverFormatting.quotaValueText(for: .fiveHour, snapshot: snapshot, status: status)
    }

    var weeklyQuotaText: String {
        StatusPopoverFormatting.quotaValueText(for: .weekly, snapshot: snapshot, status: status)
    }

    func recoveryDetails(now: Date = .now) -> StatusPopoverFormatting.RecoveryDetails {
        StatusPopoverFormatting.recoveryDetails(
            resetAt: effectiveFiveHourResetAt,
            status: status,
            now: now
        )
    }

    func updatedLine(now: Date = .now) -> String {
        StatusPopoverFormatting.updatedLine(
            lastSuccess: lastSuccessAt ?? snapshot.refreshedAt,
            lastAttempt: lastAttemptAt,
            now: now
        )
    }

    var earliestResetCreditExpiresAt: Date? {
        snapshot.resetCreditDetails
            .filter { normalizedResetCreditStatus($0.status) == "available" }
            .compactMap(\.expiresAt)
            .min()
    }

    private func normalizedResetCreditStatus(_ status: String) -> String {
        status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var resetCreditFooterText: String? {
        resetCreditFooterLine ?? earliestResetCreditLine()
    }

    func earliestResetCreditLine(
        locale: Locale = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> String? {
        guard let earliestResetCreditExpiresAt else {
            return nil
        }

        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateFormat = "M/d HH:mm"
        return "最早重置 \(formatter.string(from: earliestResetCreditExpiresAt))"
    }

    private static func makeResetCreditFooterLine(for snapshot: QuotaSnapshot) -> String? {
        let earliestExpiry = snapshot.resetCreditDetails
            .filter { $0.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "available" }
            .compactMap(\.expiresAt)
            .min()

        guard let earliestExpiry else {
            return nil
        }

        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "M/d HH:mm"
        return "最早重置 \(formatter.string(from: earliestExpiry))"
    }

    func isEquivalent(to other: WidgetDisplayState) -> Bool {
        snapshot == other.snapshot &&
        status == other.status &&
        lastSuccessAt == other.lastSuccessAt &&
        lastAttemptAt == other.lastAttemptAt &&
        effectiveFiveHourResetAt == other.effectiveFiveHourResetAt &&
        resetCreditFooterLine == other.resetCreditFooterLine
    }
}

enum WidgetDisplayStateStore {
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    static func load(fileManager: FileManager = .default) -> WidgetDisplayState {
        let url = stateURL(fileManager: fileManager)

        guard let data = try? Data(contentsOf: url),
              let state = try? decoder.decode(WidgetDisplayState.self, from: data) else {
            return .placeholder
        }

        return state
    }

    static func save(_ state: WidgetDisplayState, fileManager: FileManager = .default) {
        let url = stateURL(fileManager: fileManager)

        do {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try encoder.encode(state)
            try data.write(to: url, options: .atomic)
        } catch {
            // Widget state is best-effort; the menu bar app must keep working if this write fails.
        }
    }

    static func stateURL(fileManager: FileManager = .default) -> URL {
        if let groupURL = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: CodexMonitorWidgetConstants.appGroupIdentifier
        ) {
            return groupURL.appendingPathComponent(CodexMonitorWidgetConstants.stateFileName)
        }

        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let baseURL = appSupport ?? fileManager.temporaryDirectory
        return baseURL
            .appendingPathComponent("CodexMonitorNative", isDirectory: true)
            .appendingPathComponent(CodexMonitorWidgetConstants.stateFileName)
    }
}
