import AppKit
import ServiceManagement
import SwiftUI
import XCTest
@testable import CodexMonitorNative

@MainActor
final class StatusPopoverBehaviorTests: XCTestCase {
    func testPopoverCommandShortcutsInvokeActionsAndRespectRefreshingState() async {
        let suiteName = "CodexMonitorNativeTests.keyboard.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let appState = AppState(
            snapshotStore: SnapshotStore(defaults: defaults, key: "snapshot"),
            refreshService: SuspendedSnapshotRefreshService()
        )
        defer { appState.shutdown() }

        let launchManager = LaunchAtLoginManager(
            loginItemManager: SnapshotLoginItemManager(status: .enabled)
        )
        var refreshCount = 0
        var quitCount = 0
        let hostingView = NSHostingView(
            rootView: StatusPopoverView(
                appState: appState,
                launchAtLoginManager: launchManager,
                onRefresh: { refreshCount += 1 },
                onQuit: { quitCount += 1 }
            )
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: 340, height: 560)

        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.makeKey()
        hostingView.layoutSubtreeIfNeeded()

        XCTAssertTrue(performCommandShortcut("r", keyCode: 15, in: window))
        XCTAssertEqual(refreshCount, 1)

        appState.refresh(trigger: .manual)
        await Task.yield()
        hostingView.layoutSubtreeIfNeeded()
        XCTAssertFalse(performCommandShortcut("r", keyCode: 15, in: window))
        XCTAssertEqual(refreshCount, 1)

