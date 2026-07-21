import Foundation
import XCTest
@testable import CodexMonitorNative

@MainActor
final class CodexAuthBoundaryObserverTests: XCTestCase {
    func testDefaultSchedulerCanStartAndStopWithoutCrashing() {
        let observer = CodexAuthBoundaryObserver(
            pollInterval: 60,
            boundaryProvider: { nil },
            onChange: { XCTFail("A long-interval production timer fired unexpectedly") }
        )

        observer.start()
        XCTAssertTrue(observer.isRunning)
        observer.stop()
        XCTAssertFalse(observer.isRunning)
    }

    func testObserverReportsAccountToNilBoundaryChange() {
        let fixture = makeFixture(initialBoundary: .testDefault)
        fixture.observer.start()

        fixture.boundary.value = nil
        fixture.scheduler.fireScheduledTick(at: 0)

        XCTAssertEqual(fixture.changeCount(), 1)
    }

    func testObserverReportsNilToAccountBoundaryChange() {
        let fixture = makeFixture(initialBoundary: nil)
        fixture.observer.start()

        fixture.boundary.value = .testDefault
        fixture.scheduler.fireScheduledTick(at: 0)

        XCTAssertEqual(fixture.changeCount(), 1)
    }

    func testObserverReportsSessionReloginForSameAccount() {
        let fixture = makeFixture(initialBoundary: .testDefault)
        fixture.observer.start()

        fixture.boundary.value = .testRelogin
        fixture.scheduler.fireScheduledTick(at: 0)

        XCTAssertEqual(fixture.changeCount(), 1)
    }

    func testObserverDoesNotReportUnchangedBoundary() {
        let fixture = makeFixture(initialBoundary: .testDefault)
        fixture.observer.start()

        fixture.scheduler.fireScheduledTick(at: 0)

        XCTAssertEqual(fixture.changeCount(), 0)
    }

    func testQueuedTickAfterStopDoesNotReportOrRetainResources() {
        let fixture = makeFixture(initialBoundary: .testDefault)
        fixture.observer.start()
        fixture.boundary.value = .testOtherAccount

        fixture.observer.stop()
        fixture.scheduler.fireScheduledTick(at: 0)

        XCTAssertFalse(fixture.observer.isRunning)
        XCTAssertEqual(fixture.changeCount(), 0)
        XCTAssertEqual(fixture.scheduler.activeTaskCount, 0)
        XCTAssertEqual(fixture.scheduler.cancelCount, 1)
    }

    func testRestartIgnoresOldTickAndAcceptsNewTick() {
        let fixture = makeFixture(initialBoundary: .testDefault)
        fixture.observer.start()
        fixture.observer.stop()
        fixture.observer.start()

        fixture.boundary.value = .testOtherAccount
        fixture.scheduler.fireScheduledTick(at: 0)
        XCTAssertEqual(fixture.changeCount(), 0)

        fixture.scheduler.fireScheduledTick(at: 1)
        XCTAssertEqual(fixture.changeCount(), 1)

        fixture.observer.stop()
        XCTAssertEqual(fixture.scheduler.activeTaskCount, 0)
        XCTAssertEqual(fixture.scheduler.cancelCount, 2)
    }

    private func makeFixture(initialBoundary: QuotaAccountBoundary?) -> ObserverFixture {
        let boundary = ObserverBoundaryBox(initialBoundary)
        let scheduler = ManualRepeatingScheduler()
        var changeCount = 0
        let observer = CodexAuthBoundaryObserver(
            boundaryProvider: { boundary.value },
            scheduler: scheduler,
            onChange: { changeCount += 1 }
        )
        return ObserverFixture(
            observer: observer,
            boundary: boundary,
            scheduler: scheduler,
            changeCount: { changeCount }
        )
    }
}

@MainActor
private struct ObserverFixture {
    let observer: CodexAuthBoundaryObserver
    let boundary: ObserverBoundaryBox
    let scheduler: ManualRepeatingScheduler
    let changeCount: () -> Int
}

@MainActor
private final class ManualRepeatingScheduler: CodexAuthBoundaryRepeatingScheduling {
    private(set) var activeTaskCount = 0
    private(set) var cancelCount = 0
    private var handlers: [@MainActor () -> Void] = []

    func scheduleRepeating(
        every interval: TimeInterval,
        handler: @escaping @MainActor () -> Void
    ) -> any CodexAuthBoundaryRepeatingTask {
        handlers.append(handler)
        activeTaskCount += 1
        return Task(scheduler: self)
    }

    func fireScheduledTick(at index: Int) {
        handlers[index]()
    }

    private final class Task: CodexAuthBoundaryRepeatingTask {
        private weak var scheduler: ManualRepeatingScheduler?
        private var isCancelled = false

        init(scheduler: ManualRepeatingScheduler) {
            self.scheduler = scheduler
        }

        func cancel() {
            guard !isCancelled else { return }
            isCancelled = true
            scheduler?.activeTaskCount -= 1
            scheduler?.cancelCount += 1
        }
    }
}

@MainActor
private final class ObserverBoundaryBox {
    var value: QuotaAccountBoundary?

    init(_ value: QuotaAccountBoundary?) {
        self.value = value
    }
}
