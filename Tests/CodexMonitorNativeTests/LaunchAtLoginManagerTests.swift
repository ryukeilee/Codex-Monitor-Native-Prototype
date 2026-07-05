import ServiceManagement
import XCTest
@testable import CodexMonitorNative

@MainActor
final class LaunchAtLoginManagerTests: XCTestCase {
    func testRefreshStatusReflectsRealSystemState() {
        let service = FakeLoginItemManager(status: .enabled)
        let manager = LaunchAtLoginManager(loginItemManager: service)

        XCTAssertTrue(manager.shouldLaunchAtLogin)
        XCTAssertEqual(manager.helperText, "已启用")
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
        XCTAssertEqual(manager.helperText, "未启用")
        XCTAssertEqual(manager.lastErrorSummary, "登录会话不可用")
    }

    func testEnabledRefreshClearsStaleLaunchError() {
        let service = FakeLoginItemManager(status: .notRegistered)
        service.registerError = NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError, userInfo: [
            NSLocalizedDescriptionKey: "Operation not permitted"
        ])
        let manager = LaunchAtLoginManager(loginItemManager: service)
        manager.setLaunchAtLogin(true)
        XCTAssertEqual(manager.lastErrorSummary, "登录会话不可用")

        service.registerError = nil
        service.status = .enabled
        manager.refreshStatus()

        XCTAssertTrue(manager.shouldLaunchAtLogin)
        XCTAssertEqual(manager.helperText, "已启用")
        XCTAssertNil(manager.lastErrorSummary)
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
