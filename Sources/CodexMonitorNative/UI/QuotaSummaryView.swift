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

                if let resetCreditsSummary {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Reset Credits")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        Text(resetCreditsSummary.countLine)
                            .font(.subheadline.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)

                        if let timingLine = resetCreditsSummary.timingLine {
                            Text(timingLine)
                                .font(.subheadline.weight(.semibold))
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        ForEach(resetCreditsSummary.detailLines, id: \.self) { detailLine in
                            Text(detailLine)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
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

    private var resetCreditsSummary: StatusPopoverFormatting.ResetCreditsSummary? {
        StatusPopoverFormatting.resetCreditsSummary(
            snapshot: appState.snapshot,
            status: appState.displayStatus
        )
    }

    @ViewBuilder
    private func metricBlock(title: String, value: String, allowsMultiline: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .lineLimit(allowsMultiline ? 2 : 1)
                .fixedSize(horizontal: false, vertical: allowsMultiline)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
