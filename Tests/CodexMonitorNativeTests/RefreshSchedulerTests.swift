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

    func testUpdatingIntervalWhilePausedDoesNotFireUntilResumed() async {
        let firedWhilePaused = expectation(description: "scheduler should stay paused")
        firedWhilePaused.isInverted = true
        let firedAfterResume = expectation(description: "scheduler fired after resume")
        var fireCount = 0

        let scheduler = RefreshScheduler(interval: 0.05) {
            fireCount += 1
            if fireCount == 1 {
                firedAfterResume.fulfill()
            }
        }

        scheduler.start()
        scheduler.pause()
        scheduler.updateInterval(0.01)

        await fulfillment(of: [firedWhilePaused], timeout: 0.05)

        scheduler.resume()
        defer { scheduler.stop() }

        await fulfillment(of: [firedAfterResume], timeout: 1.0)
        XCTAssertEqual(fireCount, 1)
    }
}
