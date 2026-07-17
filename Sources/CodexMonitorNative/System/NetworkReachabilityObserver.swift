import Foundation
import Network

struct NetworkPathSnapshot: Equatable, Sendable {
    enum Interface: String, CaseIterable, Sendable {
        case wiredEthernet
        case wifi
        case cellular
        case loopback
        case other
    }

    let isReachable: Bool
    let activeInterfaces: Set<Interface>
    let isExpensive: Bool
    let isConstrained: Bool
    let supportsDNS: Bool
    let supportsIPv4: Bool
    let supportsIPv6: Bool

    init(
        isReachable: Bool,
        activeInterfaces: Set<Interface> = [],
        isExpensive: Bool = false,
        isConstrained: Bool = false,
        supportsDNS: Bool = true,
        supportsIPv4: Bool = true,
        supportsIPv6: Bool = true
    ) {
        self.isReachable = isReachable
        self.activeInterfaces = activeInterfaces
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
        self.supportsDNS = supportsDNS
        self.supportsIPv4 = supportsIPv4
        self.supportsIPv6 = supportsIPv6
    }

    init(path: NWPath) {
        isReachable = path.status == .satisfied
        activeInterfaces = Set(Interface.allCases.filter { path.usesInterfaceType($0.nwInterfaceType) })
        isExpensive = path.isExpensive
        isConstrained = path.isConstrained
        supportsDNS = path.supportsDNS
        supportsIPv4 = path.supportsIPv4
        supportsIPv6 = path.supportsIPv6
    }
}

private extension NetworkPathSnapshot.Interface {
    var nwInterfaceType: NWInterface.InterfaceType {
        switch self {
        case .wiredEthernet: return .wiredEthernet
        case .wifi: return .wifi
        case .cellular: return .cellular
        case .loopback: return .loopback
        case .other: return .other
        }
    }
}

enum NetworkReachabilityChange: Equatable, Sendable {
    case becameReachable
    case becameUnreachable
    case connectionChanged

    static func classify(
        previous: NetworkPathSnapshot?,
        current: NetworkPathSnapshot
    ) -> NetworkReachabilityChange? {
        guard let previous else {
            return current.isReachable ? .becameReachable : .becameUnreachable
        }
        guard previous != current else { return nil }

        switch (previous.isReachable, current.isReachable) {
        case (false, true):
            return .becameReachable
        case (true, false):
            return .becameUnreachable
        case (true, true):
            return .connectionChanged
        case (false, false):
            return nil
        }
    }
}

@MainActor
final class NetworkReachabilityObserver {
    private let queue: DispatchQueue
    private let dispatchTask: @Sendable (@escaping @MainActor @Sendable () -> Void) -> Void
    private let onChange: @MainActor (NetworkReachabilityChange) -> Void
    private let resources = NetworkReachabilityResources()

    var hasActiveMonitor: Bool { resources.monitor != nil }

    init(
        queue: DispatchQueue = DispatchQueue(label: "CodexMonitorNative.network-reachability"),
        dispatchTask: @escaping @Sendable (@escaping @MainActor @Sendable () -> Void) -> Void = { action in
            Task { @MainActor in action() }
        },
        onChange: @escaping @MainActor (NetworkReachabilityChange) -> Void
    ) {
        self.queue = queue
        self.dispatchTask = dispatchTask
        self.onChange = onChange
    }

    func start() {
        stop()
        let generation = resources.start()
        let monitor = NWPathMonitor()
        let onChange = self.onChange
        let dispatchTask = self.dispatchTask

        monitor.pathUpdateHandler = { [weak resources] path in
            let snapshot = NetworkPathSnapshot(path: path)
            dispatchTask {
                guard let resources, resources.isCurrent(generation) else { return }
                let previous = resources.previousSnapshot
                resources.previousSnapshot = snapshot
                guard let change = NetworkReachabilityChange.classify(
                    previous: previous,
                    current: snapshot
                ) else {
                    return
                }
                AppLogger.system.info("Network path changed: \(String(describing: change), privacy: .public)")
                onChange(change)
            }
        }

        resources.monitor = monitor
        AppLogger.system.info("Starting network reachability observer")
        monitor.start(queue: queue)
    }

    func stop() {
        if resources.monitor != nil {
            AppLogger.system.info("Stopping network reachability observer")
        }
        resources.stop()
    }
}

private final class NetworkReachabilityResources: @unchecked Sendable {
    var monitor: NWPathMonitor?
    var previousSnapshot: NetworkPathSnapshot?
    private var generation = 0

    func start() -> Int {
        generation &+= 1
        return generation
    }

    func isCurrent(_ expectedGeneration: Int) -> Bool {
        generation == expectedGeneration
    }

    func stop() {
        generation &+= 1
        monitor?.cancel()
        monitor = nil
        previousSnapshot = nil
    }

    deinit {
        stop()
    }
}
