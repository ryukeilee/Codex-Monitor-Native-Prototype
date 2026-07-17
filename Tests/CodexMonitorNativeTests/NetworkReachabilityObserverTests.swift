import XCTest
@testable import CodexMonitorNative

@MainActor
final class NetworkReachabilityObserverTests: XCTestCase {
    func testInitialPathClassifiesCurrentAvailability() {
        XCTAssertEqual(
            NetworkReachabilityChange.classify(
                previous: nil,
                current: NetworkPathSnapshot(isReachable: true, activeInterfaces: [.wifi])
            ),
            .becameReachable
        )
        XCTAssertEqual(
            NetworkReachabilityChange.classify(
                previous: nil,
                current: NetworkPathSnapshot(isReachable: false, supportsDNS: false)
            ),
            .becameUnreachable
        )
    }

    func testDuplicateAndOfflineOnlyChangesDoNotProduceRefreshSignals() {
        let offline = NetworkPathSnapshot(isReachable: false, supportsDNS: false)
        XCTAssertNil(NetworkReachabilityChange.classify(previous: offline, current: offline))
        XCTAssertNil(
            NetworkReachabilityChange.classify(
                previous: offline,
                current: NetworkPathSnapshot(isReachable: false, supportsIPv4: false)
            )
        )
    }

    func testReachabilityTransitionsAndConnectionSwitchesAreDistinct() {
        let offline = NetworkPathSnapshot(isReachable: false, supportsDNS: false)
        let wifi = NetworkPathSnapshot(isReachable: true, activeInterfaces: [.wifi])
        let ethernet = NetworkPathSnapshot(isReachable: true, activeInterfaces: [.wiredEthernet])

        XCTAssertEqual(
            NetworkReachabilityChange.classify(previous: offline, current: wifi),
            .becameReachable
        )
        XCTAssertEqual(
            NetworkReachabilityChange.classify(previous: wifi, current: ethernet),
            .connectionChanged
        )
        XCTAssertEqual(
            NetworkReachabilityChange.classify(previous: ethernet, current: offline),
            .becameUnreachable
        )
    }

    func testReachablePathTraitChangeRequestsOneControlledRefresh() {
        let regularWifi = NetworkPathSnapshot(isReachable: true, activeInterfaces: [.wifi])
        let constrainedWifi = NetworkPathSnapshot(
            isReachable: true,
            activeInterfaces: [.wifi],
            isConstrained: true
        )

        XCTAssertEqual(
            NetworkReachabilityChange.classify(previous: regularWifi, current: constrainedWifi),
            .connectionChanged
        )
        XCTAssertNil(
            NetworkReachabilityChange.classify(previous: constrainedWifi, current: constrainedWifi)
        )
    }

    func testRepeatedStartStopConvergesMonitorResource() {
        let observer = NetworkReachabilityObserver { _ in }

        for _ in 0..<20 {
            observer.start()
            XCTAssertTrue(observer.hasActiveMonitor)
            observer.stop()
            XCTAssertFalse(observer.hasActiveMonitor)
        }
    }
}
