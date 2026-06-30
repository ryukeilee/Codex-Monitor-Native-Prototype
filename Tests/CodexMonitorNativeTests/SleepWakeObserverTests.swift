import AppKit
import XCTest
@testable import CodexMonitorNative

@MainActor
final class SleepWakeObserverTests: XCTestCase {
    func testWakeNotificationInvokesHandlerAfterDelay() async {
        let notificationCenter = NotificationCenter()
        let fired = expectation(description: "wake handler invoked")

        let observer = SleepWakeObserver(
            notificationCenter: notificationCenter,
            wakeDelaySeconds: 0  // zero delay for test
        ) {
            fired.fulfill()
        }

        observer.start()
        notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)

        await fulfillment(of: [fired], timeout: 1.0)
        observer.stop()
    }

    func testSleepNotificationInvokesHandler() async {
        let notificationCenter = NotificationCenter()
        let fired = expectation(description: "sleep handler invoked")

        let observer = SleepWakeObserver(
            notificationCenter: notificationCenter,
            wakeDelaySeconds: 0,
            onSleep: {
                fired.fulfill()
            },
            onWake: {}
        )

        observer.start()
        notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)

        await fulfillment(of: [fired], timeout: 1.0)
        observer.stop()
    }
}
