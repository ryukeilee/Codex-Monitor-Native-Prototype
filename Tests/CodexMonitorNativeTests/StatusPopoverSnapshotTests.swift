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
        XCTAssertTrue(source.contains("DisclosureGroup(\"原始字段与诊断\")"))
        XCTAssertTrue(source.contains("DisclosureGroup("))
        XCTAssertTrue(source.contains("查看全部（"))
    }

    func testStatusPopoverViewSourceUsesCollapsedDiagnosticsSection() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = repoRoot.appendingPathComponent("Sources/CodexMonitorNative/UI/StatusPopoverView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("DisclosureGroup(\"详情与诊断\""))
        XCTAssertTrue(source.contains("@State private var showsDiagnostics = false"))
        XCTAssertTrue(source.contains("if let refreshSummaryLine"))
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
        hostingView.frame = NSRect(x: 0, y: 0, width: 314, height: 640)
        hostingView.layoutSubtreeIfNeeded()
        let fittingHeight = max(240, hostingView.fittingSize.height.rounded(.up))
        hostingView.frame = NSRect(x: 0, y: 0, width: 314, height: fittingHeight)
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
