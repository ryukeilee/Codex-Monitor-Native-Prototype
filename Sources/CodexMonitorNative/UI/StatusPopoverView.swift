import SwiftUI

struct StatusPopoverView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var launchAtLoginManager: LaunchAtLoginManager
    let onRefresh: () -> Void
    let onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Codex Monitor Native")
                .font(.headline.weight(.semibold))
                .lineLimit(1)

            QuotaSummaryView(appState: appState)

            if let supportLine {
                Text(supportLine)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("开机启动")
                        .font(.subheadline.weight(.medium))

                    Text(launchAtLoginManager.helperText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Toggle("", isOn: launchAtLoginBinding)
                    .labelsHidden()
                    .disabled(launchAtLoginManager.isUpdating)
                    .controlSize(.small)
                    .accessibilityLabel("开机启动")
            }

            if let loginError = launchAtLoginManager.lastErrorSummary {
                Text(loginError)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Divider()
                .opacity(0.55)

            HStack(alignment: .center, spacing: 8) {
                Button(action: onRefresh) {
                    if appState.isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("刷新")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(appState.isRefreshing)

                Spacer()

                Button("退出", action: onQuit)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .controlSize(.small)
            }
        }
        .padding(12)
        .frame(width: 314)
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLoginManager.shouldLaunchAtLogin },
            set: { newValue in
                AppLogger.settings.info("Launch at login toggle changed from UI to \(newValue, privacy: .public)")
                launchAtLoginManager.setLaunchAtLogin(newValue)
            }
        )
    }

    private var credibilityLine: String {
        StatusPopoverFormatting.credibilityLine(
            lastSuccess: appState.lastSuccessAt,
            lastAttempt: appState.lastAttemptAt,
            dataSource: appState.dataSource,
            status: appState.displayStatus
        )
    }

    private var supportLine: String? {
        switch appState.displayStatus {
        case .refreshing:
            return "正在刷新，先显示当前快照"
        case .networkFailed, .authRequired, .parseFailed:
            if let refreshError = appState.lastErrorSummary {
                return "\(credibilityLine) · \(refreshError)"
            }
            return credibilityLine
        case .stale:
            return credibilityLine
        default:
            if let refreshError = appState.lastErrorSummary {
                return refreshError
            }

            let healthLine = StatusPopoverFormatting.realQuotaHealthLine(appState.realQuotaHealth)
            switch appState.realQuotaHealth.kind {
            case .requestSucceeded:
                return nil
            default:
                return healthLine
            }
        }
    }
}
