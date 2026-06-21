import SwiftUI

struct QuotaSummaryView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            quotaRow(title: "5h Recovery", value: fiveHourRecoveryText)
            quotaRow(title: "Recovers In", value: recoveryCountdownText)
            quotaRow(title: "Decision", value: decisionText)
            detailLine(title: "Advice", value: recommendationText)
            quotaRow(title: "Weekly Quota", value: weeklyQuotaText)
            quotaRow(title: "5 Hour Quota", value: fiveHourQuotaText)

            HStack(spacing: 4) {
                Text(updatedText)
                Text("·")
                Text(sourceStatusText)
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
        }
    }

    // MARK: - Quota display

    private var weeklyQuotaText: String {
        switch appState.status {
        case .success, .stale, .refreshing, .networkFailed, .authRequired, .parseFailed:
            if appState.dataSource == .real {
                return "\(appState.snapshot.weeklyQuotaPercent)%"
            }
            return "--"
        case .noSnapshot, .idle:
            return "Not Connected"
        case .demoMode:
            return "Demo"
        }
    }

    private var fiveHourQuotaText: String {
        switch appState.status {
        case .success, .stale, .refreshing, .networkFailed, .authRequired, .parseFailed:
            if appState.dataSource == .real {
                return "\(appState.snapshot.fiveHourQuotaPercent)%"
            }
            return "--"
        case .noSnapshot, .idle:
            return "Not Connected"
        case .demoMode:
            return "Demo"
        }
    }

    private var updatedText: String {
        StatusPopoverFormatting.updatedLine(
            lastSuccess: appState.lastSuccessAt,
            lastAttempt: appState.lastAttemptAt
        )
    }

    private var sourceStatusText: String {
        StatusPopoverFormatting.sourceStatusLine(
            dataSource: appState.dataSource,
            status: appState.status
        )
    }

    private var fiveHourRecoveryText: String {
        guard let resetAt = appState.effectiveFiveHourResetAt else {
            return "--"
        }

        return StatusPopoverFormatting.shortTimestamp(for: resetAt)
    }

    private var recoveryCountdownText: String {
        StatusPopoverFormatting.relativeRecoveryLine(for: appState.effectiveFiveHourResetAt)
    }

    private var decisionText: String {
        appState.quotaDecision.level.rawValue
    }

    private var recommendationText: String {
        appState.quotaDecision.recommendation
    }

    private func quotaRow(title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.body.weight(.semibold))
                .monospacedDigit()
        }
    }

    private func detailLine(title: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 78, alignment: .leading)
            Text(value)
                .font(.subheadline.weight(.medium))
                .multilineTextAlignment(.leading)
        }
    }
}
