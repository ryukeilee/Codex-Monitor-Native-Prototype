import SwiftUI

struct StatusPopoverView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var launchAtLoginManager: LaunchAtLoginManager
    let onRefresh: () -> Void
    let onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Codex Monitor Native")
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)

                Text(StatusPopoverFormatting.titleSummary(for: appState.status))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)
            }

            QuotaSummaryView(appState: appState)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: launchAtLoginBinding) {
                    Text("Launch at Login")
                }
                .disabled(launchAtLoginManager.isUpdating)
            }

            Divider()

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
        .padding(14)
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
