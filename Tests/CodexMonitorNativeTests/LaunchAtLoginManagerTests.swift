import ServiceManagement
import XCTest
@testable import CodexMonitorNative

@MainActor
final class LaunchAtLoginManagerTests: XCTestCase {
    func testRefreshStatusReflectsRealSystemState() {
        let service = FakeLoginItemManager(status: .enabled)
        let manager = LaunchAtLoginManager(loginItemManager: service)

        XCTAssertTrue(manager.shouldLaunchAtLogin)
        XCTAssertEqual(manager.helperText, "Launch at login is enabled.")
        XCTAssertNil(manager.lastErrorSummary)
    }

    func testToggleRollsBackAndShowsShortErrorWhenSystemUpdateFails() {
        let service = FakeLoginItemManager(status: .notRegistered)
        service.registerError = NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError, userInfo: [
            NSLocalizedDescriptionKey: "Operation not permitted"
        ])

        let manager = LaunchAtLoginManager(loginItemManager: service)

        manager.setLaunchAtLogin(true)

        XCTAssertFalse(manager.shouldLaunchAtLogin)
        XCTAssertEqual(manager.helperText, "Launch at login is disabled.")
        XCTAssertEqual(manager.lastErrorSummary, "Login session unavailable")
    }
}

private final class FakeLoginItemManager: LoginItemManaging {
    var status: SMAppService.Status
    var registerError: Error?
    var unregisterError: Error?

    init(status: SMAppService.Status) {
        self.status = status
    }

    func register() throws {
        if let registerError {
            throw registerError
        }
        status = .enabled
    }

    func unregister() throws {
        if let unregisterError {
            throw unregisterError
        }
        status = .notRegistered
    }
}
