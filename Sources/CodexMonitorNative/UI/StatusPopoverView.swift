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
                DisclosureGroup("诊断", isExpanded: $showsDiagnostics) {
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

            launchAtLoginSection

            Divider()
                .opacity(usesCompactLaunchAtLoginSection ? 0.35 : 0.55)

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

    @ViewBuilder
    private var launchAtLoginSection: some View {
        if usesCompactLaunchAtLoginSection {
            HStack(alignment: .center, spacing: 8) {
                Text("开机启动 · 已启用")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer(minLength: 8)

                launchAtLoginToggle(controlSize: .mini, isLowEmphasis: true)
            }
        } else {
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

                launchAtLoginToggle(controlSize: .small, isLowEmphasis: false)
            }
        }
    }

    private var usesCompactLaunchAtLoginSection: Bool {
        launchAtLoginManager.statusInfo == .enabled
    }

    private func launchAtLoginToggle(controlSize: ControlSize, isLowEmphasis: Bool) -> some View {
        Toggle("", isOn: launchAtLoginBinding)
            .labelsHidden()
            .disabled(launchAtLoginManager.isUpdating)
            .controlSize(controlSize)
            .opacity(isLowEmphasis ? 0.62 : 1)
            .scaleEffect(isLowEmphasis ? 0.86 : 1)
            .accessibilityLabel("开机启动")
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
        StatusPopoverFormatting.freshnessSummary(
            for: appState.displayStatus,
            isUsingCachedSnapshot: appState.isUsingCachedSnapshot
        )
    }

    private var hasDiagnosticsContent: Bool {
        supportLine != nil || launchAtLoginManager.lastErrorSummary != nil
    }
}
