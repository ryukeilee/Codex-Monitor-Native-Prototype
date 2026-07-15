import AppKit
import SwiftUI

struct PopoverLifecycleState {
    typealias Token = UInt64

    private var nextToken: Token = 0
    private(set) var activePresentationToken: Token?
    private(set) var closingPresentationToken: Token?
    private(set) var layoutUpdateToken: Token?

    mutating func beginPresentation() -> Token {
        let token = makeToken()
        activePresentationToken = token
        return token
    }

    mutating func beginClosingCurrentPresentation() -> Token? {
        guard let activePresentationToken else { return nil }
        closingPresentationToken = activePresentationToken
        return activePresentationToken
    }

    mutating func consumeClosingPresentationToken() -> Token? {
        let token = closingPresentationToken
        closingPresentationToken = nil
        return token
    }

    mutating func finishPresentation(_ token: Token) -> Bool {
        guard activePresentationToken == token else { return false }
        activePresentationToken = nil
        return true
    }

    func isActivePresentation(_ token: Token) -> Bool {
        activePresentationToken == token
    }

    mutating func beginLayoutUpdate() -> Token? {
        guard activePresentationToken != nil, layoutUpdateToken == nil else { return nil }
        let token = makeToken()
        layoutUpdateToken = token
        return token
    }

    func shouldRunLayoutUpdate(_ token: Token, for presentationToken: Token) -> Bool {
        layoutUpdateToken == token && activePresentationToken == presentationToken
    }

    @discardableResult
    mutating func finishLayoutUpdate(_ token: Token) -> Bool {
        guard layoutUpdateToken == token else { return false }
        layoutUpdateToken = nil
        return true
    }

    mutating func cancelLayoutUpdate() {
        layoutUpdateToken = nil
    }

    private mutating func makeToken() -> Token {
        nextToken &+= 1
        if nextToken == 0 {
            nextToken &+= 1
        }
        return nextToken
    }
}

final class PopoverEventMonitorResources {
    private let removeMonitor: (Any) -> Void
    private(set) var localMouse: Any?
    private(set) var globalMouse: Any?
    private(set) var keyboard: Any?

    init(removeMonitor: @escaping (Any) -> Void) {
        self.removeMonitor = removeMonitor
    }

    var activeCount: Int {
        [localMouse, globalMouse, keyboard].compactMap { $0 }.count
    }

    func install(localMouse: Any?, globalMouse: Any?, keyboard: Any?) {
        removeAll()
        self.localMouse = localMouse
        self.globalMouse = globalMouse
        self.keyboard = keyboard
    }

    func removeAll() {
        if let localMouse {
            removeMonitor(localMouse)
            self.localMouse = nil
        }
        if let globalMouse {
            removeMonitor(globalMouse)
            self.globalMouse = nil
        }
        if let keyboard {
            removeMonitor(keyboard)
            self.keyboard = nil
        }
    }
}

@MainActor
final class PopoverController: NSObject, NSPopoverDelegate {
    private static let contentWidth: CGFloat = 340
    private static let contentHeight: CGFloat = 560
    private let popover: NSPopover
    private let launchAtLoginManager: LaunchAtLoginManager
    private let presentationState: PopoverPresentationState
    private nonisolated(unsafe) let eventMonitors: PopoverEventMonitorResources
    private var lifecycle = PopoverLifecycleState()
    private var layoutUpdateTask: Task<Void, Never>?

    var isPopoverShown: Bool { popover.isShown }
    var activeEventMonitorCount: Int { eventMonitors.activeCount }
    var hasPendingLayoutUpdate: Bool { layoutUpdateTask != nil }

    init(appState: AppState, launchAtLoginManager: LaunchAtLoginManager) {
        let popover = NSPopover()
        let presentationState = PopoverPresentationState(isPanelActive: false)
        popover.behavior = .applicationDefined
        popover.animates = false
        popover.contentSize = NSSize(width: Self.contentWidth, height: Self.contentHeight)

        self.popover = popover
        self.launchAtLoginManager = launchAtLoginManager
        self.presentationState = presentationState
        self.eventMonitors = PopoverEventMonitorResources(removeMonitor: NSEvent.removeMonitor)
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
        eventMonitors.removeAll()
        layoutUpdateTask?.cancel()
    }

    func toggle(relativeTo button: NSStatusBarButton) {
        if popover.isShown {
            closePopover()
        } else {
            AppLogger.popover.info("Showing popover")
            let presentationToken = lifecycle.beginPresentation()
            // Re-read the login item status right before presenting the popover
            // so the checkbox reflects system state instead of a stale cached value.
            launchAtLoginManager.refreshStatus()
            presentationState.setPanelActive(true)
            updateContentSize(for: button)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.becomeKey()
            installOutsideClickMonitors(for: presentationToken)
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
        guard let presentationToken = lifecycle.activePresentationToken else { return }
        guard let layoutToken = lifecycle.beginLayoutUpdate() else { return }

        layoutUpdateTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            defer { finishLayoutUpdate(layoutToken) }
            guard !Task.isCancelled else { return }
            guard lifecycle.shouldRunLayoutUpdate(layoutToken, for: presentationToken) else { return }
            guard popover.isShown else { return }
            updateContentSize()
        }
    }

    private func cancelPendingLayoutUpdate() {
        lifecycle.cancelLayoutUpdate()
        layoutUpdateTask?.cancel()
        layoutUpdateTask = nil
    }

    private func finishLayoutUpdate(_ token: PopoverLifecycleState.Token) {
        guard lifecycle.finishLayoutUpdate(token) else { return }
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
        guard let presentationToken = lifecycle.beginClosingCurrentPresentation() else { return }
        AppLogger.popover.info("Closing popover")
        finishPresentation(presentationToken)
        popover.performClose(nil)
    }

    private func finishPresentation(_ token: PopoverLifecycleState.Token) {
        guard lifecycle.finishPresentation(token) else { return }
        cancelPendingLayoutUpdate()
        presentationState.setPanelActive(false)
        eventMonitors.removeAll()
    }

    private func installOutsideClickMonitors(for presentationToken: PopoverLifecycleState.Token) {
        eventMonitors.removeAll()

        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]

        let localMouse = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self else {
                return event
            }
            guard lifecycle.isActivePresentation(presentationToken) else { return event }

            if shouldClose(for: event) {
                AppLogger.popover.info("Closing popover because of outside local click")
                closePopover()
                return nil
            }

            return event
        }

        let globalMouse = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self else {
                return
            }
            guard lifecycle.isActivePresentation(presentationToken) else { return }

            if shouldClose(for: event) {
                AppLogger.popover.info("Closing popover because of outside global click")
                closePopover()
            }
        }

        let keyboard = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            guard lifecycle.isActivePresentation(presentationToken) else { return event }
            guard Self.shouldCloseForKeyEvent(keyCode: event.keyCode, isShown: popover.isShown) else { return event }
            AppLogger.popover.info("Closing popover because of Escape")
            closePopover()
            return nil
        }
        eventMonitors.install(localMouse: localMouse, globalMouse: globalMouse, keyboard: keyboard)
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

    func popoverWillClose(_ notification: Notification) {
        _ = lifecycle.beginClosingCurrentPresentation()
    }

    func popoverDidClose(_ notification: Notification) {
        guard let presentationToken = lifecycle.consumeClosingPresentationToken() else { return }
        finishPresentation(presentationToken)
    }
}
