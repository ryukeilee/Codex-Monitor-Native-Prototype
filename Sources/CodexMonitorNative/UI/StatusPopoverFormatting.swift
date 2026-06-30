import Foundation

enum StatusPopoverFormatting {
    enum QuotaMetric {
        case fiveHour
        case weekly
    }

    struct RecoveryDetails: Equatable {
        let resetText: String
        let remainingText: String
    }

    static func shortTimestamp(
        for date: Date,
        now: Date = .now,
        calendar: Calendar = .current,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String {
        let timeText = timeString(for: date, locale: locale, timeZone: timeZone)

        if calendar.isDate(date, inSameDayAs: now) {
            return "\(todayLabel(for: locale)) \(timeText)"
        }

        let dateFormatter = DateFormatter()
        dateFormatter.locale = locale
        dateFormatter.timeZone = timeZone
        dateFormatter.dateFormat = "M月d日 HH:mm"
        return dateFormatter.string(from: date)
    }

    static func updatedLine(
        lastSuccess: Date?,
        lastAttempt: Date?,
        now: Date = .now,
        calendar: Calendar = .current,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String {
        let successText = lastSuccess.map {
            shortTimestamp(for: $0, now: now, calendar: calendar, locale: locale, timeZone: timeZone)
        } ?? "--"
        let attemptText = lastAttempt.map {
            shortTimestamp(for: $0, now: now, calendar: calendar, locale: locale, timeZone: timeZone)
        } ?? "--"

        if successText == attemptText {
            return "更新 \(successText)"
        }

        if lastSuccess == nil && lastAttempt == nil {
            return "更新 --"
        }

        if lastSuccess == nil {
            return "更新 \(attemptText)"
        }

        if lastAttempt == nil {
            return "更新 \(successText)"
        }

        return "更新 \(successText) · 尝试 \(attemptText)"
    }

    static func titleSummary(for status: QuotaRefreshStatus) -> String {
        switch status {
        case .success:
            return "已更新"
        case .refreshing:
            return "正在刷新"
        case .stale:
            return "数据过期"
        case .networkFailed:
            return "网络异常"
        case .authRequired:
            return "需要登录"
        case .parseFailed:
            return "数据异常"
        case .noSnapshot:
            return "等待同步"
        case .demoMode:
            return "演示数据"
        case .idle:
            return "等待刷新"
        }
    }

    static func sourceStatusLine(dataSource: QuotaDataSource, status: QuotaRefreshStatus) -> String {
        "\(sourceLabel(for: dataSource)) · \(statusLabel(for: status))"
    }

    static func credibilityLine(
        lastSuccess: Date?,
        lastAttempt: Date?,
        dataSource: QuotaDataSource,
        status: QuotaRefreshStatus,
        now: Date = .now,
        calendar: Calendar = .current,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String {
        let updated = updatedLine(
            lastSuccess: lastSuccess,
            lastAttempt: lastAttempt,
            now: now,
            calendar: calendar,
            locale: locale,
            timeZone: timeZone
        )
        let sourceStatus = sourceStatusLine(dataSource: dataSource, status: status)
        return "\(updated) · \(sourceStatus)"
    }

    static func environmentInfoLine(
        lastSuccess: Date?,
        lastAttempt: Date?,
        dataSource: QuotaDataSource,
        status: QuotaRefreshStatus,
        showsSourceStatus: Bool,
        now: Date = .now,
        calendar: Calendar = .current,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String? {
        let updated = updatedLine(
            lastSuccess: lastSuccess,
            lastAttempt: lastAttempt,
            now: now,
            calendar: calendar,
            locale: locale,
            timeZone: timeZone
        )

        guard showsSourceStatus else {
            return updated == "更新 --" ? nil : updated
        }

        let sourceStatus = sourceStatusLine(dataSource: dataSource, status: status)
        return "\(updated) · \(sourceStatus)"
    }

    static func realQuotaHealthLine(_ diagnostic: RealQuotaHealthDiagnostic) -> String {
        let suffix = fallbackSuffix(isUsingCachedSnapshot: diagnostic.isUsingCachedSnapshot)

        switch diagnostic.kind {
        case .waitingForFirstRequest:
            return diagnostic.isUsingCachedSnapshot
                ? "真实链路：尚未发起请求，显示上次成功数据"
                : "真实链路：等待首次真实请求"
        case .requestInProgress:
            return diagnostic.isUsingCachedSnapshot
                ? "真实链路：正在请求 Codex，暂时显示上次成功数据"
                : "真实链路：正在请求 Codex"
        case .requestSucceeded:
            return "真实链路：Codex 可用，请求成功"
        case .executableMissing:
            return "真实链路：未找到 codex 可执行文件\(suffix)"
        case .codexUnavailable:
            return "真实链路：Codex 不可用\(suffix)"
        case .requestTimedOut:
            return "真实链路：请求超时\(suffix)"
        case .loginRequired:
            return "真实链路：需要登录\(suffix)"
        case .responseInvalid:
            return "真实链路：响应不可解析\(suffix)"
        case .rpcRejected:
            return "真实链路：RPC 请求失败\(suffix)"
        }
    }

    static func relativeRecoveryLine(
        for date: Date?,
        now: Date = .now
    ) -> String {
        guard let date else {
            return "--"
        }

        let remaining = Int(date.timeIntervalSince(now).rounded())
        if remaining <= 0 {
            return "已恢复"
        }

        let hours = remaining / 3600
        let minutes = (remaining % 3600) / 60

        if hours > 0 {
            return minutes > 0 ? "\(hours)小时\(minutes)分" : "\(hours)小时"
        }

        if minutes > 0 {
            return "\(minutes)分"
        }

        return "少于1分"
    }

    static func quotaSummaryLine(
        snapshot: QuotaSnapshot,
        status: QuotaRefreshStatus
    ) -> String {
        "5小时额度 \(quotaValueText(for: .fiveHour, snapshot: snapshot, status: status)) · 周额度 \(quotaValueText(for: .weekly, snapshot: snapshot, status: status))"
    }

    static func quotaValueText(
        for metric: QuotaMetric,
        snapshot: QuotaSnapshot,
        status: QuotaRefreshStatus
    ) -> String {
        quotaText(for: metric, snapshot: snapshot, status: status)
    }

    static func recoverySummaryLine(
        resetAt: Date?,
        status: QuotaRefreshStatus,
        now: Date = .now,
        calendar: Calendar = .current,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String {
        let details = recoveryDetails(
            resetAt: resetAt,
            status: status,
            now: now,
            calendar: calendar,
            locale: locale,
            timeZone: timeZone
        )
        return "恢复 \(details.resetText) · 还需 \(details.remainingText)"
    }

    static func recoveryDetails(
        resetAt: Date?,
        status: QuotaRefreshStatus,
        now: Date = .now,
        calendar: Calendar = .current,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> RecoveryDetails {
        guard showsQuotaValues(for: status), let resetAt else {
            return RecoveryDetails(resetText: "--", remainingText: "--")
        }

        let resetText = shortTimestamp(
            for: resetAt,
            now: now,
            calendar: calendar,
            locale: locale,
            timeZone: timeZone
        )
        let remainingText = relativeRecoveryLine(for: resetAt, now: now)
        return RecoveryDetails(resetText: resetText, remainingText: remainingText)
    }

    static func quotaTooltip(
        snapshot: QuotaSnapshot,
        status: QuotaRefreshStatus,
        resetAt: Date? = nil,
        now: Date = .now,
        calendar: Calendar = .current,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String {
        let recovery = recoverySummaryLine(
            resetAt: resetAt,
            status: status,
            now: now,
            calendar: calendar,
            locale: locale,
            timeZone: timeZone
        )

        switch status {
        case .success:
            return "Codex Monitor：\(quotaSummaryLine(snapshot: snapshot, status: status)) · \(recovery)"
        case .refreshing:
            return "Codex Monitor：\(quotaSummaryLine(snapshot: snapshot, status: status)) · \(recovery) · 正在刷新"
        case .networkFailed:
            return "Codex Monitor：\(quotaSummaryLine(snapshot: snapshot, status: status)) · \(recovery) · 网络异常，显示上次数据"
        case .authRequired:
            return "Codex Monitor：\(quotaSummaryLine(snapshot: snapshot, status: status)) · \(recovery) · 需要登录，显示上次数据"
        case .parseFailed:
            return "Codex Monitor：\(quotaSummaryLine(snapshot: snapshot, status: status)) · \(recovery) · 数据异常，显示上次数据"
        case .stale:
            return "Codex Monitor：\(quotaSummaryLine(snapshot: snapshot, status: status)) · \(recovery) · 数据已过期"
        case .noSnapshot:
            return "Codex Monitor：等待连接"
        case .idle:
            return "Codex Monitor：等待首次刷新"
        case .demoMode:
            return "Codex Monitor：演示模式"
        }
    }

    private static func sourceLabel(for dataSource: QuotaDataSource) -> String {
        switch dataSource {
        case .real:
            return "真实数据"
        case .mock:
            return "演示数据"
        }
    }

    private static func quotaText(
        for metric: QuotaMetric,
        snapshot: QuotaSnapshot,
        status: QuotaRefreshStatus
    ) -> String {
        guard showsQuotaValues(for: status) else {
            switch status {
            case .demoMode:
                return "演示"
            case .success, .stale, .refreshing, .networkFailed, .authRequired, .parseFailed, .noSnapshot, .idle:
                return "--"
            }
        }

        guard snapshot.dataSource == .real else {
            return "--"
        }

        switch metric {
        case .fiveHour:
            return "\(snapshot.fiveHourQuotaPercent)%"
        case .weekly:
            return "\(snapshot.weeklyQuotaPercent)%"
        }
    }

    private static func showsQuotaValues(for status: QuotaRefreshStatus) -> Bool {
        switch status {
        case .success, .stale, .refreshing, .networkFailed, .authRequired, .parseFailed:
            return true
        case .noSnapshot, .idle, .demoMode:
            return false
        }
    }

    private static func statusLabel(for status: QuotaRefreshStatus) -> String {
        switch status {
        case .success:
            return "最新"
        case .refreshing:
            return "更新中"
        case .stale:
            return "已过期"
        case .networkFailed:
            return "网络异常"
        case .authRequired:
            return "需要登录"
        case .parseFailed:
            return "数据异常"
        case .noSnapshot:
            return "未连接"
        case .demoMode:
            return "演示模式"
        case .idle:
            return "空闲"
        }
    }

    private static func timeString(
        for date: Date,
        locale: Locale,
        timeZone: TimeZone
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    private static func todayLabel(for locale: Locale) -> String {
        _ = locale
        return "今天"
    }

    private static func fallbackSuffix(isUsingCachedSnapshot: Bool) -> String {
        isUsingCachedSnapshot ? "，显示上次成功数据" : "，当前无可用快照"
    }
}
