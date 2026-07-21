import AppKit
import XCTest
@testable import CodexMonitorNative

@MainActor
final class AppDelegateLifecycleTests: XCTestCase {
    func testClaimRevalidationRedirectsSamePathCoverInstallInsteadOfRelabelingOwner() {
        let claimed = installationIdentity(digest: "old-code", build: "1")
        let updatedOnDisk = installationIdentity(digest: "new-code", build: "2")

        let decision = ClaimedInstallationRevalidationPolicy.decide(
            claimedIdentity: claimed,
            resolution: .useCurrent(
                identity: updatedOnDisk,
                shouldPersist: true,
                allowsAutomaticLoginItemReconciliation: true
            )
        )

        XCTAssertEqual(decision, .redirect(updatedOnDisk))
    }

    func testClaimRevalidationContinuesOnlyWithTheClaimedIdentity() {
        let claimed = installationIdentity(digest: "same-code", build: "1")

        let decision = ClaimedInstallationRevalidationPolicy.decide(
            claimedIdentity: claimed,
            resolution: .useCurrent(
                identity: claimed,
                shouldPersist: true,
                allowsAutomaticLoginItemReconciliation: true
            )
        )

        XCTAssertEqual(
            decision,
            .continueUsing(
                identity: claimed,
                shouldPersist: true,
                allowsAutomaticLoginItemReconciliation: true
            )
        )
    }

    func testClaimRevalidationFailsClosedWhenClaimedIdentityDisappears() {
        let claimed = installationIdentity(digest: "old-code", build: "1")

        let decision = ClaimedInstallationRevalidationPolicy.decide(
            claimedIdentity: claimed,
            resolution: .useCurrent(
                identity: nil,
                shouldPersist: false,
                allowsAutomaticLoginItemReconciliation: false
            )
        )

        guard case .reject = decision else {
            XCTFail("Expected identity disappearance to fail closed, got \(decision)")
            return
        }
    }

    func testStatusBarTeardownRemovesInteractionAndIsIdempotent() throws {
        _ = NSApplication.shared
        let suiteName = "CodexMonitorNativeTests.statusBarTeardown.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let appState = AppState(
            snapshotStore: SnapshotStore(defaults: defaults, key: "snapshot"),
            refreshService: LifecycleSuspendedRefreshService()
        )
        defer { appState.shutdown() }
        let controller = StatusBarController(appState: appState)
        let button = try XCTUnwrap(controller.statusButton)
        let target = StatusBarActionTarget()
        controller.setTarget(target, action: #selector(StatusBarActionTarget.invoke(_:)))

        XCTAssertTrue(controller.statusItem.isVisible)
        XCTAssertNotNil(button.target)

        controller.teardown()
        controller.teardown()

        XCTAssertTrue(controller.isTornDown)
        XCTAssertFalse(controller.statusItem.isVisible)
        XCTAssertNil(button.target)
        XCTAssertNil(button.action)
    }

    func testOwnedServiceShutdownPublishesFinalWidgetStateBeforeStoppingBridge() async {
        let suiteName = "CodexMonitorNativeTests.ownedServiceShutdown.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let initial = QuotaSnapshot(
            weeklyQuotaPercent: 70,
            fiveHourQuotaPercent: 60,
            refreshedAt: .now,
            dataSource: .real
        )
        let store = SnapshotStore(defaults: defaults, key: "snapshot")
        store.saveSnapshot(initial)
        let refreshService = AppDelegateLifecycleBlockingRefreshService(snapshot: initial)
        let appState = AppState(snapshotStore: store, refreshService: refreshService)
        var savedStates: [WidgetDisplayState] = []
        var reloadCount = 0
        let bridge = WidgetTimelineBridge(
            appState: appState,
            saveState: { savedStates.append($0) },
            reloadTimelines: { reloadCount += 1 }
        )
        savedStates.removeAll()
        reloadCount = 0

        appState.refresh(trigger: .manual)
        await refreshService.waitForStart()

        AppDelegateOwnedServiceShutdown.stop(
            refreshScheduler: nil,
            sleepWakeObserver: nil,
            networkReachabilityObserver: nil,
            systemClockObserver: nil,
            authBoundaryObserver: nil,
            appState: appState,
            widgetTimelineBridge: bridge
        )

        XCTAssertEqual(savedStates.map(\.status), [.success])
        XCTAssertEqual(savedStates.map(\.snapshot), [initial])
        XCTAssertEqual(reloadCount, 1)

        await refreshService.release()
        for _ in 0..<3 { await Task.yield() }
        XCTAssertEqual(savedStates.count, 1)
        XCTAssertEqual(reloadCount, 1)
    }

    private func installationIdentity(digest: String, build: String) -> AppInstallationIdentity {
        AppInstallationIdentity(
            bundlePath: "/Applications/CodexMonitorNative.app",
            bundleIdentifier: "com.ryukeilee.CodexMonitorNativePrototype",
            codeIdentityDigest: digest,
            signingAnchorDigest: "same-signer",
            signatureKind: .certificateBacked,
            version: AppInstallationVersion(marketingVersion: "1.0", buildVersion: build)
        )
    }
}

@MainActor
private final class StatusBarActionTarget: NSObject {
    @objc
    func invoke(_ sender: Any?) {}
}

private struct LifecycleSuspendedRefreshService: QuotaRefreshing {
    func refresh(basedOn currentSnapshot: QuotaSnapshot) async throws -> QuotaSnapshot {
        try await Task.sleep(for: .seconds(60))
        return currentSnapshot
    }
}

private actor AppDelegateLifecycleBlockingRefreshService: QuotaRefreshing {
    let snapshot: QuotaSnapshot
    private var continuation: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?

    init(snapshot: QuotaSnapshot) {
        self.snapshot = snapshot
    }

    func refresh(basedOn currentSnapshot: QuotaSnapshot) async throws -> QuotaSnapshot {
        started?.resume()
        started = nil
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
        return snapshot
    }

    func waitForStart() async {
        if continuation != nil { return }
        await withCheckedContinuation { started = $0 }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
