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
            return "Quota looks healthy"
        case .refreshing:
            return "Refreshing quota"
        case .networkFailed, .authRequired, .parseFailed:
            return "Refresh failed"
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
            return "Connected"
        case .refreshing:
            return "Refreshing"
        case .networkFailed:
            return "Network failed"
        case .authRequired:
            return "Auth required"
        case .parseFailed:
            return "Parse failed"
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
