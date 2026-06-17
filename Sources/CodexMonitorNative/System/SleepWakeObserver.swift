import AppKit

@MainActor
final class SleepWakeObserver {
    private let notificationCenter: NotificationCenter
    private let wakeNotificationName: Notification.Name
    private let onWake: @MainActor () -> Void
    private var observers: [NSObjectProtocol] = []

    init(
        notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        wakeNotificationName: Notification.Name = NSWorkspace.didWakeNotification,
        onWake: @escaping @MainActor () -> Void
    ) {
        self.notificationCenter = notificationCenter
        self.wakeNotificationName = wakeNotificationName
        self.onWake = onWake
    }

    func start() {
        stop()
        AppLogger.system.info("Starting sleep/wake observer")

        let onWake = self.onWake
        let wakeObserver = notificationCenter.addObserver(
            forName: wakeNotificationName,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard self != nil else {
                return
            }
            Task { @MainActor in
                AppLogger.system.info("Received wake notification")
                onWake()
            }
        }

        observers = [wakeObserver]
    }

    func stop() {
        if !observers.isEmpty {
            AppLogger.system.info("Stopping sleep/wake observer")
        }
        for observer in observers {
            notificationCenter.removeObserver(observer)
        }
        observers.removeAll()
    }
}
