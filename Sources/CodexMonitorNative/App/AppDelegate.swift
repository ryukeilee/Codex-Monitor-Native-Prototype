import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var appState: AppState?
    private var launchAtLoginManager: LaunchAtLoginManager?
    private var statusBarController: StatusBarController?
    private var popoverController: PopoverController?
    private var refreshScheduler: RefreshScheduler?
    private var sleepWakeObserver: SleepWakeObserver?
    private var systemClockObserver: SystemClockObserver?
    private var widgetTimelineBridge: WidgetTimelineBridge?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        AppLogger.lifecycle.info("App ready; launching in accessory mode")

        let snapshotStore = SnapshotStore()
        let refreshService = QuotaRefreshService()
        let state = AppState(snapshotStore: snapshotStore, refreshService: refreshService)
        let launchAtLoginManager = LaunchAtLoginManager()
        let popoverController = PopoverController(appState: state, launchAtLoginManager: launchAtLoginManager)
        let statusBarController = StatusBarController(appState: state)
        let widgetTimelineBridge = WidgetTimelineBridge(appState: state)
        AppLogger.statusBar.info("Status bar controller created")

        statusBarController.setTarget(self, action: #selector(togglePopover(_:)))

        // Scheduler with dynamic backoff
        let scheduler = RefreshScheduler(interval: 300) { [weak state] in
            state?.refresh(trigger: .scheduled)
        }

        // Wire backoff changes from AppState → Scheduler
        state.onBackoffChanged = { [weak scheduler] newInterval in
            scheduler?.updateInterval(newInterval)
        }

        scheduler.start()

        // Sleep/wake: pause timer on sleep, delayed refresh on wake
        let observer = SleepWakeObserver(
            wakeDelaySeconds: 5,
            onSleep: { [weak scheduler] in
                scheduler?.pause()
            },
            onWake: { [weak scheduler, weak state] in
                scheduler?.resume()
                state?.refresh(trigger: .wake)
            }
        )
        observer.start()

        // Wall-clock and presentation-environment changes can invalidate an
        // already scheduled deadline. Reconcile immediately; only a true
        // clock adjustment needs a new server request.
        let clockObserver = SystemClockObserver { [weak state] changes in
            state?.reconcileTemporalState()
            if changes.contains(.clock) {
                state?.refresh(trigger: .systemClockChange)
            }
        }
        clockObserver.start()

        // Initial refresh after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak state] in
            state?.refresh(trigger: .manual)
        }

        self.appState = state
        self.launchAtLoginManager = launchAtLoginManager
        self.popoverController = popoverController
        self.statusBarController = statusBarController
        self.refreshScheduler = scheduler
        self.sleepWakeObserver = observer
        self.systemClockObserver = clockObserver
        self.widgetTimelineBridge = widgetTimelineBridge
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppLogger.lifecycle.info("Application will terminate")
        refreshScheduler?.stop()
        sleepWakeObserver?.stop()
        systemClockObserver?.stop()
        appState?.shutdown()
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
