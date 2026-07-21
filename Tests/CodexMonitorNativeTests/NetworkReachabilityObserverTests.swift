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

    func testStopInvalidatesPathDeliveredBeforeDispatcherRuns() async {
        let monitorFactory = NetworkPathMonitorFactory()
        let dispatcher = NetworkPathControlledDispatcher()
        var changes: [NetworkReachabilityChange] = []
        let observer = NetworkReachabilityObserver(
            monitorFactory: monitorFactory.make,
            dispatchTask: dispatcher.dispatch,
            onChange: { changes.append($0) }
        )

        observer.start()
        monitorFactory.monitors[0].emit(NetworkPathSnapshot(isReachable: true, activeInterfaces: [.wifi]))
        XCTAssertEqual(dispatcher.pendingCount, 1)

        observer.stop()
        await dispatcher.runAll()

        XCTAssertTrue(changes.isEmpty)
        XCTAssertFalse(observer.hasActiveMonitor)
        XCTAssertEqual(monitorFactory.monitors[0].cancelCount, 1)
    }

    func testRestartInvalidatesOldMonitorLateEmissionsAndDeliversNewMonitorPath() async {
        let monitorFactory = NetworkPathMonitorFactory()
        let dispatcher = NetworkPathControlledDispatcher()
        var changes: [NetworkReachabilityChange] = []
        let observer = NetworkReachabilityObserver(
            monitorFactory: monitorFactory.make,
            dispatchTask: dispatcher.dispatch,
            onChange: { changes.append($0) }
        )

        observer.start()
        let oldMonitor = monitorFactory.monitors[0]
        oldMonitor.emit(NetworkPathSnapshot(isReachable: true, activeInterfaces: [.wifi]))
        XCTAssertEqual(dispatcher.pendingCount, 1)

        observer.start()
        let newMonitor = monitorFactory.monitors[1]
        oldMonitor.emit(NetworkPathSnapshot(isReachable: false, supportsDNS: false))
        newMonitor.emit(NetworkPathSnapshot(isReachable: true, activeInterfaces: [.wiredEthernet]))
        XCTAssertEqual(dispatcher.pendingCount, 3)

        await dispatcher.runAll()

        XCTAssertEqual(changes, [.becameReachable])
        XCTAssertEqual(oldMonitor.cancelCount, 1)
        XCTAssertEqual(newMonitor.cancelCount, 0)
        observer.stop()
    }

    func testRepeatedStartStopCancelsEachMonitorExactlyOnce() {
        let monitorFactory = NetworkPathMonitorFactory()
        let observer = NetworkReachabilityObserver(monitorFactory: monitorFactory.make) { _ in }

        for _ in 0..<20 {
            observer.start()
            XCTAssertTrue(observer.hasActiveMonitor)
            observer.stop()
            XCTAssertFalse(observer.hasActiveMonitor)
        }

        XCTAssertEqual(monitorFactory.monitors.count, 20)
        XCTAssertTrue(monitorFactory.monitors.allSatisfy { $0.startCount == 1 })
        XCTAssertTrue(monitorFactory.monitors.allSatisfy { $0.cancelCount == 1 })
    }
}

@MainActor
private final class NetworkPathMonitorFactory {
    private(set) var monitors: [FakeNetworkPathMonitor] = []

    func make() -> any NetworkPathMonitoring {
        let monitor = FakeNetworkPathMonitor()
        monitors.append(monitor)
        return monitor
    }
}

private final class FakeNetworkPathMonitor: NetworkPathMonitoring, @unchecked Sendable {
    var pathUpdateHandler: (@Sendable (NetworkPathSnapshot) -> Void)?
    private(set) var startCount = 0
    private(set) var cancelCount = 0

    func start(queue: DispatchQueue) {
        startCount += 1
    }

    func cancel() {
        cancelCount += 1
    }

    func emit(_ snapshot: NetworkPathSnapshot) {
        pathUpdateHandler?(snapshot)
    }
}

private final class NetworkPathControlledDispatcher: @unchecked Sendable {
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
