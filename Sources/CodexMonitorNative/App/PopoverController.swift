import AppKit
import SwiftUI

@MainActor
final class PopoverController: NSObject, NSPopoverDelegate {
    private static let contentWidth: CGFloat = 318
    private let popover: NSPopover
    private let launchAtLoginManager: LaunchAtLoginManager
    private var localEventMonitor: Any?
    private var globalEventMonitor: Any?

    init(appState: AppState, launchAtLoginManager: LaunchAtLoginManager) {
        let popover = NSPopover()
        popover.behavior = .applicationDefined
        popover.animates = false
        popover.contentSize = NSSize(width: Self.contentWidth, height: 268)
        var hostingController: NSHostingController<StatusPopoverView>?
        let rootView = StatusPopoverView(
            appState: appState,
            launchAtLoginManager: launchAtLoginManager,
            onRefresh: {
                appState.refresh(trigger: .manual)
            },
            onQuit: {
                NSApp.terminate(nil)
            },
            onLayoutChange: {
                guard popover.isShown, let hostingController else {
                    return
                }

                let fittingSize = hostingController.sizeThatFits(
                    in: NSSize(width: Self.contentWidth, height: .greatestFiniteMagnitude)
                )
                popover.contentSize = NSSize(width: Self.contentWidth, height: ceil(fittingSize.height))
            }
        )
        hostingController = NSHostingController(rootView: rootView)
        popover.contentViewController = hostingController

        self.popover = popover
        self.launchAtLoginManager = launchAtLoginManager
        super.init()
        self.popover.delegate = self
    }

    func toggle(relativeTo button: NSStatusBarButton) {
        if popover.isShown {
            closePopover()
        } else {
            AppLogger.popover.info("Showing popover")
            // Re-read the login item status right before presenting the popover
            // so the checkbox reflects system state instead of a stale cached value.
            launchAtLoginManager.refreshStatus()
            updateContentSize()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.becomeKey()
            installOutsideClickMonitors()
        }
    }

    private func updateContentSize() {
        guard let hostingController = popover.contentViewController as? NSHostingController<StatusPopoverView> else {
            return
        }

        let fittingSize = hostingController.sizeThatFits(
            in: NSSize(width: Self.contentWidth, height: .greatestFiniteMagnitude)
        )
        popover.contentSize = NSSize(width: Self.contentWidth, height: ceil(fittingSize.height))
    }

    private func closePopover() {
        AppLogger.popover.info("Closing popover")
        popover.performClose(nil)
        removeOutsideClickMonitors()
    }

    private func installOutsideClickMonitors() {
        removeOutsideClickMonitors()

        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]

        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self else {
                return event
            }

            if shouldClose(for: event) {
                AppLogger.popover.info("Closing popover because of outside local click")
                closePopover()
                return nil
            }

            return event
        }

        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self else {
                return
            }

            if shouldClose(for: event) {
                AppLogger.popover.info("Closing popover because of outside global click")
                closePopover()
            }
        }
    }

    private func removeOutsideClickMonitors() {
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
        }

        if let globalEventMonitor {
            NSEvent.removeMonitor(globalEventMonitor)
            self.globalEventMonitor = nil
        }
    }

    private func shouldClose(for event: NSEvent) -> Bool {
        guard popover.isShown else {
            return false
        }

        guard let popoverWindow = popover.contentViewController?.view.window else {
            return true
        }

        if event.window === popoverWindow {
            return false
        }

        let location = event.locationInWindow
        if let eventWindow = event.window {
            let screenPoint = eventWindow.convertPoint(toScreen: location)
            let localPoint = popoverWindow.convertPoint(fromScreen: screenPoint)
            return !popoverWindow.contentView!.bounds.contains(localPoint)
        }

        return true
    }

    func popoverDidClose(_ notification: Notification) {
        removeOutsideClickMonitors()
    }
}
