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

    static func refreshValue(for status: QuotaRefreshStatus) -> String {
        status == .refreshing ? "正在刷新" : "可刷新"
    }

    static func disclosureValue(isExpanded: Bool) -> String {
        isExpanded ? "已展开" : "已折叠"
    }
}
