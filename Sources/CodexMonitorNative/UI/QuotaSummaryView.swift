import SwiftUI

struct QuotaSummaryView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            row(title: "Weekly Quota", value: weeklyQuotaText)
            row(title: "5 Hour Quota", value: fiveHourQuotaText)
            row(title: "Last Refresh", value: appState.formattedRefreshedAt)
            row(title: "Source", value: dataSourceText)
            row(title: "Status", value: statusText)
            if let error = appState.lastError {
                HStack {
                    Text("Error")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(error)
                        .fontWeight(.medium)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
        }
    }

    private var weeklyQuotaText: String {
        switch appState.dataSource {
        case .real:
            return "\(appState.snapshot.weeklyQuotaPercent)%"
        case .mock:
            return "Demo"
        }
    }

    private var fiveHourQuotaText: String {
        switch appState.dataSource {
        case .real:
            return "\(appState.snapshot.fiveHourQuotaPercent)%"
        case .mock:
            return "Demo"
        }
    }

    private var dataSourceText: String {
        switch appState.dataSource {
        case .real:
            return "Real (codex app-server)"
        case .mock:
            return "Demo Mode"
        }
    }

    private var statusText: String {
        if appState.dataSource == .mock {
            return "Prototype Mode"
        }
        return appState.status.displayName
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
