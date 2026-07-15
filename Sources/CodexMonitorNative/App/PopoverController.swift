import AppKit
import SwiftUI

@MainActor
final class PopoverController: NSObject, NSPopoverDelegate {
    private static let contentWidth: CGFloat = 340
    private static let contentHeight: CGFloat = 560
    private let popover: NSPopover
    private let launchAtLoginManager: LaunchAtLoginManager
    private let presentationState: PopoverPresentationState
    private nonisolated(unsafe) var localEventMonitor: Any?
    private nonisolated(unsafe) var globalEventMonitor: Any?
    private nonisolated(unsafe) var keyboardEventMonitor: Any?
    private var layoutUpdateTask: Task<Void, Never>?

    init(appState: AppState, launchAtLoginManager: LaunchAtLoginManager) {
        let popover = NSPopover()
        let presentationState = PopoverPresentationState(isPanelActive: false)
        popover.behavior = .applicationDefined
        popover.animates = false
        popover.contentSize = NSSize(width: Self.contentWidth, height: Self.contentHeight)

        self.popover = popover
        self.launchAtLoginManager = launchAtLoginManager
        self.presentationState = presentationState
        super.init()

        var hostingController: NSHostingController<StatusPopoverView>?
        let rootView = StatusPopoverView(
            appState: appState,
            launchAtLoginManager: launchAtLoginManager,
            presentationState: presentationState,
            onRefresh: {
                appState.refresh(trigger: .manual)
            },
            onQuit: {
                NSApp.terminate(nil)
            },
            onLayoutChange: { [weak self] in
                self?.scheduleLayoutUpdate()
            }
        )
        hostingController = NSHostingController(rootView: rootView)
        popover.contentViewController = hostingController
        self.popover.delegate = self
    }

    deinit {
        // Deinitialization is nonisolated under Swift 6; clean up monitors directly.
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
        }
        if let globalEventMonitor {
            NSEvent.removeMonitor(globalEventMonitor)
        }
        if let keyboardEventMonitor {
            NSEvent.removeMonitor(keyboardEventMonitor)
        }
        layoutUpdateTask?.cancel()
    }

    func toggle(relativeTo button: NSStatusBarButton) {
        if popover.isShown {
            closePopover()
        } else {
            AppLogger.popover.info("Showing popover")
            // Re-read the login item status right before presenting the popover
            // so the checkbox reflects system state instead of a stale cached value.
            launchAtLoginManager.refreshStatus()
            presentationState.setPanelActive(true)
            updateContentSize(for: button)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.becomeKey()
            installOutsideClickMonitors()
        }
    }

    private func updateContentSize(for button: NSStatusBarButton? = nil) {
        guard let hostingController = popover.contentViewController as? NSHostingController<StatusPopoverView> else {
            return
        }

        let activeVisibleFrame = button?.window?.screen?.visibleFrame
            ?? popover.contentViewController?.view.window?.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? .zero
        let contentSize = Self.clampedContentSize(
            for: hostingController,
            visibleFrame: activeVisibleFrame
        )
        Self.applyContentSize(contentSize, to: hostingController, popover: popover)
    }

    private func scheduleLayoutUpdate() {
        guard popover.isShown else { return }
        guard layoutUpdateTask == nil else { return }

        layoutUpdateTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            defer { layoutUpdateTask = nil }
            guard popover.isShown else { return }
            updateContentSize()
        }
    }

    private func cancelPendingLayoutUpdate() {
        layoutUpdateTask?.cancel()
        layoutUpdateTask = nil
    }

    private static func applyContentSize(
        _ contentSize: NSSize,
        to hostingController: NSHostingController<StatusPopoverView>,
        popover: NSPopover
    ) {
        popover.contentSize = contentSize
        hostingController.view.setFrameSize(contentSize)
    }

    private static func clampedContentSize(
        for hostingController: NSHostingController<StatusPopoverView>,
        visibleFrame: NSRect
    ) -> NSSize {
        let availableWidth = visibleFrame.width > 0 ? max(1, visibleFrame.width - 24) : contentWidth
        let width = min(contentWidth, availableWidth)
        let hostingView = hostingController.view
        let previousFrame = hostingView.frame
        hostingView.frame = NSRect(x: 0, y: 0, width: width, height: 0)
        hostingView.layoutSubtreeIfNeeded()
        let fittingSize = hostingView.fittingSize
        hostingView.frame = previousFrame
        return clampedContentSize(fittingSize: fittingSize, visibleFrame: visibleFrame)
    }

    @MainActor
    static func clampedContentSize(fittingSize: NSSize, visibleFrame: NSRect) -> NSSize {
        let availableWidth = visibleFrame.width > 0 ? max(1, visibleFrame.width - 24) : contentWidth
        let width = min(contentWidth, availableWidth)
        let availableHeight = visibleFrame.height > 0 ? max(1, visibleFrame.height - 24) : contentHeight
        // SwiftUI can report an inflated height when measured with an unbounded
        // proposal. Keep the popover host tight to the intended panel envelope
        // instead of allowing a screen-height gray window around the content.
        let height = min(availableHeight, contentHeight, max(1, ceil(fittingSize.height)))
        return NSSize(width: width, height: height)
    }

    private func closePopover() {
        AppLogger.popover.info("Closing popover")
        cancelPendingLayoutUpdate()
        presentationState.setPanelActive(false)
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

        keyboardEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            guard Self.shouldCloseForKeyEvent(keyCode: event.keyCode, isShown: popover.isShown) else { return event }
            AppLogger.popover.info("Closing popover because of Escape")
            closePopover()
            return nil
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

        if let keyboardEventMonitor {
            NSEvent.removeMonitor(keyboardEventMonitor)
            self.keyboardEventMonitor = nil
        }
    }

    static func shouldCloseForKeyEvent(keyCode: UInt16, isShown: Bool) -> Bool {
        isShown && keyCode == 53
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
        cancelPendingLayoutUpdate()
        presentationState.setPanelActive(false)
        removeOutsideClickMonitors()
    }
}
