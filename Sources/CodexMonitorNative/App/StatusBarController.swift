import AppKit
import Combine

@MainActor
final class StatusBarController {
    let statusItem: NSStatusItem
    private var cancellables = Set<AnyCancellable>()

    var statusButton: NSStatusBarButton? {
        statusItem.button
    }

    init(appState: AppState) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.isVisible = true
        configureButton()

        // Observe both snapshot and status changes to keep menu bar accurate
        appState.$snapshot
            .receive(on: RunLoop.main)
            .sink { [weak self] snapshot in
                self?.updateTitle(with: snapshot, status: appState.status)
            }
            .store(in: &cancellables)

        appState.$status
            .receive(on: RunLoop.main)
            .sink { [weak self] status in
                self?.updateTitle(with: appState.snapshot, status: status)
            }
            .store(in: &cancellables)
    }

    func setTarget(_ target: AnyObject, action: Selector) {
        guard let button = statusItem.button else {
            AppLogger.statusBar.error("Failed to assign target because status button was nil")
            return
        }

        button.target = target
        button.action = action
        button.sendAction(on: [.leftMouseUp])
        AppLogger.statusBar.info("Assigned click target to status item")
    }

    private func configureButton() {
        guard let button = statusItem.button else {
            AppLogger.statusBar.error("Failed to configure status item because button was nil")
            return
        }

        button.image = nil
        button.imagePosition = .noImage
        button.appearsDisabled = false
        applyTitle("--")
        button.toolTip = "Codex Monitor Native"
        button.setAccessibilityTitle("Codex Monitor Native")
        AppLogger.statusBar.info("Status item created; waiting for first quota data")
    }

    private func updateTitle(with snapshot: QuotaSnapshot, status: QuotaRefreshStatus) {
        let title: String

        switch status {
        case .success:
            fallthrough
        case .stale:
            // status bar title displays weekly quota, while 5h quota remains in dropdown.
            title = snapshot.dataSource == .real ? "\(snapshot.weeklyQuotaPercent)%" : "--%"

        case .refreshing:
            // Keep last value, never flash empty
            title = snapshot.dataSource == .real ? "\(snapshot.weeklyQuotaPercent)%" : "--%"

        case .networkFailed, .authRequired, .parseFailed:
            // Error state: show last real weekly % if available, otherwise placeholder.
            title = snapshot.dataSource == .real ? "\(snapshot.weeklyQuotaPercent)%" : "--%"

        case .noSnapshot, .idle:
            title = "--%"

        case .demoMode:
            title = "--%"
        }

        applyTitle(title)
        statusItem.button?.toolTip = tooltip(for: snapshot, status: status)
        statusItem.button?.setAccessibilityTitle("Codex Monitor Native \(title)")
        AppLogger.statusBar.info("Menu bar: \(title, privacy: .public) status=\(status.rawValue, privacy: .public)")
    }

    private func tooltip(for snapshot: QuotaSnapshot, status: QuotaRefreshStatus) -> String {
        switch status {
        case .success:
            return "Codex Monitor: 5h \(snapshot.fiveHourQuotaPercent)% · Weekly \(snapshot.weeklyQuotaPercent)%"
        case .refreshing:
            return "Codex Monitor: Refreshing…"
        case .networkFailed:
            return "Codex Monitor: Network error (showing last known data)"
        case .authRequired:
            return "Codex Monitor: Auth required (showing last known data)"
        case .parseFailed:
            return "Codex Monitor: Parse error (showing last known data)"
        case .stale:
            return "Codex Monitor: Data is stale (showing last known data)"
        case .noSnapshot:
            return "Codex Monitor: Not connected"
        case .idle:
            return "Codex Monitor: Waiting for first refresh"
        case .demoMode:
            return "Codex Monitor Native (Demo Mode)"
        }
    }

    private func applyTitle(_ title: String) {
        guard let button = statusItem.button else {
            return
        }

        button.title = title
    }
}
