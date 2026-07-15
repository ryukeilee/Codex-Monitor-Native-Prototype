import AppKit
import XCTest
@testable import CodexMonitorNative

@MainActor
final class SleepWakeObserverTests: XCTestCase {
    func testRepeatedStartStopCyclesConvergeObserverAndTaskResources() async {
        let notificationCenter = NotificationCenter()
        var sleepCount = 0
        var wakeCount = 0
        let observer = SleepWakeObserver(
            notificationCenter: notificationCenter,
            wakeDelaySeconds: 0,
            onSleep: { sleepCount += 1 },
            onWake: { wakeCount += 1 }
        )

        for _ in 0..<200 {
            observer.start()
            XCTAssertEqual(observer.registeredObserverCount, 2)
            observer.stop()
            XCTAssertEqual(observer.registeredObserverCount, 0)
            XCTAssertFalse(observer.hasPendingWakeTask)
        }

        observer.start()
        for expectedCount in 1...200 {
            notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
            notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
            for _ in 0..<100 {
                if sleepCount == expectedCount,
                   wakeCount == expectedCount,
                   !observer.hasPendingWakeTask {
                    break
                }
                await Task.yield()
            }

            XCTAssertEqual(sleepCount, expectedCount)
            XCTAssertEqual(wakeCount, expectedCount)
            XCTAssertEqual(observer.registeredObserverCount, 2)
            XCTAssertFalse(observer.hasPendingWakeTask)
        }

        observer.stop()
        notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        for _ in 0..<2 { await Task.yield() }

        XCTAssertEqual(sleepCount, 200)
        XCTAssertEqual(wakeCount, 200)
        XCTAssertEqual(observer.registeredObserverCount, 0)
        XCTAssertFalse(observer.hasPendingWakeTask)
    }

    func testStopInvalidatesWakeDeliveredBeforeOuterTaskRuns() async {
        let notificationCenter = NotificationCenter()
        let dispatcher = ControlledMainTaskDispatcher()
        var callbackCount = 0
        let observer = SleepWakeObserver(
            notificationCenter: notificationCenter,
            wakeDelaySeconds: 0,
            dispatchTask: dispatcher.dispatch,
            onWake: { callbackCount += 1 }
        )

        observer.start()
        notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        XCTAssertEqual(dispatcher.pendingCount, 1)

        observer.stop()
        await dispatcher.runAll()

        XCTAssertEqual(callbackCount, 0)
        XCTAssertEqual(dispatcher.pendingCount, 0)
    }

    func testStopInvalidatesSleepDeliveredBeforeOuterTaskRuns() async {
        let notificationCenter = NotificationCenter()
        let dispatcher = ControlledMainTaskDispatcher()
        var callbackCount = 0
        let observer = SleepWakeObserver(
            notificationCenter: notificationCenter,
            wakeDelaySeconds: 0,
            onSleep: { callbackCount += 1 },
            dispatchTask: dispatcher.dispatch,
            onWake: {}
        )

        observer.start()
        notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        XCTAssertEqual(dispatcher.pendingCount, 1)

        observer.stop()
        await dispatcher.runAll()

        XCTAssertEqual(callbackCount, 0)
        XCTAssertEqual(dispatcher.pendingCount, 0)
    }
    func testDeinitCancelsPendingWakeAndRemovesObservers() async {
        let notificationCenter = NotificationCenter()
        let gate = WakeDelayGate()
        let noCallback = expectation(description: "no callback after deinit")
        noCallback.isInverted = true
        var observer: SleepWakeObserver? = SleepWakeObserver(
            notificationCenter: notificationCenter,
            wakeDelaySeconds: 1,
            sleep: { _ in await gate.wait() },
            onWake: { noCallback.fulfill() }
        )
        weak var weakObserver = observer

        observer?.start()
        notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        await gate.waitUntilSleeping()
        observer = nil

        XCTAssertNil(weakObserver)
        await gate.release()
        await fulfillment(of: [noCallback], timeout: 0.05)
    }

    func testStopCancelsPendingWakeBeforeItsDelayCompletes() async {
        let notificationCenter = NotificationCenter()
        let gate = WakeDelayGate()
        let noCallback = expectation(description: "no callback after stop")
        noCallback.isInverted = true
        let observer = SleepWakeObserver(
            notificationCenter: notificationCenter,
            wakeDelaySeconds: 1,
            sleep: { _ in await gate.wait() },
            onWake: { noCallback.fulfill() }
        )

        observer.start()
        notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        await gate.waitUntilSleeping()
        observer.stop()
        await gate.release()
        await fulfillment(of: [noCallback], timeout: 0.05)
    }
    func testRepeatedWakeNotificationsCoalesceIntoOneCallback() async {
        let notificationCenter = NotificationCenter()
        let fired = expectation(description: "one wake callback")
        let noSecondCallback = expectation(description: "no second wake callback")
        noSecondCallback.isInverted = true
        var callbackCount = 0
        let observer = SleepWakeObserver(notificationCenter: notificationCenter, wakeDelaySeconds: 0) {
            callbackCount += 1
            if callbackCount == 1 { fired.fulfill() } else { noSecondCallback.fulfill() }
        }

        observer.start()
        notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        await fulfillment(of: [fired, noSecondCallback], timeout: 0.1)
        observer.stop()
    }

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

private final class ControlledMainTaskDispatcher: @unchecked Sendable {
    private var pending: [@MainActor @Sendable () -> Void] = []

    var pendingCount: Int { pending.count }

    func dispatch(_ action: @escaping @MainActor @Sendable () -> Void) {
        pending.append(action)
    }

    func runAll() async {
        let actions = pending
        pending.removeAll()
        for action in actions { await MainActor.run { action() } }
        await Task.yield()
    }
}

private actor WakeDelayGate {
    private var sleeper: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?

    func wait() async {
        started?.resume()
        started = nil
        await withCheckedContinuation { sleeper = $0 }
    }

    func waitUntilSleeping() async {
        if sleeper != nil { return }
        await withCheckedContinuation { started = $0 }
    }

    func release() {
        sleeper?.resume()
        sleeper = nil
    }
}
