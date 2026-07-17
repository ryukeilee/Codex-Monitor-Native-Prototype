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

    struct QuotaValueDisplay: Equatable {
        let percentText: String
        let historyCaption: String?

        var combinedText: String {
            guard let historyCaption else { return percentText }
            return "\(percentText)\(historyCaption)"
        }
    }

    /// The single presentation contract consumed by the popover, status-item
    /// tooltip, and Widget. A trusted number and its progress always travel
    /// together, while cache provenance remains separate from the number.
    struct QuotaWindowDisplayItem: Equatable, Identifiable {
        enum Origin: Equatable {
            case dynamic
            case legacyFallback
        }

        let id: String
        let semanticIdentity: String
        let kind: QuotaWindowKind
        let label: String
        let percentText: String
        let historyCaption: String?
        let trustedPercent: Int?
        let progress: Double?
        let fieldState: QuotaFieldState
        let stateText: String
        let resetAt: Date?
        let resetText: String
        let resetRemainingText: String
        let origin: Origin

        var combinedPercentText: String {
            guard let historyCaption else { return percentText }
            return "\(percentText)\(historyCaption)"
        }
    }

    struct QuotaWindowLayoutSignal: Equatable {
        let itemTokens: [String]
        let rowCount: Int
        let requiresScrolling: Bool
    }

    struct QuotaWindowSelection: Equatable {
        let visibleItems: [QuotaWindowDisplayItem]
        let overflowCount: Int

        var primaryItem: QuotaWindowDisplayItem? {
            visibleItems.first
        }
    }

    struct ResetBankDisplayItem: Equatable, Identifiable {
        let id: String
        let resetText: String
        let remainingText: String
        let sourceText: String?
        let detailText: String?
    }

    struct ResetCreditTimeDisplayItem: Equatable, Identifiable {
        let id: String
        let label: String
        let resetText: String
        let remainingText: String
        let sourceText: String
    }

    struct ResetCreditDisplayItem: Equatable, Identifiable {
        let id: String
        let expiryText: String
        let remainingText: String
        let grantedText: String?
    }

    struct ResetCreditsSummary: Equatable {
        let countLine: String
        let timingLine: String?
        let featuredCreditItem: ResetCreditDisplayItem?
        let additionalCreditItems: [ResetCreditDisplayItem]
        let detailLines: [String]
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
            return "最新数据"
        case .refreshing:
            return "读取中"
        case .stale:
            return "使用上次数据"
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

    static func freshnessTitle(for status: QuotaRefreshStatus, isUsingCachedSnapshot: Bool) -> String {
        switch status {
        case .success:
            return "最新数据"
        case .refreshing:
            return "读取中"
        case .stale:
            return "使用上次数据"
        case .networkFailed, .authRequired, .parseFailed:
            return isUsingCachedSnapshot ? "使用上次数据" : "读取失败"
        case .noSnapshot:
            return "等待同步"
        case .demoMode:
            return "演示数据"
        case .idle:
            return "等待刷新"
        }
    }

    static func freshnessSummary(for status: QuotaRefreshStatus, isUsingCachedSnapshot: Bool) -> String? {
        switch status {
        case .success, .stale:
            return nil
        case .refreshing:
            return isUsingCachedSnapshot
                ? "读取中，暂用上次快照"
                : "读取中"
        case .networkFailed:
            return isUsingCachedSnapshot ? "读取失败，显示上次快照" : "读取失败，无可用快照"
        case .authRequired:
            return isUsingCachedSnapshot ? "需要登录，显示上次快照" : "需要登录，无可用快照"
        case .parseFailed:
            return isUsingCachedSnapshot ? "响应异常，显示上次快照" : "响应异常，无可用快照"
        case .noSnapshot:
            return "尚未读取到真实数据"
        case .idle, .demoMode:
            return nil
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
        status: QuotaRefreshStatus,
        now: Date = .now,
        calendar: Calendar = .current,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String {
        let items = quotaWindowDisplayItems(
            snapshot: snapshot,
            status: status,
            now: now,
            calendar: calendar,
            locale: locale,
            timeZone: timeZone
        )
        guard !items.isEmpty else {
            return "额度 --"
        }

        return items
            .map { "\($0.label) \($0.combinedPercentText)" }
            .joined(separator: " · ")
    }

    static func quotaWindowDisplayItems(
        snapshot: QuotaSnapshot,
        status: QuotaRefreshStatus,
        now: Date = .now,
        calendar: Calendar = .current,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> [QuotaWindowDisplayItem] {
        guard snapshot.dataSource == .real, showsQuotaValues(for: status) else {
            return []
        }

        let dynamicWindows = preferredCurrentQuotaWindows(from: snapshot.quotaWindows)
        var candidates: [(window: QuotaWindow, origin: QuotaWindowDisplayItem.Origin)] = dynamicWindows.map {
            ($0, .dynamic)
        }

        if !dynamicWindows.contains(where: { $0.kind == .fiveHour }),
           snapshot.fiveHourQuotaState.isCurrent {
            candidates.append((
                QuotaWindow(
                    limitId: "legacy",
                    windowId: "fiveHour",
                    kind: .fiveHour,
                    durationMinutes: 300,
                    remainingPercent: snapshot.fiveHourQuotaPercent,
                    state: snapshot.fiveHourQuotaState,
                    resetAt: snapshot.fiveHourResetAt
                ),
                .legacyFallback
            ))
        }

        if !dynamicWindows.contains(where: { $0.kind == .weekly }),
           snapshot.weeklyQuotaState.isCurrent {
            candidates.append((
                QuotaWindow(
                    limitId: "legacy",
                    windowId: "weekly",
                    kind: .weekly,
                    durationMinutes: 10_080,
                    remainingPercent: snapshot.weeklyQuotaPercent,
                    state: snapshot.weeklyQuotaState,
                    resetAt: nil
                ),
                .legacyFallback
            ))
        }

        candidates.sort { compareQuotaWindowDisplayOrder($0.window, $1.window) }

        return candidates.enumerated().map { index, candidate in
            let sameKind = candidates.filter { $0.window.kind == candidate.window.kind }
            let ordinal = candidates[..<index].filter { $0.window.kind == candidate.window.kind }.count + 1
            let label = quotaWindowLabel(
                for: candidate.window,
                ordinal: ordinal,
                count: sameKind.count
            )
            return makeQuotaWindowDisplayItem(
                window: candidate.window,
                label: label,
                origin: candidate.origin,
                dataSource: snapshot.dataSource,
                status: status,
                now: now,
                calendar: calendar,
                locale: locale,
                timeZone: timeZone
            )
        }
    }

    /// Keep only current, trustworthy windows. Known quota kinds represent one
    /// semantic meter, so prefer the canonical server source instead of
    /// rendering duplicate cards from fallback buckets.
    private static func preferredCurrentQuotaWindows(from windows: [QuotaWindow]) -> [QuotaWindow] {
        let currentWindows = windows.filter { $0.state.isCurrent }
        let knownKinds: [QuotaWindowKind] = [.fiveHour, .weekly, .monthly]
        let selected = knownKinds.compactMap { kind in
            preferredCurrentQuotaWindow(
                kind: kind,
                from: currentWindows.filter { $0.kind == kind }
            )
        }
        return selected.sorted(by: compareQuotaWindowDisplayOrder)
    }

    private static func preferredCurrentQuotaWindow(
        kind: QuotaWindowKind,
        from windows: [QuotaWindow]
    ) -> QuotaWindow? {
        let canonicalIdentity: (limitId: String, windowId: String)?
        switch kind {
        case .fiveHour:
            canonicalIdentity = ("codex", "primary")
        case .weekly:
            canonicalIdentity = ("codex", "secondary")
        case .monthly, .unknown:
            canonicalIdentity = nil
        }

        if let canonicalIdentity,
           let canonical = windows.first(where: {
               $0.limitId == canonicalIdentity.limitId && $0.windowId == canonicalIdentity.windowId
           }) {
            return canonical
        }
        return windows.sorted(by: compareQuotaWindowDisplayOrder).first
    }

    static func quotaWindowLayoutSignal(
        snapshot: QuotaSnapshot,
        status: QuotaRefreshStatus,
        columns: Int = 2
    ) -> QuotaWindowLayoutSignal {
        let safeColumns = max(1, columns)
        let items = quotaWindowDisplayItems(snapshot: snapshot, status: status)
        let rowCount = (items.count + safeColumns - 1) / safeColumns
        return QuotaWindowLayoutSignal(
            itemTokens: items.map {
                "\($0.id)|\($0.label)|\($0.historyCaption == nil ? "current" : "cached")"
            },
            rowCount: rowCount,
            requiresScrolling: rowCount > 2
        )
    }

    static func quotaWindowSelection(
        snapshot: QuotaSnapshot,
        status: QuotaRefreshStatus,
        capacity: Int,
        now: Date = .now,
        calendar: Calendar = .current,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> QuotaWindowSelection {
        guard capacity > 0 else {
            return QuotaWindowSelection(visibleItems: [], overflowCount: quotaWindowDisplayItems(
                snapshot: snapshot,
                status: status,
                now: now,
                calendar: calendar,
                locale: locale,
                timeZone: timeZone
            ).count)
        }

        let items = quotaWindowDisplayItems(
            snapshot: snapshot,
            status: status,
            now: now,
            calendar: calendar,
            locale: locale,
            timeZone: timeZone
        )
        guard !items.isEmpty else {
            return QuotaWindowSelection(visibleItems: [], overflowCount: 0)
        }
        let primaryIndex = items.firstIndex(where: { $0.trustedPercent != nil }) ?? items.startIndex

        let primary = items[primaryIndex]
        let selectionOrder = [primary] + items.enumerated().compactMap { index, item in
            index == primaryIndex ? nil : item
        }
        let visibleItems = Array(selectionOrder.prefix(capacity))
        return QuotaWindowSelection(
            visibleItems: visibleItems,
            overflowCount: max(0, selectionOrder.count - visibleItems.count)
        )
    }

    static func weeklyQuotaMenuTitle(
        snapshot: QuotaSnapshot,
        status: QuotaRefreshStatus
    ) -> String {
        guard snapshot.dataSource == .real else { return "--%" }
        let weeklyItem = quotaWindowDisplayItems(snapshot: snapshot, status: status)
            .first { $0.kind == .weekly && $0.trustedPercent != nil }
        return weeklyItem?.percentText ?? "--%"
    }

    static func quotaValueText(
        for metric: QuotaMetric,
        snapshot: QuotaSnapshot,
        status: QuotaRefreshStatus
    ) -> String {
        quotaText(for: metric, snapshot: snapshot, status: status)
    }

    /// Returns the numeric value and its historical marker separately so UI
    /// layouts cannot truncate the percentage while trying to fit a caption.
    static func quotaValueDisplay(
        for metric: QuotaMetric,
        snapshot: QuotaSnapshot,
        status: QuotaRefreshStatus
    ) -> QuotaValueDisplay {
        quotaDisplay(for: metric, snapshot: snapshot, status: status)
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
        guard showsQuotaValues(for: status) else {
            return RecoveryDetails(resetText: "--", remainingText: "--")
        }

        guard let resetAt else {
            return RecoveryDetails(resetText: "未知（未暴露）", remainingText: "未暴露")
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

    static func resetBankDisplayItems(
        snapshot: QuotaSnapshot,
        status: QuotaRefreshStatus,
        now: Date = .now,
        calendar: Calendar = .current,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> [ResetBankDisplayItem] {
        guard showsQuotaValues(for: status), snapshot.dataSource == .real else {
            return []
        }

        return snapshot.resetBanks
            .sorted(by: compareResetBankDisplayOrder)
            .prefix(3)
            .map { bank in
            let details = recoveryDetails(
                resetAt: bank.resetAt,
                status: status,
                now: now,
                calendar: calendar,
                locale: locale,
                timeZone: timeZone
            )

            return ResetBankDisplayItem(
                id: bank.id,
                resetText: details.resetText,
                remainingText: details.remainingText,
                sourceText: nil,
                detailText: bankDetailText(for: bank)
            )
        }
    }

    static func resetCreditTimeDisplayItems(
        snapshot: QuotaSnapshot,
        status: QuotaRefreshStatus,
        now: Date = .now,
        calendar: Calendar = .current,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> [ResetCreditTimeDisplayItem] {
        guard showsQuotaValues(for: status), snapshot.dataSource == .real else {
            return []
        }

        return snapshot.resetCreditTimeEntries.map { entry in
            let details = recoveryDetails(
                resetAt: entry.date,
                status: status,
                now: now,
                calendar: calendar,
                locale: locale,
                timeZone: timeZone
            )

            return ResetCreditTimeDisplayItem(
                id: entry.id,
                label: entry.label,
                resetText: details.resetText,
                remainingText: details.remainingText,
                sourceText: "来源：\(entry.sourcePath)"
            )
        }
    }

    static func resetCreditsSummary(
        snapshot: QuotaSnapshot,
        status: QuotaRefreshStatus,
        now: Date = .now,
        calendar: Calendar = .current,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> ResetCreditsSummary? {
        guard showsQuotaValues(for: status), snapshot.dataSource == .real else {
            return nil
        }

        let countLine: String
        if let count = snapshot.resetAvailableCount {
            countLine = "重置次数 \(count)"
        } else {
            countLine = "重置次数未知"
        }

        let creditItems = resetCreditDisplayItems(
            snapshot: snapshot,
            status: status,
            now: now,
            calendar: calendar,
            locale: locale,
            timeZone: timeZone
        )
        let timingLine = resetCreditTimingLine(
            snapshot: snapshot,
            creditItems: creditItems
        )
        let detailLines = resetCreditDetailLines(
            snapshot: snapshot,
            hasDisplayableCreditItems: !creditItems.isEmpty
        )

        return ResetCreditsSummary(
            countLine: countLine,
            timingLine: timingLine,
            featuredCreditItem: creditItems.first,
            additionalCreditItems: Array(creditItems.dropFirst()),
            detailLines: detailLines
        )
    }

    static func quotaTooltip(
        snapshot: QuotaSnapshot,
        status: QuotaRefreshStatus,
        now: Date = .now,
        calendar: Calendar = .current,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String {
        let summary = quotaSummaryLine(
            snapshot: snapshot,
            status: status,
            now: now,
            calendar: calendar,
            locale: locale,
            timeZone: timeZone
        )
        let selection = quotaWindowSelection(
            snapshot: snapshot,
            status: status,
            capacity: 1,
            now: now,
            calendar: calendar,
            locale: locale,
            timeZone: timeZone
        )
        let recovery = selection.primaryItem.flatMap { item -> String? in
            guard item.trustedPercent != nil else { return nil }
            return "\(item.label)恢复 \(item.resetText) · 还需 \(item.resetRemainingText)"
        }
        let detail = [summary, recovery].compactMap { $0 }.joined(separator: " · ")

        switch status {
        case .success:
            return "Codex Monitor：\(detail)"
        case .refreshing:
            return "Codex Monitor：\(detail) · 正在刷新"
        case .networkFailed:
            return "Codex Monitor：\(detail) · 网络异常，显示上次数据"
        case .authRequired:
            return "Codex Monitor：\(detail) · 需要登录，显示上次数据"
        case .parseFailed:
            return "Codex Monitor：\(detail) · 数据异常，显示上次数据"
        case .stale:
            return "Codex Monitor：\(detail) · 数据已过期"
        case .noSnapshot:
            return "Codex Monitor：等待连接"
        case .idle:
            return "Codex Monitor：等待首次刷新"
        case .demoMode:
            return "Codex Monitor：演示模式"
        }
    }

    private static func makeQuotaWindowDisplayItem(
        window: QuotaWindow,
        label: String,
        origin: QuotaWindowDisplayItem.Origin,
        dataSource: QuotaDataSource,
        status: QuotaRefreshStatus,
        now: Date,
        calendar: Calendar,
        locale: Locale,
        timeZone: TimeZone
    ) -> QuotaWindowDisplayItem {
        let isTrusted = showsQuotaValues(for: status)
            && dataSource == .real
            && window.state.isDisplayable
        let trustedPercent = isTrusted ? window.remainingPercent : nil
        let percentText: String
        if let trustedPercent {
            percentText = "\(trustedPercent)%"
        } else {
            percentText = status == .demoMode ? "演示" : "--"
        }

        let resetText: String
        let resetRemainingText: String
        if isTrusted, let resetAt = window.resetAt {
            resetText = shortTimestamp(
                for: resetAt,
                now: now,
                calendar: calendar,
                locale: locale,
                timeZone: timeZone
            )
            resetRemainingText = relativeRecoveryLine(for: resetAt, now: now)
        } else if isTrusted {
            resetText = "未暴露"
            resetRemainingText = "未暴露"
        } else {
            resetText = "--"
            resetRemainingText = "--"
        }

        return QuotaWindowDisplayItem(
            id: window.id,
            semanticIdentity: window.semanticIdentity,
            kind: window.kind,
            label: label,
            percentText: percentText,
            historyCaption: isTrusted && window.state == .cached ? "（历史缓存）" : nil,
            trustedPercent: trustedPercent,
            progress: trustedPercent.map { Double($0) / 100 },
            fieldState: window.state,
            stateText: quotaWindowStateText(
                state: window.state,
                dataSource: dataSource,
                status: status
            ),
            resetAt: window.resetAt,
            resetText: resetText,
            resetRemainingText: resetRemainingText,
            origin: origin
        )
    }

    private static func quotaWindowStateText(
        state: QuotaFieldState,
        dataSource: QuotaDataSource,
        status: QuotaRefreshStatus
    ) -> String {
        if status == .demoMode || dataSource != .real {
            return status == .demoMode ? "演示" : "不可用"
        }

        guard showsQuotaValues(for: status) else {
            return "等待同步"
        }

        switch state {
        case .cached:
            return "历史缓存"
        case .unavailable:
            return "不可用"
        case .invalid:
            return "数据无效"
        case .live:
            switch status {
            case .success:
                return "最新"
            case .refreshing:
                return "刷新中"
            case .stale:
                return "已过期"
            case .networkFailed, .authRequired, .parseFailed:
                return "上次数据"
            case .noSnapshot, .idle:
                return "等待同步"
            case .demoMode:
                return "演示"
            }
        }
    }

    private static func compareQuotaWindowDisplayOrder(_ lhs: QuotaWindow, _ rhs: QuotaWindow) -> Bool {
        let leftRank = quotaWindowKindRank(lhs.kind)
        let rightRank = quotaWindowKindRank(rhs.kind)
        if leftRank != rightRank {
            return leftRank < rightRank
        }

        switch (lhs.durationMinutes, rhs.durationMinutes) {
        case let (left?, right?) where left != right:
            return left < right
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            break
        }

        if lhs.limitId != rhs.limitId {
            return lhs.limitId < rhs.limitId
        }
        if lhs.windowId != rhs.windowId {
            return lhs.windowId < rhs.windowId
        }
        return lhs.id < rhs.id
    }

    private static func quotaWindowKindRank(_ kind: QuotaWindowKind) -> Int {
        switch kind {
        case .fiveHour:
            return 0
        case .weekly:
            return 1
        case .monthly:
            return 2
        case .unknown:
            return 3
        }
    }

    private static func quotaWindowLabel(
        for window: QuotaWindow,
        ordinal: Int,
        count: Int
    ) -> String {
        let label: String
        if window.kind == .unknown {
            let duration = window.durationMinutes.flatMap(quotaWindowDurationLabel)
            let durationSuffix = duration.map { " · \($0)" } ?? ""
            label = "未知额度 \(ordinal)\(durationSuffix)"
        } else if count > 1 {
            label = "\(window.displayName) \(ordinal)"
        } else {
            label = window.displayName
        }

        let maximumLength = 18
        guard label.count > maximumLength else { return label }
        return "\(label.prefix(maximumLength - 1))…"
    }

    private static func quotaWindowDurationLabel(_ minutes: Int) -> String? {
        guard minutes > 0 else { return nil }
        if minutes.isMultiple(of: 1_440) {
            return "\(minutes / 1_440)天"
        }
        if minutes.isMultiple(of: 60) {
            return "\(minutes / 60)小时"
        }
        return "\(minutes)分"
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
        quotaDisplay(for: metric, snapshot: snapshot, status: status).combinedText
    }

    private static func quotaDisplay(
        for metric: QuotaMetric,
        snapshot: QuotaSnapshot,
        status: QuotaRefreshStatus
    ) -> QuotaValueDisplay {
        let kind: QuotaWindowKind
        switch metric {
        case .fiveHour:
            kind = .fiveHour
        case .weekly:
            kind = .weekly
        }

        let candidates = quotaWindowDisplayItems(snapshot: snapshot, status: status)
            .filter { $0.kind == kind }
        guard let item = candidates.first(where: { $0.trustedPercent != nil }) ?? candidates.first else {
            return QuotaValueDisplay(
                percentText: status == .demoMode ? "演示" : "--",
                historyCaption: nil
            )
        }
        return QuotaValueDisplay(percentText: item.percentText, historyCaption: item.historyCaption)
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

    private static func compareResetBankDisplayOrder(_ lhs: ResetBankSnapshot, _ rhs: ResetBankSnapshot) -> Bool {
        switch (lhs.resetAt, rhs.resetAt) {
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

        if lhs.displayName != rhs.displayName {
            return lhs.displayName < rhs.displayName
        }

        return lhs.id < rhs.id
    }

    private static func bankDetailText(for bank: ResetBankSnapshot) -> String? {
        switch bank.resetTimeStatus {
        case .actual:
            return nil
        case .unexposed:
            return "诊断：重置时间未知/未暴露"
        case .parseFailed:
            return "诊断：重置时间格式不受支持"
        }
    }

    private static func resetCreditDetailLines(
        snapshot: QuotaSnapshot,
        hasDisplayableCreditItems: Bool
    ) -> [String] {
        var details: [String] = []

        switch snapshot.resetCreditDetailsState {
        case .detailed:
            details.append("已加载重置次数详情")
        case .unavailable:
            if let diagnostic = snapshot.resetCreditDiagnostic?.summary {
                if hasDisplayableCreditItems {
                    details.append("详情刷新失败，显示上次成功时间：\(diagnostic)")
                } else {
                    details.append("详情失败：\(diagnostic)")
                }
            } else if hasDisplayableCreditItems {
                details.append("详情刷新失败，显示上次成功时间")
            } else {
                details.append("详情暂不可用，当前仅显示 Codex 提供的次数")
            }
        case .appServerCountOnly:
            details.append("当前仅显示 Codex 提供的次数")
        }

        let hiddenStatuses = snapshot.resetCreditStatusSummary
            .sorted { lhs, rhs in
                if lhs.count != rhs.count {
                    return lhs.count > rhs.count
                }
                return lhs.status < rhs.status
            }
            .filter { $0.status != "available" && $0.count > 0 }
            .map { "\($0.status) \($0.count) 条" }
            .joined(separator: " · ")

        if !hiddenStatuses.isEmpty {
            details.append("已隐藏非 available 状态：\(hiddenStatuses)")
        }

        return details
    }

    private static func resetCreditTimingLine(
        snapshot: QuotaSnapshot,
        creditItems: [ResetCreditDisplayItem]
    ) -> String? {
        switch snapshot.resetCreditDetailsState {
        case .unavailable:
            return creditItems.isEmpty ? "到期时间暂不可用" : nil
        case .appServerCountOnly:
            return "到期时间暂不可用"
        case .detailed:
            if let count = snapshot.resetAvailableCount, count == 0 {
                return "当前没有可用 reset credit"
            }

            return creditItems.isEmpty ? "到期时间暂不可用" : nil
        }
    }

    private static func resetCreditDisplayItems(
        snapshot: QuotaSnapshot,
        status: QuotaRefreshStatus,
        now: Date,
        calendar: Calendar,
        locale: Locale,
        timeZone: TimeZone
    ) -> [ResetCreditDisplayItem] {
        guard showsQuotaValues(for: status), snapshot.dataSource == .real else {
            return []
        }

        return snapshot.resetCreditDetails
            .filter { detail in
                snapshot.resetCreditDetailsState != .unavailable ||
                detail.expiresAt.map { $0 > now } == true
            }
            .sorted(by: compareResetCreditDetails)
            .map { detail in
            let expiryText: String
            let countdownText: String

            if let expiresAt = detail.expiresAt {
                expiryText = shortTimestamp(
                    for: expiresAt,
                    now: now,
                    calendar: calendar,
                    locale: locale,
                    timeZone: timeZone
                )
                countdownText = relativeRecoveryLine(for: expiresAt, now: now)
            } else {
                expiryText = "到期时间暂不可用"
                countdownText = "暂不可用"
            }

            var subtitleParts = ["剩余 \(countdownText)"]
            if snapshot.resetCreditDetailsState == .unavailable {
                subtitleParts.append("上次成功")
            }
            var grantedText: String?
            if let grantedAt = detail.grantedAt {
                grantedText = shortTimestamp(
                    for: grantedAt,
                    now: now,
                    calendar: calendar,
                    locale: locale,
                    timeZone: timeZone
                )
            }

            return ResetCreditDisplayItem(
                id: detail.id,
                expiryText: expiryText,
                remainingText: subtitleParts.joined(separator: " · "),
                grantedText: grantedText
            )
        }
    }

    private static func compareResetCreditDetails(_ lhs: ResetCreditDetailSnapshot, _ rhs: ResetCreditDetailSnapshot) -> Bool {
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
}
