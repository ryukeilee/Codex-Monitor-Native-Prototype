import SwiftUI

struct QuotaSummaryView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 5) {
                Text("\(decisionText) · \(freshnessText)")
                Text("5小时额度 \(fiveHourQuotaText) · 周额度 \(weeklyQuotaText)")
                Text("恢复 \(fiveHourRecoveryText) · 还需 \(recoveryCountdownText)")
                Text("建议 \(recommendationText)")
                    .foregroundStyle(.secondary)
                    .fontWeight(.medium)
            }
            .font(.subheadline)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var decisionText: String {
        appState.quotaDecision.level.rawValue
    }

    private var freshnessText: String {
        StatusPopoverFormatting.titleSummary(for: appState.status)
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
            return "--"
        case .demoMode:
            return "演示"
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
            return "--"
        case .demoMode:
            return "演示"
        }
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

    private var recommendationText: String {
        appState.quotaDecision.recommendation
    }
}
