import SwiftUI

struct QuotaSummaryView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 5) {
                Text("\(decisionText) · \(freshnessText)")
                Text(quotaSummaryText)
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
        StatusPopoverFormatting.titleSummary(for: appState.displayStatus)
    }

    private var quotaSummaryText: String {
        StatusPopoverFormatting.quotaSummaryLine(
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

    private var recommendationText: String {
        appState.quotaDecision.recommendation
    }

    private var recoveryParts: (resetText: String, remainingText: String) {
        let line = StatusPopoverFormatting.recoverySummaryLine(
            resetAt: appState.effectiveFiveHourResetAt,
            status: appState.displayStatus
        )
        let parts = line.components(separatedBy: " · ")
        guard parts.count == 2 else {
            return ("--", "--")
        }

        let resetText = parts[0].replacingOccurrences(of: "恢复 ", with: "")
        let remainingText = parts[1].replacingOccurrences(of: "还需 ", with: "")
        return (resetText, remainingText)
    }
}
