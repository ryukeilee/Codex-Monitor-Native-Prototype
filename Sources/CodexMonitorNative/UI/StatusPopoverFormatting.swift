import Foundation

enum StatusPopoverFormatting {
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
            return "数据已更新"
        case .refreshing:
            return "正在更新"
        case .stale:
            return "数据已过期"
        case .networkFailed, .authRequired, .parseFailed:
            return "上次刷新失败"
        case .noSnapshot:
            return "等待首次同步"
        case .demoMode:
            return "演示数据"
        case .idle:
            return "可继续"
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

    private static func sourceLabel(for dataSource: QuotaDataSource) -> String {
        switch dataSource {
        case .real:
            return "真实数据"
        case .mock:
            return "演示数据"
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
}
