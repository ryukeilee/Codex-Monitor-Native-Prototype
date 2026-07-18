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
