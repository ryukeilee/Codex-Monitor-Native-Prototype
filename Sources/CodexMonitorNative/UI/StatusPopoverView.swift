import SwiftUI

struct StatusPopoverView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var launchAtLoginManager: LaunchAtLoginManager
    let onRefresh: () -> Void
    let onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Codex Monitor Native")
                .font(.title3.weight(.semibold))

            QuotaSummaryView(appState: appState)

            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: launchAtLoginBinding) {
                    Text("Launch at Login")
                        .font(.headline)
                }
                .disabled(launchAtLoginManager.isUpdating)

                Text(launchAtLoginManager.helperText)
                    .font(.caption)
                    .foregroundStyle(launchAtLoginManager.statusInfo == .requiresApproval ? .orange : .secondary)
            }

            HStack(spacing: 12) {
                Button(action: onRefresh) {
                    if appState.isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("Refresh")
                    }
                }
                .disabled(appState.isRefreshing)

                Spacer()

                Button("Quit", role: .destructive, action: onQuit)
            }
        }
        .padding(16)
        .frame(width: 340)
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
