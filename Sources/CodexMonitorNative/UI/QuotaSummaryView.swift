import SwiftUI

struct QuotaSummaryView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            row(title: "Weekly Quota", value: weeklyQuotaText)
            row(title: "5 Hour Quota", value: fiveHourQuotaText)
            row(title: "Last Success", value: appState.formattedLastSuccess ?? "--")
            row(title: "Last Attempt", value: appState.formattedLastAttempt ?? "--")
            row(title: "Data Source", value: dataSourceText)
            row(title: "Status", value: statusText)

            if let error = appState.lastErrorSummary {
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

            if appState.failureCount > 0 {
                HStack {
                    Text("Failures")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(appState.failureCount)")
                        .fontWeight(.medium)
                        .foregroundStyle(appState.status.isError ? .red : .secondary)
                }
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

    private var dataSourceText: String {
        switch appState.dataSource {
        case .real:
            return "Real (codex app-server)"
        case .mock:
            return "Demo Mode"
        }
    }

    private var statusText: String {
        appState.status.displayName
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
