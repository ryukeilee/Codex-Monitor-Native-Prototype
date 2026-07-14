import SwiftUI

struct QuotaSummaryView: View {
    let presentationSnapshot: QuotaPresentationSnapshot
    let onLayoutChange: (Bool) -> Void
    @Binding private var showsAllResetCredits: Bool
    @Binding private var showsResetCreditFields: Bool

    init(
        presentationSnapshot: QuotaPresentationSnapshot,
        showsAllResetCredits: Binding<Bool> = .constant(false),
        showsResetCreditFields: Binding<Bool> = .constant(false),
        onLayoutChange: @escaping (Bool) -> Void = { _ in }
    ) {
        self.presentationSnapshot = presentationSnapshot
        self._showsAllResetCredits = showsAllResetCredits
        self._showsResetCreditFields = showsResetCreditFields
        self.onLayoutChange = onLayoutChange
    }

    var body: some View {
        VStack(spacing: 10) {
            if quotaItems.isEmpty {
                Text("暂无可显示的额度窗口")
                    .font(.subheadline)
                    .foregroundStyle(MetallicPalette.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(MetallicPalette.card)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                LazyVGrid(columns: quotaColumns, alignment: .leading, spacing: 8) {
                    ForEach(quotaItems) { item in
                        QuotaGaugeView(item: item)
                    }
                }
                .frame(maxWidth: .infinity)
            }

            if let resetCreditsSummary {
                resetCreditsSection(resetCreditsSummary)
            }
        }
        .onChange(of: showsAllResetCredits) { _, _ in
            onLayoutChange(showsAllResetCredits || showsResetCreditFields)
        }
        .onChange(of: showsResetCreditFields) { _, _ in
            onLayoutChange(showsAllResetCredits || showsResetCreditFields)
        }
    }

    private var quotaItems: [StatusPopoverFormatting.QuotaWindowDisplayItem] {
        StatusPopoverFormatting.quotaWindowDisplayItems(
            snapshot: presentationSnapshot.snapshot,
            status: presentationSnapshot.status
        )
    }

    private var quotaColumns: [GridItem] {
        [
            GridItem(.flexible(minimum: 140), spacing: 8, alignment: .top),
            GridItem(.flexible(minimum: 140), spacing: 8, alignment: .top)
        ]
    }

    private var resetCreditsSummary: StatusPopoverFormatting.ResetCreditsSummary? {
        StatusPopoverFormatting.resetCreditsSummary(
            snapshot: presentationSnapshot.snapshot,
            status: presentationSnapshot.status
        )
    }

    @ViewBuilder
    private func resetCreditsSection(_ summary: StatusPopoverFormatting.ResetCreditsSummary) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.clockwise")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(MetallicPalette.red)
                    .frame(width: 22)
                Text(summary.countLine)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(MetallicPalette.foreground)
                    .accessibilityLabel("重置次数 \(summary.countLine)")
                Spacer()
            }
                    .padding(.vertical, 8)

            Divider().overlay(MetallicPalette.separator)

            HStack(spacing: 12) {
                Image(systemName: "clock")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(MetallicPalette.red)
                    .frame(width: 22)

                if let featured = summary.featuredCreditItem {
                    featuredResetCreditSummary(featured)
                } else if let timingLine = summary.timingLine {
                    Text(timingLine)
                        .font(.subheadline)
                        .foregroundStyle(MetallicPalette.muted)
                    Spacer()
                } else {
                    Text("最早到期 --")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(MetallicPalette.foreground)
                    Spacer()
                }
            }
            .padding(.vertical, 8)