        XCTAssertTrue(performCommandShortcut("q", keyCode: 12, in: window))
        XCTAssertEqual(quitCount, 1)
    }

    func testScrollViewportPolicyCoversExpandedAndOverflowingContent() {
        let compact = StatusPopoverFormatting.QuotaWindowLayoutSignal(
            itemTokens: ["weekly"],
            rowCount: 1,
            requiresScrolling: false
        )
        let overflowing = StatusPopoverFormatting.QuotaWindowLayoutSignal(
            itemTokens: ["five-hour", "weekly", "monthly", "quarterly", "yearly"],
            rowCount: 3,
            requiresScrolling: true
        )

        XCTAssertFalse(
            StatusPopoverInteractionPolicy.requiresScrollableViewport(
                isQuotaExpanded: false,
                isDiagnosticsExpanded: false,
                hasDiagnosticsContent: false,
                quotaLayoutSignal: compact
            )
        )
        XCTAssertTrue(
            StatusPopoverInteractionPolicy.requiresScrollableViewport(
                isQuotaExpanded: true,
                isDiagnosticsExpanded: false,
                hasDiagnosticsContent: false,
                quotaLayoutSignal: compact
            )
        )
        XCTAssertTrue(
            StatusPopoverInteractionPolicy.requiresScrollableViewport(
                isQuotaExpanded: false,
                isDiagnosticsExpanded: true,
                hasDiagnosticsContent: true,
                quotaLayoutSignal: compact
            )
        )
        XCTAssertFalse(
            StatusPopoverInteractionPolicy.requiresScrollableViewport(
                isQuotaExpanded: false,
                isDiagnosticsExpanded: true,
                hasDiagnosticsContent: false,
                quotaLayoutSignal: compact
            )
        )
        XCTAssertTrue(
            StatusPopoverInteractionPolicy.requiresScrollableViewport(
                isQuotaExpanded: false,
                isDiagnosticsExpanded: false,
                hasDiagnosticsContent: false,
                quotaLayoutSignal: overflowing
            )
        )
        XCTAssertEqual(StatusPopoverInteractionPolicy.expandedViewportHeight, 520)
    }

    func testDiagnosticsLayoutSignalTracksAppearanceAndRemoval() {
        let hidden = StatusPopoverInteractionPolicy.DiagnosticsLayoutSignal(
            refreshSummaryLine: nil,
            supportLine: nil,
            launchAtLoginErrorSummary: nil
        )
        let refreshing = StatusPopoverInteractionPolicy.DiagnosticsLayoutSignal(
            refreshSummaryLine: "读取中",
            supportLine: "正在刷新，先显示当前快照",
            launchAtLoginErrorSummary: nil
        )

        XCTAssertFalse(hidden.hasDisclosureContent)
        XCTAssertTrue(refreshing.hasDisclosureContent)
        XCTAssertNotEqual(hidden, refreshing)
    }

    func testQuotaDisclosureLayoutPolicyPropagatesNestedExpansionOnlyWhenNeeded() {
        XCTAssertFalse(
            QuotaDisclosureLayoutPolicy.requiresParentViewport(
                showsAllResetCredits: false,
                showsResetCreditFields: false
            )
        )
        XCTAssertTrue(
            QuotaDisclosureLayoutPolicy.requiresParentViewport(
                showsAllResetCredits: true,
                showsResetCreditFields: false
            )
        )
        XCTAssertTrue(
            QuotaDisclosureLayoutPolicy.requiresParentViewport(
                showsAllResetCredits: false,
                showsResetCreditFields: true
            )
        )
        XCTAssertFalse(StatusPopoverInteractionPolicy.shouldNotifyQuotaLayoutChange(current: false, next: false))
        XCTAssertTrue(StatusPopoverInteractionPolicy.shouldNotifyQuotaLayoutChange(current: false, next: true))
        XCTAssertTrue(StatusPopoverInteractionPolicy.shouldNotifyQuotaLayoutChange(current: true, next: false))
    }

    func testAccessibilityContractPublishesStableControlState() {
        XCTAssertEqual(
            StatusPopoverAccessibilityContract.launchAtLoginValue(isUpdating: false, isEnabled: false),
            "已关闭"
        )
        XCTAssertEqual(
            StatusPopoverAccessibilityContract.launchAtLoginValue(isUpdating: false, isEnabled: true),
            "已开启"
        )
        XCTAssertEqual(
            StatusPopoverAccessibilityContract.launchAtLoginValue(isUpdating: true, isEnabled: true),
            "正在更新"
        )
        XCTAssertEqual(StatusPopoverAccessibilityContract.refreshValue(for: .success), "可刷新")
        XCTAssertEqual(StatusPopoverAccessibilityContract.refreshValue(for: .refreshing), "正在刷新")
        XCTAssertEqual(StatusPopoverAccessibilityContract.disclosureValue(isExpanded: false), "已折叠")
        XCTAssertEqual(StatusPopoverAccessibilityContract.disclosureValue(isExpanded: true), "已展开")
        XCTAssertEqual(
            [
                StatusPopoverAccessibilityContract.launchAtLoginToggleIdentifier,
                StatusPopoverAccessibilityContract.refreshButtonIdentifier,
                StatusPopoverAccessibilityContract.quitButtonIdentifier,
                StatusPopoverAccessibilityContract.diagnosticsDisclosureIdentifier,
                StatusPopoverAccessibilityContract.resetCreditsDisclosureIdentifier,
                StatusPopoverAccessibilityContract.resetCreditFieldsDisclosureIdentifier
            ],
            [
                "launch-at-login-toggle",
                "refresh-button",
                "quit-button",
                "diagnostics-disclosure",
                "reset-credits-disclosure",
                "reset-credit-fields-disclosure"
            ]
        )
    }

    func testEscapeClosePolicyOnlyClosesVisiblePopover() {
        XCTAssertTrue(PopoverController.shouldCloseForKeyEvent(keyCode: 53, isShown: true))
        XCTAssertFalse(PopoverController.shouldCloseForKeyEvent(keyCode: 53, isShown: false))
        XCTAssertFalse(PopoverController.shouldCloseForKeyEvent(keyCode: 36, isShown: true))
    }

    func testPopoverContentSizeClampsAcrossVisibleFrameOriginsAndSizes() {
        let fittingSize = NSSize(width: 390, height: 650)

        let primary = PopoverController.clampedContentSize(
            fittingSize: fittingSize,
            visibleFrame: NSRect(x: 0, y: 0, width: 2560, height: 1664)
        )
        let secondaryOrigin = PopoverController.clampedContentSize(
            fittingSize: fittingSize,
            visibleFrame: NSRect(x: 1440, y: -120, width: 1920, height: 1080)
        )
        let narrowDisplay = PopoverController.clampedContentSize(
            fittingSize: fittingSize,
            visibleFrame: NSRect(x: -800, y: 40, width: 320, height: 420)
        )

        XCTAssertEqual(primary, NSSize(width: 340, height: 560))
        XCTAssertEqual(secondaryOrigin, NSSize(width: 340, height: 560))
        XCTAssertEqual(narrowDisplay, NSSize(width: 296, height: 396))
    }

    func testPopoverContentSizeRejectsInflatedHostingHeight() {
        let measured = PopoverController.clampedContentSize(
            fittingSize: NSSize(width: 340, height: 1_100),
            visibleFrame: NSRect(x: 0, y: 0, width: 2560, height: 1664)
        )

        XCTAssertEqual(measured.width, 340)
        XCTAssertLessThanOrEqual(measured.height, 560)
    }

    func testPopoverLifecycleIgnoresStaleCloseAndLayoutCompletion() {
        var lifecycle = PopoverLifecycleState()
        let firstPresentation = lifecycle.beginPresentation()
        let staleLayout = lifecycle.beginLayoutUpdate()

        XCTAssertNotNil(staleLayout)
        lifecycle.cancelLayoutUpdate()
        let currentLayout = lifecycle.beginLayoutUpdate()
        XCTAssertNotNil(currentLayout)
        XCTAssertFalse(lifecycle.finishLayoutUpdate(staleLayout!))
        XCTAssertEqual(lifecycle.layoutUpdateToken, currentLayout)

        XCTAssertEqual(lifecycle.beginClosingCurrentPresentation(), firstPresentation)
        XCTAssertTrue(lifecycle.finishPresentation(firstPresentation))
        let secondPresentation = lifecycle.beginPresentation()
        let delayedClose = lifecycle.consumeClosingPresentationToken()

        XCTAssertEqual(delayedClose, firstPresentation)
        XCTAssertFalse(lifecycle.finishPresentation(delayedClose!))
        XCTAssertEqual(lifecycle.activePresentationToken, secondPresentation)
        XCTAssertFalse(lifecycle.shouldRunLayoutUpdate(currentLayout!, for: firstPresentation))
        XCTAssertNil(lifecycle.consumeClosingPresentationToken())
        XCTAssertEqual(lifecycle.activePresentationToken, secondPresentation)
    }

    func testPopoverMonitorResourcesStayBoundedAcrossRepeatedPresentationCycles() {
        final class MonitorToken {
            let id: Int

            init(id: Int) {
                self.id = id
            }
        }

        var removedIdentifiers: Set<Int> = []
        let resources = PopoverEventMonitorResources { monitor in
            removedIdentifiers.insert((monitor as! MonitorToken).id)
        }
        var installedIdentifiers: Set<Int> = []

        for cycle in 0..<1_000 {
            let identifiers = (0..<3).map { cycle * 3 + $0 }
            let monitors = identifiers.map(MonitorToken.init)
            installedIdentifiers.formUnion(identifiers)
            resources.install(
                localMouse: monitors[0],
                globalMouse: monitors[1],
                keyboard: monitors[2]
            )
            XCTAssertEqual(resources.activeCount, 3)
            resources.removeAll()
            XCTAssertEqual(resources.activeCount, 0)
        }

        XCTAssertEqual(removedIdentifiers, installedIdentifiers)

        resources.removeAll()
        XCTAssertEqual(removedIdentifiers.count, 3_000)
    }

    func testRealPopoverRepeatedToggleReclaimsMonitorsAndLayoutTask() async throws {
        _ = NSApplication.shared
        let suiteName = "CodexMonitorNativeTests.popoverLifecycle.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let appState = AppState(
            snapshotStore: SnapshotStore(defaults: defaults, key: "snapshot"),
            refreshService: SuspendedSnapshotRefreshService()
        )
        defer { appState.shutdown() }
        let launchManager = LaunchAtLoginManager(
            loginItemManager: SnapshotLoginItemManager(status: .enabled)
        )
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        defer { NSStatusBar.system.removeStatusItem(statusItem) }
        let button = try XCTUnwrap(statusItem.button)
        button.title = "--%"
        let controller = PopoverController(appState: appState, launchAtLoginManager: launchManager)

        for _ in 0..<50 {
            controller.toggle(relativeTo: button)
            XCTAssertTrue(controller.isPopoverShown)
            XCTAssertEqual(controller.activeEventMonitorCount, 3)

            controller.toggle(relativeTo: button)
            await Task.yield()
            XCTAssertFalse(controller.isPopoverShown)
            XCTAssertEqual(controller.activeEventMonitorCount, 0)
            XCTAssertFalse(controller.hasPendingLayoutUpdate)
        }
    }

    private func performCommandShortcut(_ character: String, keyCode: UInt16, in window: NSWindow) -> Bool {
        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .command,
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: character,
            charactersIgnoringModifiers: character,
            isARepeat: false,
            keyCode: keyCode
        )!
        return window.performKeyEquivalent(with: event)
    }

}

private struct SuspendedSnapshotRefreshService: QuotaRefreshing {
    func refresh(basedOn currentSnapshot: QuotaSnapshot) async throws -> QuotaSnapshot {
        try await Task.sleep(for: .seconds(60))
        return currentSnapshot
    }
}

private struct SnapshotLoginItemManager: LoginItemManaging {
    let status: SMAppService.Status

    func register() throws {}

    func unregister() throws {}
}
