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
            return "Updated \(successText)"
        }

        if lastSuccess == nil && lastAttempt == nil {
            return "Updated --"
        }

        if lastSuccess == nil {
            return "Updated \(attemptText)"
        }

        if lastAttempt == nil {
            return "Updated \(successText)"
        }

        return "Updated \(successText) · Attempted \(attemptText)"
    }

    static func titleSummary(for status: QuotaRefreshStatus) -> String {
        switch status {
        case .success:
            return "Quota is fresh"
        case .refreshing:
            return "Updating quota"
        case .stale:
            return "Quota data is stale"
        case .networkFailed, .authRequired, .parseFailed:
            return "Last refresh failed"
        case .noSnapshot:
            return "Waiting for first sync"
        case .demoMode:
            return "Demo data loaded"
        case .idle:
            return "Safe to continue"
        }
    }

    static func sourceStatusLine(dataSource: QuotaDataSource, status: QuotaRefreshStatus) -> String {
        "\(sourceLabel(for: dataSource)) · \(statusLabel(for: status))"
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
            return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
        }

        if minutes > 0 {
            return "\(minutes)m"
        }

        return "<1m"
    }

    private static func sourceLabel(for dataSource: QuotaDataSource) -> String {
        switch dataSource {
        case .real:
            return "Real data"
        case .mock:
            return "Demo data"
        }
    }

    private static func statusLabel(for status: QuotaRefreshStatus) -> String {
        switch status {
        case .success:
            return "Fresh"
        case .refreshing:
            return "Updating"
        case .stale:
            return "Stale"
        case .networkFailed:
            return "Failed"
        case .authRequired:
            return "Failed"
        case .parseFailed:
            return "Failed"
        case .noSnapshot:
            return "Not connected"
        case .demoMode:
            return "Demo mode"
        case .idle:
            return "Idle"
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
        locale.identifier.lowercased().hasPrefix("zh") ? "今天" : "Today"
    }
}
