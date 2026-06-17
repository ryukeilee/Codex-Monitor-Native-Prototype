import XCTest
@testable import CodexMonitorNative

@MainActor
final class RefreshSchedulerTests: XCTestCase {
    func testSchedulerFiresTickHandler() async {
        let fired = expectation(description: "scheduler fired")

        let scheduler = RefreshScheduler(interval: 0.05) {
            fired.fulfill()
        }

        scheduler.start()
        defer { scheduler.stop() }

        await fulfillment(of: [fired], timeout: 1.0)
    }
}
