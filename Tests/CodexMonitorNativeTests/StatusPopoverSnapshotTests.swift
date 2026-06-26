import AppKit
import ServiceManagement
import SwiftUI
import XCTest
@testable import CodexMonitorNative

@MainActor
final class StatusPopoverSnapshotTests: XCTestCase {
    func testRenderStatusPopoverSnapshot() async throws {
        let defaults = UserDefaults(suiteName: "CodexMonitorNativeTests.snapshot.\(UUID().uuidString)")!
        let store = SnapshotStore(defaults: defaults, key: "snapshot")
        let refreshedAt = makeDate("2026-06-26T11:40:00Z")
        let resetAt = makeDate("2026-06-26T14:10:00Z")
        let snapshot = QuotaSnapshot(
            weeklyQuotaPercent: 71,
            fiveHourQuotaPercent: 64,
            fiveHourResetAt: resetAt,
            refreshedAt: refreshedAt,
            dataSource: .real
        )
        store.saveSnapshot(snapshot)

        let appState = AppState(snapshotStore: store, refreshService: SnapshotRefreshService(snapshot: snapshot))
        await appState.refreshNow(trigger: .manual)

        let launchManager = SnapshotLoginItemManager(status: .enabled)
        let view = ZStack {
            Color(nsColor: .windowBackgroundColor)
            StatusPopoverView(
                appState: appState,
                launchAtLoginManager: LaunchAtLoginManager(loginItemManager: launchManager),
                onRefresh: {},
                onQuit: {}
            )
        }

        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = NSRect(x: 0, y: 0, width: 314, height: 240)
        hostingView.layoutSubtreeIfNeeded()

        let outputURL = URL(fileURLWithPath: "/private/tmp/codex-monitor-status-popover.png")
        try saveSnapshot(of: hostingView, to: outputURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
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
