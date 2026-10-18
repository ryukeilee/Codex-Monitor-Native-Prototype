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
        let status = presentationSnapshot.effectiveStatus(at: .now)
        let presentation = StatusPopoverFormatting.statusItemPresentation(
            snapshot: snapshot,
            status: status
        )
        let title: String

        // Only states with no trusted weekly value fall back to the
        // placeholder. Success, stale, refreshing, and every typed failure keep
        // showing the last real weekly percentage rather than flashing empty.
        switch status {
        case .noSnapshot, .idle, .demoMode:
            title = "--%"

        case .success, .stale, .refreshing, .networkFailed, .authRequired, .parseFailed:
            title = presentation.title
        }

        applyTitle(title)
        statusItem.button?.toolTip = presentation.tooltip
        statusItem.button?.setAccessibilityTitle("Codex Monitor Native \(title)")
        AppLogger.statusBar.info("Menu bar: \(title, privacy: .public) status=\(status.rawValue, privacy: .public)")
    }

    private func applyTitle(_ title: String) {
        guard let button = statusItem.button else {
            return
        }

        button.title = title
    }
}
