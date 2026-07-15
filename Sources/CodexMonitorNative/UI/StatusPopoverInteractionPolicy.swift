import Foundation

enum StatusPopoverInteractionPolicy {
    static let expandedViewportHeight: CGFloat = 520

    static func requiresScrollableViewport(
        isQuotaExpanded: Bool,
        isSelfCheckExpanded: Bool,
        isDiagnosticsExpanded: Bool,
        quotaLayoutSignal: StatusPopoverFormatting.QuotaWindowLayoutSignal
    ) -> Bool {
        isQuotaExpanded || isSelfCheckExpanded || isDiagnosticsExpanded || quotaLayoutSignal.requiresScrolling
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
    static let selfCheckDisclosureIdentifier = "self-check-disclosure"
    static let diagnosticsDisclosureIdentifier = "diagnostics-disclosure"
    static let resetCreditsDisclosureIdentifier = "reset-credits-disclosure"
    static let resetCreditFieldsDisclosureIdentifier = "reset-credit-fields-disclosure"

    static func launchAtLoginValue(isUpdating: Bool, isEnabled: Bool) -> String {
        if isUpdating {
            return "正在更新"
        }
        return isEnabled ? "已开启" : "已关闭"
    }

    static func refreshValue(for status: QuotaRefreshStatus) -> String {
        status == .refreshing ? "正在刷新" : "可刷新"
    }

    static func disclosureValue(isExpanded: Bool) -> String {
        isExpanded ? "已展开" : "已折叠"
    }
}
