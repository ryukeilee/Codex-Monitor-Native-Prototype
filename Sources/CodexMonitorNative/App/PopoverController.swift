import AppKit
import SwiftUI

@MainActor
final class PopoverController: NSObject, NSPopoverDelegate {
    private let popover: NSPopover
    private var localEventMonitor: Any?
    private var globalEventMonitor: Any?

    init(appState: AppState, launchAtLoginManager: LaunchAtLoginManager) {
        let popover = NSPopover()
        popover.behavior = .applicationDefined
        popover.animates = false
        popover.contentSize = NSSize(width: 340, height: 380)
        popover.contentViewController = NSHostingController(
            rootView: StatusPopoverView(
                appState: appState,
                launchAtLoginManager: launchAtLoginManager,
                onRefresh: {
                    appState.refresh(trigger: .manual)
                },
                onQuit: {
                    NSApp.terminate(nil)
                }
            )
        )

        self.popover = popover
        super.init()
        self.popover.delegate = self
    }

    func toggle(relativeTo button: NSStatusBarButton) {
        if popover.isShown {
            closePopover()
        } else {
            AppLogger.popover.info("Showing popover")
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.becomeKey()
            installOutsideClickMonitors()
        }
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
