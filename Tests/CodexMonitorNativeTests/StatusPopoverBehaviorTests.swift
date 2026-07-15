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
                isSelfCheckExpanded: false,
                isDiagnosticsExpanded: false,
                quotaLayoutSignal: compact
            )
        )
        XCTAssertTrue(
            StatusPopoverInteractionPolicy.requiresScrollableViewport(
                isQuotaExpanded: true,
                isSelfCheckExpanded: false,
                isDiagnosticsExpanded: false,
                quotaLayoutSignal: compact
            )
        )
        XCTAssertTrue(
            StatusPopoverInteractionPolicy.requiresScrollableViewport(
                isQuotaExpanded: false,
                isSelfCheckExpanded: true,
                isDiagnosticsExpanded: false,
                quotaLayoutSignal: compact
            )
        )
        XCTAssertTrue(
            StatusPopoverInteractionPolicy.requiresScrollableViewport(
                isQuotaExpanded: false,
                isSelfCheckExpanded: false,
                isDiagnosticsExpanded: true,
                quotaLayoutSignal: compact
            )
        )
        XCTAssertTrue(
            StatusPopoverInteractionPolicy.requiresScrollableViewport(
                isQuotaExpanded: false,
                isSelfCheckExpanded: false,
                isDiagnosticsExpanded: false,
                quotaLayoutSignal: overflowing
            )
        )
        XCTAssertEqual(StatusPopoverInteractionPolicy.expandedViewportHeight, 520)
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
                StatusPopoverAccessibilityContract.selfCheckDisclosureIdentifier,
                StatusPopoverAccessibilityContract.diagnosticsDisclosureIdentifier,
                StatusPopoverAccessibilityContract.resetCreditsDisclosureIdentifier,
                StatusPopoverAccessibilityContract.resetCreditFieldsDisclosureIdentifier
            ],
            [
                "launch-at-login-toggle",
                "refresh-button",
                "quit-button",
                "self-check-disclosure",
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
