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
    let savedAt: Date

    static func make(
        snapshot: QuotaSnapshot,
        status: QuotaRefreshStatus,
        lastSuccessAt: Date?,
        lastAttemptAt: Date?,
        effectiveFiveHourResetAt: Date?,
        savedAt: Date = .now
    ) -> WidgetDisplayState {
        WidgetDisplayState(
            snapshot: snapshot,
            status: status,
            lastSuccessAt: lastSuccessAt,
            lastAttemptAt: lastAttemptAt,
            effectiveFiveHourResetAt: effectiveFiveHourResetAt,
            savedAt: savedAt
        )
    }

    static let placeholder = WidgetDisplayState(
        snapshot: .notConnected,
        status: .noSnapshot,
        lastSuccessAt: nil,
        lastAttemptAt: nil,
        effectiveFiveHourResetAt: nil,
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
