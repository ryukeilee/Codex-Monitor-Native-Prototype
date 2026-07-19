import Foundation

enum StatusPopoverInteractionPolicy {
    static let expandedViewportHeight: CGFloat = 520

    struct DiagnosticsLayoutSignal: Equatable {
        let refreshSummaryLine: String?
        let supportLine: String?
        let launchAtLoginErrorSummary: String?

        var hasDisclosureContent: Bool {
            supportLine != nil || launchAtLoginErrorSummary != nil
        }
    }

    static func requiresScrollableViewport(
        isQuotaExpanded: Bool,
        isDiagnosticsExpanded: Bool,
        hasDiagnosticsContent: Bool,
        quotaLayoutSignal: StatusPopoverFormatting.QuotaWindowLayoutSignal
    ) -> Bool {
        isQuotaExpanded ||
            (isDiagnosticsExpanded && hasDiagnosticsContent) ||
            quotaLayoutSignal.requiresScrolling
    }

    static func shouldNotifyQuotaLayoutChange(current: Bool, next: Bool) -> Bool {
        current != next
    }
}

enum QuotaDisclosureLayoutPolicy {
    static func requiresParentViewport(
        showsAllResetCredits: Bool,
        showsResetCreditFields: Bool
    ) -> Bool {
        showsAllResetCredits || showsResetCreditFields
    }
}

enum StatusPopoverAccessibilityContract {
    struct ControlState: Equatable {
        let isEnabled: Bool
        let label: String
        let value: String
        let hint: String
        let identifier: String
    }

    struct QuotaCardState: Equatable {
        let label: String
        let value: String
        let hint: String
        let identifier: String
    }

    static let scrollViewportIdentifier = "quota-scroll-viewport"
    static let launchAtLoginToggleIdentifier = "launch-at-login-toggle"
    static let refreshButtonIdentifier = "refresh-button"
    static let quitButtonIdentifier = "quit-button"
    static let diagnosticsDisclosureIdentifier = "diagnostics-disclosure"
    static let resetCreditsDisclosureIdentifier = "reset-credits-disclosure"
    static let resetCreditFieldsDisclosureIdentifier = "reset-credit-fields-disclosure"

    static func launchAtLoginValue(
        isUpdating: Bool,
        statusInfo: LaunchAtLoginManager.StatusInfo
    ) -> String {
        if isUpdating {
            return "正在更新"
        }
        return statusInfo.message
    }

    static func launchAtLoginControlState(
        isUpdating: Bool,
        statusInfo: LaunchAtLoginManager.StatusInfo
    ) -> ControlState {
        ControlState(
            isEnabled: !isUpdating,
            label: "开机启动",
            value: launchAtLoginValue(isUpdating: isUpdating, statusInfo: statusInfo),
            hint: isUpdating ? "正在更新开机启动设置" : "开启或关闭登录时自动启动",
            identifier: launchAtLoginToggleIdentifier
        )
    }

    static func refreshValue(for status: QuotaRefreshStatus) -> String {
        status == .refreshing ? "正在刷新" : "可刷新"
    }

    static func refreshControlState(for status: QuotaRefreshStatus) -> ControlState {
        let isEnabled = status != .refreshing
        return ControlState(
            isEnabled: isEnabled,
            label: "刷新额度",
            value: refreshValue(for: status),
            hint: isEnabled ? "按 Command-R 立即更新额度数据" : "刷新进行中，请等待完成",
            identifier: refreshButtonIdentifier
        )
    }

    static let quitControlState = ControlState(
        isEnabled: true,
        label: "退出 Codex Monitor",
        value: "可退出",
        hint: "按 Command-Q 退出应用",
        identifier: quitButtonIdentifier
    )

    static func quotaCardState(
        for item: StatusPopoverFormatting.QuotaWindowDisplayItem,
        status: QuotaRefreshStatus
    ) -> QuotaCardState {
        QuotaCardState(
            label: "\(item.label) 额度窗口，剩余 \(item.combinedPercentText)",
            value: "\(quotaCardCredibilityValue(for: item, status: status))；\(item.stateText)；恢复 \(item.resetText)，还需 \(item.resetRemainingText)",
            hint: "只读额度状态；使用刷新额度按钮更新数据",
            identifier: quotaCardIdentifier(for: item.semanticIdentity)
        )
    }

    static func quotaCardIdentifier(for semanticIdentity: String) -> String {
        "quota-card-\(semanticIdentity)"
    }

    static func quotaCredibilityValue(for status: QuotaRefreshStatus) -> String {
        switch status {
        case .success:
            return "可信度：最新数据"
        case .refreshing:
            return "可信度：正在刷新，当前显示的数据尚未更新"
        case .stale:
            return "可信度：数据已过期"
        case .networkFailed:
            return "可信度：网络异常，显示上次数据"
        case .authRequired:
            return "可信度：需要登录，显示上次数据"
        case .parseFailed:
            return "可信度：数据异常，显示上次数据"
        case .noSnapshot:
            return "可信度：尚无可用额度数据"
        case .demoMode:
            return "可信度：演示数据"
        case .idle:
            return "可信度：等待刷新"
        }
    }

    static func quotaCardCredibilityValue(
        for item: StatusPopoverFormatting.QuotaWindowDisplayItem,
        status: QuotaRefreshStatus
    ) -> String {
        switch item.fieldState {
        case .live:
            return quotaCredibilityValue(for: status)
        case .cached:
            return "可信度：当前窗口为历史缓存，\(snapshotCredibilityValue(for: status))"
        case .invalid:
            return "可信度：当前窗口数据无效，\(snapshotCredibilityValue(for: status))"
        case .unavailable:
            return "可信度：当前窗口不可用，\(snapshotCredibilityValue(for: status))"
        }
    }

    private static func snapshotCredibilityValue(for status: QuotaRefreshStatus) -> String {
        switch status {
        case .success:
            return "本次快照最新"
        case .refreshing:
            return "正在刷新"
        case .stale:
            return "数据已过期"
        case .networkFailed:
            return "网络异常"
        case .authRequired:
            return "需要登录"
        case .parseFailed:
            return "数据异常"
        case .noSnapshot:
            return "尚无可用额度数据"
        case .demoMode:
            return "演示数据"
        case .idle:
            return "等待刷新"
        }
    }

    static func disclosureValue(isExpanded: Bool) -> String {
        isExpanded ? "已展开" : "已折叠"
    }
}
