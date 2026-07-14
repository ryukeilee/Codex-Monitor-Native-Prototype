import SwiftUI

@MainActor
final class PopoverPresentationState: ObservableObject {
    @Published private(set) var isPanelActive: Bool

    init(isPanelActive: Bool = true) {
        self.isPanelActive = isPanelActive
    }

    func setPanelActive(_ active: Bool) {
        guard isPanelActive != active else { return }
        isPanelActive = active
    }
}

struct StatusPopoverView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var launchAtLoginManager: LaunchAtLoginManager
    @ObservedObject var presentationState: PopoverPresentationState
    let onRefresh: () -> Void
    let onQuit: () -> Void
    let onLayoutChange: () -> Void
    @State private var showsDiagnostics = false
    @State private var showsSelfCheck = false
    @State private var isQuotaExpanded = false
    @State private var showsAllResetCredits = false
    @State private var showsResetCreditFields = false

    private static let expandedViewportHeight: CGFloat = 520

    init(
        appState: AppState,
        launchAtLoginManager: LaunchAtLoginManager,
        presentationState: PopoverPresentationState = PopoverPresentationState(),
        onRefresh: @escaping () -> Void,
        onQuit: @escaping () -> Void,
        onLayoutChange: @escaping () -> Void = {}
    ) {
        self.appState = appState
        self.launchAtLoginManager = launchAtLoginManager
        self.presentationState = presentationState
        self.onRefresh = onRefresh
        self.onQuit = onQuit
        self.onLayoutChange = onLayoutChange
    }

    private var isPanelActive: Bool { presentationState.isPanelActive }
    private var presentationSnapshot: QuotaPresentationSnapshot { appState.presentationSnapshot }

    var body: some View {
        MetallicPanelBackground {
            if hasExpandedContent {
                ScrollView(.vertical) {
                    panelContent
                }
                .frame(maxWidth: .infinity)
                .frame(height: Self.expandedViewportHeight, alignment: .top)
                .accessibilityIdentifier("quota-scroll-viewport")
            } else {
                panelContent
            }
        }
        .frame(maxWidth: .infinity)
        .onChange(of: showsSelfCheck) { _, _ in onLayoutChange() }
        .onChange(of: showsDiagnostics) { _, _ in onLayoutChange() }
        .onChange(of: quotaLayoutSignal) { _, _ in onLayoutChange() }
    }

    private var hasExpandedContent: Bool {
        isQuotaExpanded || showsSelfCheck || showsDiagnostics || quotaLayoutSignal.requiresScrolling
    }

    private var quotaLayoutSignal: StatusPopoverFormatting.QuotaWindowLayoutSignal {
        StatusPopoverFormatting.quotaWindowLayoutSignal(
            snapshot: presentationSnapshot.snapshot,
            status: presentationSnapshot.status,
            columns: 2
        )
    }

    @ViewBuilder
    private var panelContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            QuotaSummaryView(
                presentationSnapshot: presentationSnapshot,
                showsAllResetCredits: $showsAllResetCredits,
                showsResetCreditFields: $showsResetCreditFields,
                onLayoutChange: { expanded in
                    guard isQuotaExpanded != expanded else { return }
                    isQuotaExpanded = expanded
                    onLayoutChange()
                }
            )
            launchAtLoginSection
            actions
            diagnostics
        }
        .padding(12)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            ReactorView(isPanelActive: isPanelActive, allowsAnimation: false)
                .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text("Codex Monitor")
                        .font(.headline.weight(.semibold))
                    Text("Native")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(MetallicPalette.redBright)
                }
                Text(statusLine)
                    .font(.caption)
                    .foregroundStyle(MetallicPalette.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if presentationSnapshot.status == .refreshing {
                ProgressView()
                    .controlSize(.small)
                    .tint(MetallicPalette.redBright)
            } else {
                Image(systemName: "arrow.clockwise")
                    .font(.headline.weight(.medium))
                    .foregroundStyle(MetallicPalette.muted)
            }
            Text(refreshTimeText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(MetallicPalette.muted)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Codex Monitor Native，\(statusLine)，更新时间 \(refreshTimeText)")
    }

    private var statusLine: String {
        StatusPopoverFormatting.titleSummary(for: presentationSnapshot.status)
    }

    private var refreshTimeText: String {
        presentationSnapshot.snapshot.refreshedAt.formatted(date: .omitted, time: .shortened)
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
        HStack(spacing: 8) {
            Image(systemName: "power")
                .font(.headline.weight(.semibold))
                .foregroundStyle(launchAtLoginManager.shouldLaunchAtLogin ? Color.green : MetallicPalette.red)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                if usesCompactLaunchAtLoginSection {
                    Text("开机启动 · 已启用")
                        .font(.subheadline.weight(.medium))
                } else {
                    Text("开机启动")
                        .font(.subheadline.weight(.medium))
                    Text(launchAtLoginManager.helperText)
                        .font(.caption2)
                        .foregroundStyle(MetallicPalette.muted)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if usesCompactLaunchAtLoginSection {
                launchAtLoginToggle(controlSize: .mini, isLowEmphasis: true)
            } else {
                launchAtLoginToggle(controlSize: .small, isLowEmphasis: false)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(MetallicPalette.card)
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(MetallicPalette.border, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var usesCompactLaunchAtLoginSection: Bool {
        launchAtLoginManager.statusInfo == .enabled
    }

    private func launchAtLoginToggle(controlSize: ControlSize, isLowEmphasis: Bool) -> some View {
        let dimension: CGFloat = isLowEmphasis ? 22 : 24

        return Toggle(isOn: launchAtLoginBinding) {
            ZStack {
                Circle()
                    .fill(
                        launchAtLoginManager.shouldLaunchAtLogin
                            ? MetallicPalette.red
                            : MetallicPalette.red.opacity(0.12)
                    )
                    .overlay {
                        Circle()
                            .stroke(
                                launchAtLoginManager.shouldLaunchAtLogin
                                    ? MetallicPalette.redBright
                                    : MetallicPalette.red.opacity(0.9),
                                lineWidth: 2
                            )
                    }

                if launchAtLoginManager.isUpdating {
                    ProgressView()
                        .controlSize(controlSize)
                        .tint(.white)
                } else if launchAtLoginManager.shouldLaunchAtLogin {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .black))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: dimension, height: dimension)
            .shadow(
                color: launchAtLoginManager.shouldLaunchAtLogin
                    ? MetallicPalette.red.opacity(0.45)
                    : .clear,
                radius: 4
            )
            .contentShape(Rectangle())
        }
            .toggleStyle(.button)
            .buttonStyle(.plain)
            .disabled(launchAtLoginManager.isUpdating)
            .accessibilityLabel("开机启动")
            .accessibilityValue(launchAtLoginAccessibilityValue)
            .accessibilityHint("开启或关闭登录时自动启动")
            .accessibilityIdentifier("launch-at-login-toggle")
            .help("开机启动")
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button(action: onRefresh) {
                Label("刷新", systemImage: "arrow.clockwise")
                    .font(.subheadline.weight(.medium))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(MetallicPalette.redBright)
            .disabled(presentationSnapshot.status == .refreshing)
            .keyboardShortcut("r", modifiers: .command)
            .accessibilityLabel("刷新额度")
            .accessibilityValue(presentationSnapshot.status == .refreshing ? "正在刷新" : "可刷新")
            .accessibilityHint("立即更新额度数据")
            .accessibilityIdentifier("refresh-button")

            Spacer()

            Button(action: onQuit) {
                Label("退出", systemImage: "rectangle.portrait.and.arrow.right")
                    .font(.subheadline.weight(.medium))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(MetallicPalette.foreground)
            .keyboardShortcut("q", modifiers: .command)
            .accessibilityLabel("退出 Codex Monitor")
            .accessibilityHint("退出应用")
            .accessibilityIdentifier("quit-button")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var diagnostics: some View {
        if let refreshSummaryLine {
            Text(refreshSummaryLine)
                .font(.caption2)
                .foregroundStyle(MetallicPalette.muted)
                .lineLimit(2)
        }

        DisclosureGroup("自检", isExpanded: $showsSelfCheck) {
            selfCheckSection
        }
        .font(.caption)
        .tint(MetallicPalette.muted)
        .accessibilityValue(showsSelfCheck ? "已展开" : "已折叠")
        .accessibilityHint("显示或隐藏自检信息")
        .accessibilityIdentifier("self-check-disclosure")

        if hasDiagnosticsContent {
            DisclosureGroup("诊断", isExpanded: $showsDiagnostics) {
                VStack(alignment: .leading, spacing: 6) {
                    if let supportLine { Text(supportLine) }
                    if let loginError = launchAtLoginManager.lastErrorSummary { Text(loginError) }
                }
                .font(.caption2)
                .foregroundStyle(MetallicPalette.muted)
                .padding(.top, 4)
            }
            .font(.caption)
            .tint(MetallicPalette.muted)
            .accessibilityValue(showsDiagnostics ? "已展开" : "已折叠")
            .accessibilityHint("显示或隐藏诊断信息")
            .accessibilityIdentifier("diagnostics-disclosure")
        }
    }

    private var launchAtLoginAccessibilityValue: String {
        if launchAtLoginManager.isUpdating {
            return "正在更新"
        }
        return launchAtLoginManager.shouldLaunchAtLogin ? "已开启" : "已关闭"
    }

    private var environmentInfoLine: String? {
        StatusPopoverFormatting.environmentInfoLine(
            lastSuccess: presentationSnapshot.lastSuccessAt,
            lastAttempt: presentationSnapshot.lastAttemptAt,
            dataSource: presentationSnapshot.snapshot.dataSource,
            status: presentationSnapshot.status,
            showsSourceStatus: hasDisplayableSourceStatus
        )
    }

    private var hasDisplayableSourceStatus: Bool {
        presentationSnapshot.snapshot.dataSource == .real || presentationSnapshot.status == .demoMode
    }

    private var selfCheckSnapshot: StatusSelfCheckSnapshot {
        StatusSelfCheckSnapshot.capture(appState: appState)
    }

    private var selfCheckSection: some View {
        let snapshot = selfCheckSnapshot
        return VStack(alignment: .leading, spacing: 6) {
            selfCheckRow(title: "版本", value: snapshot.version)
            selfCheckRow(title: "安装", value: snapshot.installPath)
            selfCheckRow(title: "最近刷新", value: snapshot.refreshSummary)
            selfCheckRow(title: "Widget", value: snapshot.widgetSummary)
        }
        .font(.caption2)
        .foregroundStyle(MetallicPalette.muted)
        .padding(.top, 4)
    }

    private func selfCheckRow(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(MetallicPalette.foreground)
            Text(value)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var supportLine: String? {
        switch presentationSnapshot.status {
        case .refreshing:
            return "正在刷新，先显示当前快照"
        case .networkFailed, .authRequired, .parseFailed:
            if let refreshError = appState.lastErrorSummary {
                if let environmentInfoLine { return "\(environmentInfoLine) · \(refreshError)" }
                return refreshError
            }
            return environmentInfoLine
        case .stale:
            return environmentInfoLine
        default:
            if let refreshError = appState.lastErrorSummary { return refreshError }
            let healthLine = StatusPopoverFormatting.realQuotaHealthLine(appState.realQuotaHealth)
            switch appState.realQuotaHealth.kind {
            case .requestSucceeded: return nil
            case .waitingForFirstRequest where !hasDisplayableSourceStatus: return nil
            default: return healthLine
            }
        }
    }

    private var refreshSummaryLine: String? {
        StatusPopoverFormatting.freshnessSummary(
            for: presentationSnapshot.status,
            isUsingCachedSnapshot: appState.isUsingCachedSnapshot
        )
    }

    private var hasDiagnosticsContent: Bool {
        supportLine != nil || launchAtLoginManager.lastErrorSummary != nil
    }
}
