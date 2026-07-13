import AppKit
import ServiceManagement
import SwiftUI
import XCTest
@testable import CodexMonitorNative

@MainActor
final class StatusPopoverSnapshotTests: XCTestCase {
    func testRenderStatusPopoverSnapshot() async throws {
        let outputURL = URL(fileURLWithPath: "/private/tmp/codex-monitor-status-popover.png")
        try await renderSnapshot(
            snapshot: QuotaSnapshot(
                weeklyQuotaPercent: 71,
                fiveHourQuotaPercent: 64,
                resetAvailableCount: 5,
                resetCreditDetailsState: .detailed,
                resetCreditDetails: [
                    ResetCreditDetailSnapshot(
                        ordinal: 1,
                        status: "available",
                        grantedAt: makeDate("2026-06-26T09:10:00Z"),
                        expiresAt: makeDate("2026-06-26T13:10:00Z")
                    ),
                    ResetCreditDetailSnapshot(
                        ordinal: 2,
                        status: "available",
                        grantedAt: makeDate("2026-06-26T10:10:00Z"),
                        expiresAt: makeDate("2026-06-26T18:10:00Z")
                    )
                ],
                resetCreditStatusSummary: [ResetCreditStatusSummary(status: "available", count: 2)],
                fiveHourResetAt: makeDate("2026-06-26T14:10:00Z"),
                refreshedAt: makeDate("2026-06-26T11:40:00Z"),
                dataSource: .real
            ),
            outputURL: outputURL
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
    }

    func testRenderStatusPopoverWithResetBanksSnapshot() async throws {
        let refreshedAt = makeDate("2026-06-26T11:40:00Z")
        let outputURL = URL(fileURLWithPath: "/private/tmp/codex-monitor-status-popover-reset-banks.png")
        try await renderSnapshot(
            snapshot: QuotaSnapshot(
                weeklyQuotaPercent: 71,
                fiveHourQuotaPercent: 64,
                resetAvailableCount: 5,
                fiveHourResetAt: makeDate("2026-06-26T14:10:00Z"),
                resetBanks: [
                    ResetBankSnapshot(
                        limitId: "codex",
                        windowId: "primary",
                        displayName: "5小时额度",
                        remainingPercent: 64,
                        resetAt: makeDate("2026-06-26T14:10:00Z"),
                        rawResetFields: []
                    ),
                    ResetBankSnapshot(
                        limitId: "codex",
                        windowId: "secondary",
                        displayName: "周额度",
                        remainingPercent: 71,
                        resetAt: nil,
                        rawResetFields: []
                    ),
                    ResetBankSnapshot(
                        limitId: "bonus",
                        windowId: "primary",
                        displayName: "bonus.primary",
                        remainingPercent: 80,
                        resetAt: nil,
                        rawResetFields: [ResetBankRawField(name: "windowResetAt", value: "<null>")]
                    )
                ],
                refreshedAt: refreshedAt,
                dataSource: .real
            ),
            outputURL: outputURL
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
    }

    func testRenderMechanicalEnergyCoreSizeMatrix() throws {
        let outputURL = URL(fileURLWithPath: "/private/tmp/codex-monitor-energy-core-sizes.png")
        let view = AnyView(
            HStack(spacing: 18) {
                MechanicalEnergyCore(diameter: 40, rotation: .degrees(18)) {
                    EmptyView()
                }

                MechanicalEnergyCore(diameter: 72, progress: 0.71) {
                    Text("71")
                        .font(.system(size: 19, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                        .monospacedDigit()
                }

                MechanicalEnergyCore(diameter: 74, progress: 0.64) {
                    Text("64")
                        .font(.system(size: 20, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                        .monospacedDigit()
                }
            }
            .padding(18)
            .background(Color(red: 0.08, green: 0.01, blue: 0.02))
        )
        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = NSRect(x: 0, y: 0, width: 278, height: 110)
        hostingView.layoutSubtreeIfNeeded()

        try saveSnapshot(of: hostingView, to: outputURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
    }

    func testQuotaSummaryViewSourceDoesNotRenderRateLimitBanksSection() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = repoRoot.appendingPathComponent("Sources/CodexMonitorNative/UI/QuotaSummaryView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertFalse(source.contains("Rate Limit Banks（最快 3 条）"))
        XCTAssertFalse(source.contains("rateLimitBankDiagnosticsSummary("))
        XCTAssertFalse(source.contains("resetBankItems"))
        XCTAssertTrue(source.contains("DisclosureGroup(\"字段\", isExpanded"))
        XCTAssertTrue(source.contains("DisclosureGroup("))
        XCTAssertTrue(source.contains("\"全部 \\("))
        XCTAssertFalse(source.contains("Text(\"当前状态\")"))
        XCTAssertFalse(source.contains("Text(\"重置次数\")"))
        XCTAssertFalse(source.contains("查看全部（"))
        XCTAssertFalse(source.contains("DisclosureGroup(\"原始字段与诊断\")"))
        XCTAssertTrue(source.contains("featuredResetCreditSummary("))
        XCTAssertTrue(source.contains("Text(\"最早到期"))
    }

    func testStatusPopoverViewSourceUsesCollapsedDiagnosticsSection() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = repoRoot.appendingPathComponent("Sources/CodexMonitorNative/UI/StatusPopoverView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("DisclosureGroup(\"诊断\""))
        XCTAssertTrue(source.contains("DisclosureGroup(\"自检\""))
        XCTAssertFalse(source.contains("DisclosureGroup(\"详情与诊断\""))
        XCTAssertTrue(source.contains("@State private var showsDiagnostics = false"))
        XCTAssertTrue(source.contains("@State private var showsSelfCheck = false"))
        XCTAssertTrue(source.contains("if let refreshSummaryLine"))
    }

    func testStatusPopoverViewSourceUsesCompactLaunchAtLoginWhenEnabled() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = repoRoot.appendingPathComponent("Sources/CodexMonitorNative/UI/StatusPopoverView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("usesCompactLaunchAtLoginSection"))
        XCTAssertTrue(source.contains("launchAtLoginManager.statusInfo == .enabled"))
        XCTAssertTrue(source.contains("Text(\"开机启动 · 已启用\")"))
        XCTAssertFalse(source.contains("Text(\"开机启动已启用\")"))
        XCTAssertTrue(source.contains("launchAtLoginToggle(controlSize: .mini, isLowEmphasis: true)"))
        XCTAssertTrue(source.contains("launchAtLoginToggle(controlSize: .small, isLowEmphasis: false)"))
        XCTAssertTrue(source.contains(".opacity(isLowEmphasis ? 0.62 : 1)"))
        XCTAssertTrue(source.contains(".scaleEffect(isLowEmphasis ? 0.86 : 1)"))
    }

    func testMetallicPopoverSourceContainsReferencePanelSections() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let statusSource = try String(
            contentsOf: repoRoot.appendingPathComponent("Sources/CodexMonitorNative/UI/StatusPopoverView.swift"),
            encoding: .utf8
        )
        let quotaSource = try String(
            contentsOf: repoRoot.appendingPathComponent("Sources/CodexMonitorNative/UI/QuotaSummaryView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(statusSource.contains("MetallicPanelBackground"))
        XCTAssertTrue(statusSource.contains("ReactorView"))
        XCTAssertTrue(statusSource.contains("isPanelActive"))
        XCTAssertTrue(statusSource.contains("开机启动"))
        XCTAssertTrue(statusSource.contains("刷新"))
        XCTAssertTrue(statusSource.contains("退出"))
        XCTAssertFalse(statusSource.contains(".frame(width: 390)"))
        XCTAssertTrue(quotaSource.contains("QuotaGaugeView"))
        XCTAssertTrue(quotaSource.contains("最早到期"))
        XCTAssertTrue(quotaSource.contains("重置次数"))
    }

    func testMechanicalEnergyCoreUsesLayeredVectorMechanicsWithoutLegacyPlaceholder() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let reactorSource = try String(
            contentsOf: repoRoot.appendingPathComponent("Sources/CodexMonitorNative/UI/MetallicPanelComponents.swift"),
            encoding: .utf8
        )
        let coreSource = try String(
            contentsOf: repoRoot.appendingPathComponent("Sources/CodexMonitorNative/UI/MechanicalEnergyCore.swift"),
            encoding: .utf8
        )
        let statusSource = try String(
            contentsOf: repoRoot.appendingPathComponent("Sources/CodexMonitorNative/UI/StatusPopoverView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(reactorSource.contains("MechanicalEnergyCore"))
        XCTAssertTrue(reactorSource.contains("TimelineView(.animation(minimumInterval: 1.0 / 12.0"))
        XCTAssertTrue(reactorSource.contains("allowsAnimation"))
        XCTAssertTrue(statusSource.contains("ReactorView(isPanelActive: isPanelActive, allowsAnimation: false)"))
        XCTAssertTrue(coreSource.contains("segmentedArmorRing"))
        XCTAssertTrue(coreSource.contains("AngularGradient"))
        XCTAssertTrue(coreSource.contains("RadialGradient"))
        XCTAssertTrue(coreSource.contains("ForEach(0..<layout.strutCount"))
        XCTAssertTrue(coreSource.contains("ForEach(0..<layout.emitterCount"))
        XCTAssertFalse(reactorSource.contains("triangle.fill"))
        XCTAssertFalse(reactorSource.contains("dash: [3, 5]"))
    }

    func testQuotaDisclosurePropagatesLayoutChangesAndLabelsDetailOnlyContent() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent("Sources/CodexMonitorNative/UI/QuotaSummaryView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("let onLayoutChange: (Bool) -> Void"))
        XCTAssertTrue(source.contains("@Binding private var showsResetCreditFields"))
        XCTAssertTrue(source.contains("onChange(of: showsAllResetCredits)"))
        XCTAssertTrue(source.contains("onChange(of: showsResetCreditFields)"))
        XCTAssertTrue(source.contains("字段详情"))
    }

    func testNestedQuotaDisclosureOnlyTriggersParentLayoutWhenExpansionStateChanges() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent("Sources/CodexMonitorNative/UI/StatusPopoverView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("guard isQuotaExpanded != expanded else { return }"))
        XCTAssertTrue(source.contains("isQuotaExpanded = expanded"))
        XCTAssertTrue(source.contains("onLayoutChange()"))
    }

    func testExpandedPopoverUsesScrollableViewportForAccessibility() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent("Sources/CodexMonitorNative/UI/StatusPopoverView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("ScrollView(.vertical)"))
        XCTAssertTrue(source.contains("expandedViewportHeight"))
        XCTAssertTrue(source.contains("isQuotaExpanded"))
        XCTAssertTrue(source.contains("quota-scroll-viewport"))
    }

    func testPopoverControllerSourceWiresEscAndLifecycleCleanup() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent("Sources/CodexMonitorNative/App/PopoverController.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("keyCode == 53"))
        XCTAssertTrue(source.contains("isPanelActive"))
        XCTAssertTrue(source.contains("deinit"))
        XCTAssertTrue(source.contains("removeOutsideClickMonitors()"))
        XCTAssertTrue(source.contains("visibleFrame"))
    }

    func testPopoverControllerLayoutChangeReusesDisplayClamp() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent("Sources/CodexMonitorNative/App/PopoverController.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("clampedContentSize"))
        XCTAssertTrue(source.contains("activeVisibleFrame"))
        XCTAssertTrue(source.contains("updateContentSize(for: button)"))
        XCTAssertFalse(source.contains("popover.contentSize = NSSize(width: Self.contentWidth, height: ceil(fittingSize.height))"))
    }

    func testPopoverControllerDefersAndCoalescesLayoutChanges() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent("Sources/CodexMonitorNative/App/PopoverController.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("layoutUpdateTask"))
        XCTAssertTrue(source.contains("Task.yield()"))
        XCTAssertTrue(source.contains("guard layoutUpdateTask == nil else { return }"))
        XCTAssertTrue(source.contains("layoutUpdateTask?.cancel()"))
        XCTAssertTrue(source.contains("guard popover.isShown else { return }"))
    }

    func testPopoverControllerMeasuresWithFinitePanelHeight() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent("Sources/CodexMonitorNative/App/PopoverController.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("hostingView.fittingSize"))
        XCTAssertFalse(source.contains("height: .greatestFiniteMagnitude"))
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

    private func renderSnapshot(snapshot: QuotaSnapshot, outputURL: URL) async throws {
        let hostingView = try await makeHostingView(snapshot: snapshot)
        try saveSnapshot(of: hostingView, to: outputURL)
    }

    private func makeHostingView(snapshot: QuotaSnapshot) async throws -> NSHostingView<AnyView> {
        let defaults = UserDefaults(suiteName: "CodexMonitorNativeTests.snapshot.\(UUID().uuidString)")!
        let store = SnapshotStore(defaults: defaults, key: "snapshot")
        store.saveSnapshot(snapshot)

        let appState = AppState(snapshotStore: store, refreshService: SnapshotRefreshService(snapshot: snapshot))
        await appState.refreshNow(trigger: .manual)

        let launchManager = SnapshotLoginItemManager(status: .enabled)
        let view = AnyView(ZStack {
            Color(nsColor: .windowBackgroundColor)
            StatusPopoverView(
                appState: appState,
                launchAtLoginManager: LaunchAtLoginManager(loginItemManager: launchManager),
                onRefresh: {},
                onQuit: {}
            )
        })

        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = NSRect(x: 0, y: 0, width: 340, height: 560)
        hostingView.layoutSubtreeIfNeeded()
        let fittingHeight = max(240, hostingView.fittingSize.height.rounded(.up))
        hostingView.frame = NSRect(x: 0, y: 0, width: 340, height: fittingHeight)
        hostingView.layoutSubtreeIfNeeded()

        return hostingView
    }

    private func saveSnapshot(of view: NSView, to url: URL) throws {
        let bounds = view.bounds
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: bounds) else {
            XCTFail("Unable to allocate bitmap for popover snapshot")
            return
        }

        view.cacheDisplay(in: bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            XCTFail("Unable to encode popover snapshot as PNG")
            return
        }

        try data.write(to: url)
    }

    private func makeDate(_ iso8601: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: iso8601)!
    }
}

private struct SnapshotRefreshService: QuotaRefreshing {
    let snapshot: QuotaSnapshot

    func refresh(basedOn currentSnapshot: QuotaSnapshot) async throws -> QuotaSnapshot {
        snapshot
    }
}

private struct SnapshotLoginItemManager: LoginItemManaging {
    let status: SMAppService.Status

    func register() throws {}

    func unregister() throws {}
}
