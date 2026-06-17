import SwiftUI

struct QuotaSummaryView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            row(title: "Weekly Quota", value: "\(appState.snapshot.weeklyQuotaPercent)%")
            row(title: "5 Hour Quota", value: "\(appState.snapshot.fiveHourQuotaPercent)%")
            row(title: "Last Refresh", value: appState.formattedRefreshedAt)
            row(title: "Status", value: appState.status.displayName)
        }
    }

    private func row(title: String, value: String) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.medium)
        }
    }
}
