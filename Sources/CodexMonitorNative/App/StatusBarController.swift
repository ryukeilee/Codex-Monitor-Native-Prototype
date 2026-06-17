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

        appState.$snapshot
            .receive(on: RunLoop.main)
            .sink { [weak self] snapshot in
                self?.updateTitle(with: snapshot)
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
        applyTitle("CM")
        button.toolTip = "Codex Monitor Native"
        button.setAccessibilityTitle("Codex Monitor Native")
        AppLogger.statusBar.info("Status item created; waiting for first quota data")
    }

    private func updateTitle(with snapshot: QuotaSnapshot) {
        let title: String

        switch snapshot.dataSource {
        case .real:
            title = "\(snapshot.weeklyQuotaPercent)%"
        case .mock:
            title = "Demo"
        }

        applyTitle(title)
        statusItem.button?.toolTip = tooltip(for: snapshot)
        statusItem.button?.setAccessibilityTitle("Codex Monitor Native \(title)")
        AppLogger.statusBar.info("Menu bar updated: \(title, privacy: .public) (source=\(snapshot.dataSource.rawValue, privacy: .public))")
    }

    private func tooltip(for snapshot: QuotaSnapshot) -> String {
        switch snapshot.dataSource {
        case .real:
            return "Codex Monitor: Weekly \(snapshot.weeklyQuotaPercent)% · 5h \(snapshot.fiveHourQuotaPercent)%"
        case .mock:
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
