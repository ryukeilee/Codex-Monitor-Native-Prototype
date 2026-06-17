import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var appState: AppState?
    private var launchAtLoginManager: LaunchAtLoginManager?
    private var statusBarController: StatusBarController?
    private var popoverController: PopoverController?
    private var refreshScheduler: RefreshScheduler?
    private var sleepWakeObserver: SleepWakeObserver?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        AppLogger.lifecycle.info("App ready; launching in accessory mode")

        let snapshotStore = SnapshotStore()
        let refreshService = QuotaRefreshService()
        let state = AppState(snapshotStore: snapshotStore, refreshService: refreshService)
        let launchAtLoginManager = LaunchAtLoginManager()
        let popoverController = PopoverController(appState: state, launchAtLoginManager: launchAtLoginManager)
        let statusBarController = StatusBarController(appState: state)
        AppLogger.statusBar.info("Status bar controller created")

        statusBarController.setTarget(self, action: #selector(togglePopover(_:)))

        // Trigger an initial refresh after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak state] in
            state?.refresh(trigger: .manual)
        }

        let scheduler = RefreshScheduler(interval: 300) { [weak state] in
            state?.refresh(trigger: .scheduled)
        }
        scheduler.start()

        let observer = SleepWakeObserver { [weak state] in
            state?.refresh(trigger: .wake)
        }
        observer.start()

        self.appState = state
        self.launchAtLoginManager = launchAtLoginManager
        self.popoverController = popoverController
        self.statusBarController = statusBarController
        self.refreshScheduler = scheduler
        self.sleepWakeObserver = observer
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppLogger.lifecycle.info("Application will terminate")
        refreshScheduler?.stop()
        sleepWakeObserver?.stop()
    }

    @objc
    private func togglePopover(_ sender: AnyObject?) {
        guard let button = statusBarController?.statusButton else {
            AppLogger.popover.error("Tried to toggle popover without a status button")
            return
        }

        AppLogger.popover.info("Status item clicked")
        popoverController?.toggle(relativeTo: button)
    }
}
