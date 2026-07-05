import SwiftUI

struct QuotaSummaryView: View {
    @ObservedObject var appState: AppState
    @State private var showsAllResetCredits = false

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 8) {
                    Text("当前状态")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Text(freshnessText)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(statusBadgeBackground)
                        .clipShape(Capsule())

                    Spacer()
                }

                HStack(alignment: .top, spacing: 16) {
                    metricCard(title: "5小时额度", value: fiveHourQuotaText)
                    metricCard(title: "周额度", value: weeklyQuotaText)
                }

                if let resetCreditsSummary {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("重置次数")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        VStack(alignment: .leading, spacing: 6) {
                            Text(resetCreditsSummary.countLine)
                                .font(.headline.weight(.semibold))
                                .fixedSize(horizontal: false, vertical: true)

                            if let timingLine = resetCreditsSummary.timingLine {
                                Text(timingLine)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            if let featuredCreditItem = resetCreditsSummary.featuredCreditItem {
                                featuredResetCreditSummary(featuredCreditItem)
                                    .padding(.top, 4)
                            }

                            if !resetCreditsSummary.additionalCreditItems.isEmpty {
                                DisclosureGroup(
                                    "查看全部（\(resetCreditsSummary.additionalCreditItems.count + (resetCreditsSummary.featuredCreditItem == nil ? 0 : 1))）",
                                    isExpanded: $showsAllResetCredits
                                ) {
                                    VStack(alignment: .leading, spacing: 8) {
                                        if let featuredCreditItem = resetCreditsSummary.featuredCreditItem {
                                            resetCreditDetailRow(featuredCreditItem)
                                        }

                                        ForEach(resetCreditsSummary.additionalCreditItems) { creditItem in
                                            resetCreditDetailRow(creditItem)
                                        }
                                    }
                                    .padding(.top, 8)
                                }
                                .font(.caption)
                                .tint(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        if !resetCreditsSummary.detailLines.isEmpty {
                            DisclosureGroup("原始字段与诊断") {
                                VStack(alignment: .leading, spacing: 6) {
                                    ForEach(resetCreditsSummary.detailLines, id: \.self) { detailLine in
                                        Text(detailLine)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                .padding(.top, 4)
                            }
                            .font(.caption)
                            .tint(.secondary)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var freshnessText: String {
        StatusPopoverFormatting.freshnessTitle(
            for: appState.displayStatus,
            isUsingCachedSnapshot: appState.isUsingCachedSnapshot
        )
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

    private var statusBadgeBackground: Color {
        switch appState.displayStatus {
        case .success:
            return .green.opacity(0.16)
        case .refreshing:
            return .blue.opacity(0.16)
        case .stale:
            return .orange.opacity(0.16)
        case .networkFailed, .authRequired, .parseFailed:
            return .red.opacity(0.14)
        case .noSnapshot, .idle, .demoMode:
            return .gray.opacity(0.14)
        }
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

    @ViewBuilder
    private func metricCard(title: String, value: String) -> some View {
        metricBlock(title: title, value: value)
            .padding(12)
            .background(Color.secondary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private func featuredResetCreditSummary(_ creditItem: StatusPopoverFormatting.ResetCreditDisplayItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("最早到期 \(creditItem.expiryText)")
                .font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)

            Text(creditItem.remainingText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func resetCreditDetailRow(_ creditItem: StatusPopoverFormatting.ResetCreditDisplayItem) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("到期 \(creditItem.expiryText)")
                .font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)

            Text(detailSubtitle(for: creditItem))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.secondary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func detailSubtitle(for creditItem: StatusPopoverFormatting.ResetCreditDisplayItem) -> String {
        if let grantedText = creditItem.grantedText {
            return "\(creditItem.remainingText) · 授予 \(grantedText)"
        }

        return creditItem.remainingText
    }
}
