import Foundation
import XCTest
@testable import CodexMonitorNative

@MainActor
final class CodexAuthBoundaryObserverTests: XCTestCase {
    func testObserverReportsBoundaryChangeAndStopsCleanly() async {
        let changed = expectation(description: "auth boundary changed")
        let boundary = ObserverBoundaryBox(.testDefault)
        var hasFulfilled = false
        let observer = CodexAuthBoundaryObserver(
            pollInterval: 0.01,
            boundaryProvider: { boundary.value },
            onChange: {
                guard !hasFulfilled else { return }
                hasFulfilled = true
                changed.fulfill()
            }
        )
        observer.start()
        XCTAssertTrue(observer.isRunning)

        boundary.value = .testOtherAccount
        await fulfillment(of: [changed], timeout: 2)

        observer.stop()
        XCTAssertFalse(observer.isRunning)
    }
}

@MainActor
private final class ObserverBoundaryBox {
    var value: QuotaAccountBoundary?

    init(_ value: QuotaAccountBoundary?) {
        self.value = value
    }
}
