import Foundation

@MainActor
final class SystemClockObserver {
    struct Change: OptionSet, Equatable, Sendable {
        let rawValue: UInt8

        static let clock = Change(rawValue: 1 << 0)
        static let timeZone = Change(rawValue: 1 << 1)
        static let calendarDay = Change(rawValue: 1 << 2)
        static let locale = Change(rawValue: 1 << 3)
    }

    private let notificationCenter: NotificationCenter
    private let debounceNanoseconds: UInt64
    private let sleep: @Sendable (UInt64) async throws -> Void
    private let dispatchTask: @Sendable (@escaping @MainActor @Sendable () -> Void) -> Void
    private let onChange: @MainActor (Change) -> Void
    private let resources: SystemClockObserverResources

    var registeredObserverCount: Int { resources.observers.count }
    var hasPendingDelivery: Bool { resources.pendingDeliveryTask != nil }

    init(
        notificationCenter: NotificationCenter = .default,
        debounceNanoseconds: UInt64 = 250_000_000,
        sleep: @escaping @Sendable (UInt64) async throws -> Void = { nanoseconds in
            try await Task.sleep(nanoseconds: nanoseconds)
        },
        dispatchTask: @escaping @Sendable (@escaping @MainActor @Sendable () -> Void) -> Void = { action in
            Task { @MainActor in action() }
        },
        onChange: @escaping @MainActor (Change) -> Void
    ) {
        self.notificationCenter = notificationCenter
        self.debounceNanoseconds = debounceNanoseconds
        self.sleep = sleep
        self.dispatchTask = dispatchTask
        self.onChange = onChange
        self.resources = SystemClockObserverResources(notificationCenter: notificationCenter)
    }

    func start() {
        stop()
        let generation = resources.start()
        AppLogger.system.info("Starting system clock observer")

        let registrations: [(Notification.Name, Change)] = [
            (.NSSystemClockDidChange, .clock),
            (.NSSystemTimeZoneDidChange, .timeZone),
            (.NSCalendarDayChanged, .calendarDay),
            (NSLocale.currentLocaleDidChangeNotification, .locale)
        ]

        for (name, change) in registrations {
            let debounceNanoseconds = self.debounceNanoseconds
            let sleep = self.sleep
            let onChange = self.onChange
            let token = notificationCenter.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak resources, dispatchTask] _ in
                dispatchTask {
                    guard let resources, resources.isCurrent(generation) else { return }
                    resources.pendingChanges.formUnion(change)
                    resources.pendingDeliveryTask?.cancel()
                    resources.pendingDeliveryTask = Task { @MainActor [weak resources] in
                        do {
                            try await sleep(debounceNanoseconds)
                        } catch {
                            return
                        }

                        guard !Task.isCancelled,
                              let resources,
                              resources.isCurrent(generation) else {
                            return
                        }
                        let changes = resources.takePendingChanges(for: generation)
                        guard !changes.isEmpty else { return }
                        AppLogger.system.info("System temporal environment changed; reconciling presentation")
                        onChange(changes)
                    }
                }
            }
            resources.observers.append(token)
        }
    }

    func stop() {
        if !resources.observers.isEmpty {
            AppLogger.system.info("Stopping system clock observer")
        }
        resources.stop()
    }
}

private final class SystemClockObserverResources: @unchecked Sendable {
    let notificationCenter: NotificationCenter
    var observers: [NSObjectProtocol] = []
    var pendingDeliveryTask: Task<Void, Never>?
    var pendingChanges: SystemClockObserver.Change = []
    private var generation = 0

    init(notificationCenter: NotificationCenter) {
        self.notificationCenter = notificationCenter
    }

    func start() -> Int {
        generation &+= 1
        return generation
    }

    func isCurrent(_ expectedGeneration: Int) -> Bool {
        generation == expectedGeneration
    }

    func takePendingChanges(for expectedGeneration: Int) -> SystemClockObserver.Change {
        guard isCurrent(expectedGeneration) else { return [] }
        let changes = pendingChanges
        pendingChanges = []
        pendingDeliveryTask = nil
        return changes
    }

    func stop() {
        generation &+= 1
        for observer in observers {
            notificationCenter.removeObserver(observer)
        }
        observers.removeAll()
        pendingDeliveryTask?.cancel()
        pendingDeliveryTask = nil
        pendingChanges = []
    }

    deinit {
        stop()
    }
}
