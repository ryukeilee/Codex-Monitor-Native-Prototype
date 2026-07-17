import Foundation
import XCTest
@testable import CodexMonitorNative

@MainActor
final class SystemClockObserverTests: XCTestCase {
    func testNotificationBurstCoalescesAllTemporalChangesIntoOneDelivery() async {
        let notificationCenter = NotificationCenter()
        let dispatcher = SystemClockControlledDispatcher()
        let gate = SystemClockSleepGate()
        let delivered = expectation(description: "coalesced clock change")
        var deliveries: [SystemClockObserver.Change] = []
        let observer = SystemClockObserver(
            notificationCenter: notificationCenter,
            debounceNanoseconds: 1,
            sleep: { _ in await gate.wait() },
            dispatchTask: dispatcher.dispatch,
            onChange: {
                deliveries.append($0)
                delivered.fulfill()
            }
        )

        observer.start()
        notificationCenter.post(name: .NSSystemClockDidChange, object: nil)
        notificationCenter.post(name: .NSSystemTimeZoneDidChange, object: nil)
        notificationCenter.post(name: .NSCalendarDayChanged, object: nil)
        notificationCenter.post(name: NSLocale.currentLocaleDidChangeNotification, object: nil)

        XCTAssertEqual(dispatcher.pendingCount, 4)
        await dispatcher.runAll()
        await gate.waitForSleepers(1)
        await gate.releaseAll()
        await fulfillment(of: [delivered], timeout: 1)
        for _ in 0..<4 { await Task.yield() }

        XCTAssertEqual(deliveries.count, 1)
        XCTAssertTrue(deliveries[0].contains(.clock))
        XCTAssertTrue(deliveries[0].contains(.timeZone))
        XCTAssertTrue(deliveries[0].contains(.calendarDay))
        XCTAssertTrue(deliveries[0].contains(.locale))
        XCTAssertFalse(observer.hasPendingDelivery)
        observer.stop()
    }

    func testRepeatedStartStopCyclesConvergeObserverResources() {
        let notificationCenter = NotificationCenter()
        let observer = SystemClockObserver(
            notificationCenter: notificationCenter,
            debounceNanoseconds: 0,
            onChange: { _ in }
        )

        for _ in 0..<200 {
            observer.start()
            XCTAssertEqual(observer.registeredObserverCount, 4)
            observer.stop()
            XCTAssertEqual(observer.registeredObserverCount, 0)
            XCTAssertFalse(observer.hasPendingDelivery)
        }
    }

    func testStopInvalidatesNotificationDeliveredBeforeOuterTaskRuns() async {
        let notificationCenter = NotificationCenter()
        let dispatcher = SystemClockControlledDispatcher()
        var callbackCount = 0
        let observer = SystemClockObserver(
            notificationCenter: notificationCenter,
            debounceNanoseconds: 0,
            dispatchTask: dispatcher.dispatch,
            onChange: { _ in callbackCount += 1 }
        )

        observer.start()
        notificationCenter.post(name: .NSSystemClockDidChange, object: nil)
        XCTAssertEqual(dispatcher.pendingCount, 1)

        observer.stop()
        await dispatcher.runAll()
        for _ in 0..<2 { await Task.yield() }

        XCTAssertEqual(callbackCount, 0)
        XCTAssertEqual(observer.registeredObserverCount, 0)
        XCTAssertFalse(observer.hasPendingDelivery)
    }

    func testStopCancelsPendingDebouncedDelivery() async {
        let notificationCenter = NotificationCenter()
        let dispatcher = SystemClockControlledDispatcher()
        let gate = SystemClockSleepGate()
        var callbackCount = 0
        let observer = SystemClockObserver(
            notificationCenter: notificationCenter,
            debounceNanoseconds: 1,
            sleep: { _ in await gate.wait() },
            dispatchTask: dispatcher.dispatch,
            onChange: { _ in callbackCount += 1 }
        )

        observer.start()
        notificationCenter.post(name: .NSSystemClockDidChange, object: nil)
        await dispatcher.runAll()
        await gate.waitForSleepers(1)
        XCTAssertTrue(observer.hasPendingDelivery)

        observer.stop()
        await gate.releaseAll()
        for _ in 0..<4 { await Task.yield() }

        XCTAssertEqual(callbackCount, 0)
        XCTAssertFalse(observer.hasPendingDelivery)
    }

    func testDeinitCancelsPendingDebouncedDeliveryAndRemovesObservers() async {
        let notificationCenter = NotificationCenter()
        let dispatcher = SystemClockControlledDispatcher()
        let gate = SystemClockSleepGate()
        var callbackCount = 0
        var observer: SystemClockObserver? = SystemClockObserver(
            notificationCenter: notificationCenter,
            debounceNanoseconds: 1,
            sleep: { _ in await gate.wait() },
            dispatchTask: dispatcher.dispatch,
            onChange: { _ in callbackCount += 1 }
        )
        weak var weakObserver = observer

        observer?.start()
        notificationCenter.post(name: .NSSystemClockDidChange, object: nil)
        await dispatcher.runAll()
        await gate.waitForSleepers(1)
        observer = nil

        XCTAssertNil(weakObserver)
        await gate.releaseAll()
        for _ in 0..<4 { await Task.yield() }
        notificationCenter.post(name: .NSSystemClockDidChange, object: nil)
        await dispatcher.runAll()

        XCTAssertEqual(callbackCount, 0)
    }
}

private final class SystemClockControlledDispatcher: @unchecked Sendable {
    private var pending: [@MainActor @Sendable () -> Void] = []

    var pendingCount: Int { pending.count }

    func dispatch(_ action: @escaping @MainActor @Sendable () -> Void) {
        pending.append(action)
    }

    func runAll() async {
        let actions = pending
        pending.removeAll()
        for action in actions {
            await MainActor.run { action() }
        }
        await Task.yield()
    }
}

private actor SystemClockSleepGate {
    private var sleepers: [CheckedContinuation<Void, Never>] = []
    private var isReleased = false

    func wait() async {
        if isReleased { return }
        await withCheckedContinuation { sleepers.append($0) }
    }

    func waitForSleepers(_ count: Int) async {
        while sleepers.count < count {
            await Task.yield()
        }
    }

    func releaseAll() {
        isReleased = true
        let continuations = sleepers
        sleepers.removeAll()
        continuations.forEach { $0.resume() }
    }
}
