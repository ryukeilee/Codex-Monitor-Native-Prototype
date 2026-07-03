import SwiftUI

struct StatusPopoverView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var launchAtLoginManager: LaunchAtLoginManager
    let onRefresh: () -> Void
    let onQuit: () -> Void
    @State private var showsDiagnostics = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Codex Monitor Native")
                .font(.headline.weight(.semibold))
                .lineLimit(1)

            QuotaSummaryView(appState: appState)

            if let refreshSummaryLine {
                Text(refreshSummaryLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            if hasDiagnosticsContent {
                DisclosureGroup("详情与诊断", isExpanded: $showsDiagnostics) {
                    VStack(alignment: .leading, spacing: 6) {
                        if let supportLine {
                            Text(supportLine)
                        }

                        if let loginError = launchAtLoginManager.lastErrorSummary {
                            Text(loginError)
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                }
                .font(.caption)
                .tint(.secondary)
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

    private var environmentInfoLine: String? {
        StatusPopoverFormatting.environmentInfoLine(
            lastSuccess: appState.lastSuccessAt,
            lastAttempt: appState.lastAttemptAt,
            dataSource: appState.dataSource,
            status: appState.displayStatus,
            showsSourceStatus: hasDisplayableSourceStatus
        )
    }

    private var hasDisplayableSourceStatus: Bool {
        appState.dataSource == .real || appState.displayStatus == .demoMode
    }

    private var supportLine: String? {
        switch appState.displayStatus {
        case .refreshing:
            return "正在刷新，先显示当前快照"
        case .networkFailed, .authRequired, .parseFailed:
            if let refreshError = appState.lastErrorSummary {
                if let environmentInfoLine {
                    return "\(environmentInfoLine) · \(refreshError)"
                }
                return refreshError
            }
            return environmentInfoLine
        case .stale:
            return environmentInfoLine
        default:
            if let refreshError = appState.lastErrorSummary {
                return refreshError
            }

            let healthLine = StatusPopoverFormatting.realQuotaHealthLine(appState.realQuotaHealth)
            switch appState.realQuotaHealth.kind {
            case .requestSucceeded:
                return nil
            case .waitingForFirstRequest where !hasDisplayableSourceStatus:
                return nil
            default:
                return healthLine
            }
        }
    }

    private var refreshSummaryLine: String? {
        switch appState.displayStatus {
        case .refreshing:
            return "正在刷新，主额度与 reset credits 保持当前快照"
        case .networkFailed:
            return "刷新失败，当前显示上次成功快照"
        case .authRequired:
            return "需要重新登录 Codex，当前显示上次成功快照"
        case .parseFailed:
            return "响应暂时不可解析，当前显示上次成功快照"
        case .stale:
            return "当前显示的数据已过期，建议手动刷新"
        default:
            return nil
        }
    }

    private var hasDiagnosticsContent: Bool {
        supportLine != nil || launchAtLoginManager.lastErrorSummary != nil
    }
}
