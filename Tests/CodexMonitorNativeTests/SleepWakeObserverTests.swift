import AppKit
import XCTest
@testable import CodexMonitorNative

@MainActor
final class SleepWakeObserverTests: XCTestCase {
    func testWakeNotificationInvokesHandler() async {
        let notificationCenter = NotificationCenter()
        let fired = expectation(description: "wake handler invoked")

        let observer = SleepWakeObserver(
            notificationCenter: notificationCenter,
            wakeNotificationName: .testWakeNotification
        ) {
            fired.fulfill()
        }

        observer.start()
        notificationCenter.post(name: .testWakeNotification, object: nil)

        await fulfillment(of: [fired], timeout: 1.0)
        observer.stop()
    }
}

private extension Notification.Name {
    static let testWakeNotification = Notification.Name("CodexMonitorNativeTests.testWakeNotification")
}
