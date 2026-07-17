import Foundation

/// Pure display data consumed by the Widget view. This keeps compact-widget
/// layout decisions testable without coupling the tests to SwiftUI source.
struct WidgetPresentation: Equatable {
    enum Family: Equatable {
        case small
        case medium

        var quotaCapacity: Int {
            switch self {
            case .small:
                return 1
            case .medium:
                return 3
            }
        }
    }

    struct Quota: Equatable, Identifiable {
        let id: String
        let label: String
        let percentText: String
        let caption: String?
        let resetText: String
        let resetRemainingText: String
        let progress: Double?

        init(_ item: StatusPopoverFormatting.QuotaWindowDisplayItem) {
            id = item.id
            label = item.label
            percentText = item.percentText
            caption = item.historyCaption ?? (item.stateText == "最新" ? nil : item.stateText)
            resetText = item.resetText
            resetRemainingText = item.resetRemainingText
            progress = item.progress
        }
    }

    let family: Family
    let primaryQuota: Quota?
    let supplementaryQuotas: [Quota]
    let overflowCount: Int
    let footerText: String?

    init(state: WidgetDisplayState, family: Family, now: Date) {
        let selection = state.quotaSelection(capacity: family.quotaCapacity, now: now)
        self.init(
            visibleQuotaItems: selection.visibleItems,
            family: family,
            overflowCount: selection.overflowCount,
            resetCreditFooterText: state.resetCreditFooterText(now: now)
        )
    }

    init(
        quotaItems: [StatusPopoverFormatting.QuotaWindowDisplayItem],
        family: Family,
        resetCreditFooterText: String?
    ) {
        let selection = Self.selection(for: quotaItems, capacity: family.quotaCapacity)
        self.init(
            visibleQuotaItems: selection.visibleItems,
            family: family,
            overflowCount: selection.overflowCount,
            resetCreditFooterText: resetCreditFooterText
        )
    }

    var quotaSideItems: [Quota] {
        guard let primaryQuota else { return [] }
        return family == .small || supplementaryQuotas.isEmpty ? [primaryQuota] : supplementaryQuotas
    }

    var showsRecovery: Bool {
        primaryQuota != nil && (family == .small || supplementaryQuotas.count < 2)
    }

    var centerQuotaNumberText: String {
        primaryQuota?.percentText.replacingOccurrences(of: "%", with: "") ?? "--"
    }

    var gaugeProgress: Double {
        min(max(primaryQuota?.progress ?? 0.05, 0.05), 1.0)
    }

    func shortLabel(for label: String) -> String {
        switch label {
        case "周额度":
            return "周额度"
        case "刷新状态":
            return "状态"
        case "恢复时间":
            return "恢复"
        case "更新时间":
            return "更新"
        default:
            return label
        }
    }

    private static func footerText(from line: String?) -> String? {
        guard let line else { return nil }
        let currentPrefix = "最早重置 "
        if line.hasPrefix(currentPrefix) {
            return String(line.dropFirst(currentPrefix.count))
        }

        let cachedPrefix = "上次重置 "
        if line.hasPrefix(cachedPrefix) {
            return "上次 \(line.dropFirst(cachedPrefix.count))"
        }

        return line
    }

    private init(
        visibleQuotaItems: [StatusPopoverFormatting.QuotaWindowDisplayItem],
        family: Family,
        overflowCount: Int,
        resetCreditFooterText: String?
    ) {
        self.family = family
        let visibleQuotas = visibleQuotaItems.map(Quota.init)
        primaryQuota = visibleQuotas.first
        supplementaryQuotas = Array(visibleQuotas.dropFirst())
        self.overflowCount = overflowCount
        footerText = Self.footerText(from: resetCreditFooterText)
    }

    private static func selection(
        for items: [StatusPopoverFormatting.QuotaWindowDisplayItem],
        capacity: Int
    ) -> StatusPopoverFormatting.QuotaWindowSelection {
        guard capacity > 0 else {
            return StatusPopoverFormatting.QuotaWindowSelection(
                visibleItems: [],
                overflowCount: items.count
            )
        }
        guard !items.isEmpty else {
            return StatusPopoverFormatting.QuotaWindowSelection(visibleItems: [], overflowCount: 0)
        }

        let primaryIndex = items.firstIndex(where: { $0.trustedPercent != nil }) ?? items.startIndex
        let selectionOrder = [items[primaryIndex]] + items.enumerated().compactMap { index, item in
            index == primaryIndex ? nil : item
        }
        let visibleItems = Array(selectionOrder.prefix(capacity))
        return StatusPopoverFormatting.QuotaWindowSelection(
            visibleItems: visibleItems,
            overflowCount: max(0, selectionOrder.count - visibleItems.count)
        )
    }
}
