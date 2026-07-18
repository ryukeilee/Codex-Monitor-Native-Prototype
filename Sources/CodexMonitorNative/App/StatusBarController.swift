import AppKit
import Combine

@MainActor
final class StatusBarController {
    let statusItem: NSStatusItem
    private var cancellables = Set<AnyCancellable>()
    private(set) var isTornDown = false

    var statusButton: NSStatusBarButton? {
        statusItem.button
    }

    init(appState: AppState) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.isVisible = true
        configureButton()

        appState.$stateEvent
            .receive(on: RunLoop.main)
            .sink { [weak self] stateEvent in
                self?.updateTitle(with: stateEvent.presentationSnapshot)
            }
            .store(in: &cancellables)
    }

    func setTarget(_ target: AnyObject, action: Selector) {
        guard !isTornDown else { return }
        guard let button = statusItem.button else {
            AppLogger.statusBar.error("Failed to assign target because status button was nil")
            return
        }

        button.target = target
        button.action = action
        button.sendAction(on: [.leftMouseUp])
        AppLogger.statusBar.info("Assigned click target to status item")
    }

    func teardown() {
        guard !isTornDown else { return }
        isTornDown = true
        cancellables.removeAll()
        statusItem.button?.target = nil
        statusItem.button?.action = nil
        statusItem.isVisible = false
        NSStatusBar.system.removeStatusItem(statusItem)
        AppLogger.statusBar.info("Removed status item during owner shutdown")
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

    private func updateTitle(with presentationSnapshot: QuotaPresentationSnapshot) {
        let snapshot = presentationSnapshot.snapshot
        let status = presentationSnapshot.status
        let title: String

        switch status {
        case .success:
            fallthrough
        case .stale:
            // status bar title displays weekly quota, while 5h quota remains in dropdown.
            title = weeklyQuotaTitle(for: snapshot, status: status)

        case .refreshing:
            // Keep last value, never flash empty
            title = weeklyQuotaTitle(for: snapshot, status: status)

        case .networkFailed, .authRequired, .parseFailed:
            // Error state: show last real weekly % if available, otherwise placeholder.
            title = weeklyQuotaTitle(for: snapshot, status: status)

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

    private func weeklyQuotaTitle(for snapshot: QuotaSnapshot, status: QuotaRefreshStatus) -> String {
        StatusPopoverFormatting.weeklyQuotaMenuTitle(
            snapshot: snapshot,
            status: status
        )
    }

    private func tooltip(for snapshot: QuotaSnapshot, status: QuotaRefreshStatus) -> String {
        StatusPopoverFormatting.quotaTooltip(
            snapshot: snapshot,
            status: status
        )
    }

    private func applyTitle(_ title: String) {
        guard let button = statusItem.button else {
            return
        }

        button.title = title
    }
}
