import SwiftUI

struct QuotaSummaryView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text(freshnessText)
                    .font(.headline.weight(.semibold))

                HStack(alignment: .top, spacing: 16) {
                    metricBlock(title: "5小时额度", value: fiveHourQuotaText)
                    metricBlock(title: "周额度", value: weeklyQuotaText)
                }

                HStack(alignment: .top, spacing: 16) {
                    metricBlock(title: "恢复时间", value: fiveHourRecoveryText)
                    metricBlock(title: "剩余", value: recoveryCountdownText)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var freshnessText: String {
        StatusPopoverFormatting.titleSummary(for: appState.displayStatus)
    }

    private var fiveHourQuotaText: String {
        StatusPopoverFormatting.quotaValueText(
            for: .fiveHour,
            snapshot: appState.snapshot,
            status: appState.displayStatus
        )
    }

    private var weeklyQuotaText: String {
        StatusPopoverFormatting.quotaValueText(
            for: .weekly,
            snapshot: appState.snapshot,
            status: appState.displayStatus
        )
    }

    private var fiveHourRecoveryText: String {
        recoveryParts.resetText
    }

    private var recoveryCountdownText: String {
        recoveryParts.remainingText
    }

    private var recoveryParts: (resetText: String, remainingText: String) {
        let details = StatusPopoverFormatting.recoveryDetails(
            resetAt: appState.effectiveFiveHourResetAt,
            status: appState.displayStatus
        )
        return (details.resetText, details.remainingText)
    }

    @ViewBuilder
    private func metricBlock(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
