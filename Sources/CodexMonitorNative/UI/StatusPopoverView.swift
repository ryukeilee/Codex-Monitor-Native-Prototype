import SwiftUI

struct StatusPopoverView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var launchAtLoginManager: LaunchAtLoginManager
    let onRefresh: () -> Void
    let onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Codex Monitor Native")
                    .font(.headline.weight(.semibold))
                    .lineLimit(1)

                Text(StatusPopoverFormatting.titleSummary(for: appState.status))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)

                if let refreshError = appState.lastErrorSummary {
                    Text(refreshError)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            QuotaSummaryView(appState: appState)

            Divider()
                .opacity(0.55)

            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Launch at Login")
                        .font(.subheadline.weight(.medium))

                    Text(launchAtLoginManager.helperText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 8)

                Toggle("", isOn: launchAtLoginBinding)
                    .labelsHidden()
                    .disabled(launchAtLoginManager.isUpdating)
                    .controlSize(.small)
                    .accessibilityLabel("Launch at Login")
            }

            if let loginError = launchAtLoginManager.lastErrorSummary {
                Text(loginError)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Divider()
                .opacity(0.55)

            HStack(spacing: 8) {
                Button(action: onRefresh) {
                    if appState.isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("Refresh")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(appState.isRefreshing)
                .frame(minWidth: 84)

                Spacer()

                Button("Quit", action: onQuit)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .controlSize(.small)
            }
        }
        .padding(12)
        .frame(width: 318)
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
}
