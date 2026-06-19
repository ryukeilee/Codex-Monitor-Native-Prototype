import SwiftUI

struct QuotaSummaryView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            quotaRow(title: "Weekly Quota", value: weeklyQuotaText)
            quotaRow(title: "5 Hour Quota", value: fiveHourQuotaText)

            VStack(alignment: .leading, spacing: 4) {
                Text(updatedText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)

                Text(sourceStatusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)
            }
        }
    }

    // MARK: - Quota display

    private var weeklyQuotaText: String {
        switch appState.status {
        case .success, .refreshing, .networkFailed, .authRequired, .parseFailed:
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
        case .success, .refreshing, .networkFailed, .authRequired, .parseFailed:
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

    private func quotaRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.medium)
                .monospacedDigit()
        }
    }
}