            if !summary.additionalCreditItems.isEmpty || !summary.detailLines.isEmpty {
                let disclosureTitle = summary.additionalCreditItems.isEmpty && summary.featuredCreditItem == nil
                    ? "字段详情"
                    : "全部 \(summary.additionalCreditItems.count + (summary.featuredCreditItem == nil ? 0 : 1))"
                DisclosureGroup(isExpanded: $showsAllResetCredits) {
                    VStack(alignment: .leading, spacing: 8) {
                        if let featured = summary.featuredCreditItem {
                            resetCreditDetailRow(featured)
                        }
                        ForEach(summary.additionalCreditItems) { item in
                            resetCreditDetailRow(item)
                        }
                        if !summary.detailLines.isEmpty {
                            DisclosureGroup("字段", isExpanded: $showsResetCreditFields) {
                                VStack(alignment: .leading, spacing: 6) {
                                    ForEach(summary.detailLines, id: \.self) { line in
                                        Text(line)
                                            .font(.caption2)
                                            .foregroundStyle(MetallicPalette.muted)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                .padding(.top, 4)
                            }
                            .font(.caption)
                            .tint(MetallicPalette.muted)
                            .accessibilityValue(showsResetCreditFields ? "已展开" : "已折叠")
                            .accessibilityHint("显示或隐藏重置额度字段")
                            .accessibilityIdentifier("reset-credit-fields-disclosure")
                        }
                    }
                    .padding(.top, 8)
                } label: {
                    HStack(spacing: 6) {
                        Text(disclosureTitle)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(MetallicPalette.foreground)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .tint(MetallicPalette.redBright)
                .accessibilityLabel("重置额度详情，\(disclosureTitle)")
                .accessibilityValue(showsAllResetCredits ? "已展开" : "已折叠")
                .accessibilityHint("显示或隐藏重置额度详情")
                .accessibilityIdentifier("reset-credits-disclosure")
            }
        }
        .padding(.horizontal, 10)
        .background(MetallicPalette.card)
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(MetallicPalette.border, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private func featuredResetCreditSummary(_ creditItem: StatusPopoverFormatting.ResetCreditDisplayItem) -> some View {
        Text("最早到期")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(MetallicPalette.foreground)
        Text(creditItem.expiryText)
            .font(.subheadline)
            .foregroundStyle(MetallicPalette.muted)
        Spacer(minLength: 4)
        Text(creditItem.remainingText)
            .font(.caption.weight(.medium))
            .foregroundStyle(MetallicPalette.muted)
            .lineLimit(1)
    }

    @ViewBuilder
    private func resetCreditDetailRow(_ creditItem: StatusPopoverFormatting.ResetCreditDisplayItem) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("到期 \(creditItem.expiryText)")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(MetallicPalette.foreground)
            Text(detailSubtitle(for: creditItem))
                .font(.caption)
                .foregroundStyle(MetallicPalette.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(MetallicPalette.innerCard)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func detailSubtitle(for creditItem: StatusPopoverFormatting.ResetCreditDisplayItem) -> String {
        if let grantedText = creditItem.grantedText {
            return "\(creditItem.remainingText) · 授予 \(grantedText)"
        }
        return creditItem.remainingText
    }
}

struct QuotaGaugeView: View {
    let item: StatusPopoverFormatting.QuotaWindowDisplayItem

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(item.label)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(MetallicPalette.foreground)
                    .lineLimit(1)
                    .help(item.label)
                Spacer(minLength: 2)
                Text(item.stateText)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(MetallicPalette.muted)
                    .lineLimit(1)
            }
            Text(item.percentText)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundStyle(MetallicPalette.foreground)
                .lineLimit(nil)
                .fixedSize(horizontal: true, vertical: false)
            if let historyCaption = item.historyCaption {
                Text(historyCaption)
                    .font(.caption2)
                    .foregroundStyle(MetallicPalette.muted)
                    .lineLimit(1)
            }
            GeometryReader { geometry in
                Capsule(style: .continuous)
                    .fill(MetallicPalette.track)
                    .overlay(alignment: .leading) {
                        Capsule(style: .continuous)
                            .fill(MetallicPalette.redGradient)
                            .frame(width: max(0, geometry.size.width * (item.progress ?? 0)))
                    }
            }
            .frame(height: 6)
            Text("恢复 \(item.resetText)")
                .font(.caption2)
                .foregroundStyle(MetallicPalette.muted)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
            Text("还需 \(item.resetRemainingText)")
                .font(.caption2)
                .foregroundStyle(MetallicPalette.muted)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(MetallicPalette.card)
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(MetallicPalette.border, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(item.label) \(item.percentText)，\(item.stateText)，恢复 \(item.resetText)，还需 \(item.resetRemainingText)"
        )
    }
}
