import Foundation

struct StatusSelfCheckSnapshot: Equatable {
    let version: String
    let installPath: String
    let refreshSummary: String
    let widgetSummary: String

    @MainActor
    static func capture(
        appState: AppState,
        bundle: Bundle = .main,
        fileManager: FileManager = .default,
        now: Date = .now,
        calendar: Calendar = .current,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> StatusSelfCheckSnapshot {
        let widgetStateURL = WidgetDisplayStateStore.stateURL(fileManager: fileManager)
        let widgetStateExists = fileManager.fileExists(atPath: widgetStateURL.path)
        let widgetState = widgetStateExists ? WidgetDisplayStateStore.load(fileManager: fileManager) : nil

        let refreshSummary = formattedRefreshSummary(
            lastSuccess: appState.lastSuccessAt,
            lastAttempt: appState.lastAttemptAt,
            now: now,
            calendar: calendar,
            locale: locale,
            timeZone: timeZone
        )

        return StatusSelfCheckSnapshot(
            version: formattedVersion(bundle: bundle),
            installPath: bundle.bundleURL.resolvingSymlinksInPath().path,
            refreshSummary: refreshSummary,
            widgetSummary: formattedWidgetSummary(
                state: widgetState,
                hasStateFile: widgetStateExists,
                now: now,
                calendar: calendar,
                locale: locale,
                timeZone: timeZone
            )
        )
    }

    static func formattedVersion(bundle: Bundle) -> String {
        let shortVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let buildVersion = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String

        switch (normalized(shortVersion), normalized(buildVersion)) {
        case let (short?, build?) where short != build:
            return "\(short) (\(build))"
        case let (short?, _):
            return short
        case let (_, build?):
            return build
        default:
            return "未写入"
        }
    }

    static func formattedRefreshSummary(
        lastSuccess: Date?,
        lastAttempt: Date?,
        now: Date = .now,
        calendar: Calendar = .current,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String {
        let line = StatusPopoverFormatting.updatedLine(
            lastSuccess: lastSuccess,
            lastAttempt: lastAttempt,
            now: now,
            calendar: calendar,
            locale: locale,
            timeZone: timeZone
        )

        return line == "更新 --" ? "未刷新" : line
    }

    static func formattedWidgetSummary(
        state: WidgetDisplayState?,
        hasStateFile: Bool,
        now: Date = .now,
        calendar: Calendar = .current,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String {
        guard hasStateFile, let state else {
            return "未写入"
        }

        let savedAt = StatusPopoverFormatting.shortTimestamp(
            for: state.savedAt,
            now: now,
            calendar: calendar,
            locale: locale,
            timeZone: timeZone
        )
        return "\(state.statusText) · 保存 \(savedAt)"
    }

    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }

        return trimmed
    }
}
