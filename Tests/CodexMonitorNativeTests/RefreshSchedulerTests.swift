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
        XCTAssertTrue(scheduler.hasScheduledTimer)
        scheduler.pause()
        XCTAssertFalse(scheduler.hasScheduledTimer)
        scheduler.updateInterval(0.01)
        XCTAssertFalse(scheduler.hasScheduledTimer)

        await fulfillment(of: [firedWhilePaused], timeout: 0.05)

        scheduler.resume()
        XCTAssertTrue(scheduler.hasScheduledTimer)
        defer { scheduler.stop() }

        await fulfillment(of: [firedAfterResume], timeout: 1.0)
        XCTAssertEqual(fireCount, 1)
    }

    func testRepeatedLifecycleOperationsKeepTimerResourceConverged() {
        let scheduler = RefreshScheduler(interval: 1) {}

        XCTAssertFalse(scheduler.hasScheduledTimer)
        XCTAssertFalse(scheduler.isPaused)

        for _ in 0..<1_000 {
            scheduler.start()
            XCTAssertTrue(scheduler.hasScheduledTimer)
            XCTAssertFalse(scheduler.isPaused)

            scheduler.start()
            XCTAssertTrue(scheduler.hasScheduledTimer)
            XCTAssertFalse(scheduler.isPaused)

            scheduler.pause()
            XCTAssertTrue(scheduler.isPaused)
            XCTAssertFalse(scheduler.hasScheduledTimer)

            scheduler.pause()
            XCTAssertTrue(scheduler.isPaused)
            XCTAssertFalse(scheduler.hasScheduledTimer)

            scheduler.updateInterval(2)
            XCTAssertFalse(scheduler.hasScheduledTimer)

            scheduler.resume()
            XCTAssertFalse(scheduler.isPaused)
            XCTAssertTrue(scheduler.hasScheduledTimer)

            scheduler.resume()
            XCTAssertFalse(scheduler.isPaused)
            XCTAssertTrue(scheduler.hasScheduledTimer)

            scheduler.updateInterval(1)
            XCTAssertTrue(scheduler.hasScheduledTimer)

            scheduler.stop()
            XCTAssertFalse(scheduler.isPaused)
            XCTAssertFalse(scheduler.hasScheduledTimer)
        }
    }

    func testOperationsAfterStopDoNotRecreateTimerOrFire() async {
        var fireCount = 0
        let scheduler = RefreshScheduler(interval: 0.01) {
            fireCount += 1
        }

        scheduler.start()
        scheduler.stop()
        XCTAssertFalse(scheduler.hasScheduledTimer)

        scheduler.updateInterval(0.02)
        scheduler.resume()
        scheduler.pause()

        XCTAssertFalse(scheduler.isPaused)
        XCTAssertFalse(scheduler.hasScheduledTimer)
        try? await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(fireCount, 0)
    }

    func testStopWhilePausedThenStartRestoresRunningTimer() {
        let scheduler = RefreshScheduler(interval: 1) {}

        scheduler.start()
        scheduler.pause()
        XCTAssertTrue(scheduler.isPaused)
        XCTAssertFalse(scheduler.hasScheduledTimer)

        scheduler.stop()
        XCTAssertFalse(scheduler.isPaused)
        XCTAssertFalse(scheduler.hasScheduledTimer)

        scheduler.start()
        XCTAssertFalse(scheduler.isPaused)
        XCTAssertTrue(scheduler.hasScheduledTimer)
        scheduler.stop()
    }
}
