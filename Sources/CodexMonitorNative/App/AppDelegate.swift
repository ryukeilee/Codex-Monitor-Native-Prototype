import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let singleInstanceCoordinator = SingleInstanceCoordinator()
    private var isPrimaryInstance = false
    private var isTerminating = false
    private var shouldShowPopoverAfterLaunch = false
    private var appState: AppState?
    private var launchAtLoginManager: LaunchAtLoginManager?
    private var statusBarController: StatusBarController?
    private var popoverController: PopoverController?
    private var refreshScheduler: RefreshScheduler?
    private var sleepWakeObserver: SleepWakeObserver?
    private var networkReachabilityObserver: NetworkReachabilityObserver?
    private var systemClockObserver: SystemClockObserver?
    private var authBoundaryObserver: CodexAuthBoundaryObserver?
    private var widgetTimelineBridge: WidgetTimelineBridge?

    func applicationWillFinishLaunching(_ notification: Notification) {
        let claim = singleInstanceCoordinator.claim { [weak self] action in
            self?.handleForwardedActivation(action) ?? false
        }
        switch claim {
        case .owner:
            isPrimaryInstance = true
            AppLogger.lifecycle.info("Acquired global single-instance ownership")
        case .secondary(let forwardedActivation):
            AppLogger.lifecycle.info("Existing instance owns the app; forwarded activation=\(forwardedActivation, privacy: .public)")
            NSApp.terminate(nil)
        case .failed(let reason):
            AppLogger.lifecycle.error("Single-instance arbitration failed closed: \(reason, privacy: .public)")
            NSApp.terminate(nil)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard isPrimaryInstance else { return }
        NSApp.setActivationPolicy(.accessory)
        AppLogger.lifecycle.info("App ready; launching in accessory mode")

        let snapshotStore = SnapshotStore()
        let refreshService = QuotaRefreshService()
        let state = AppState(
            snapshotStore: snapshotStore,
            refreshService: refreshService,
            initialNetworkReachability: nil,
            accountBoundaryProvider: {
                CodexAuthIdentityReader.currentBoundary()
            }
        )
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
        scheduler.pause(for: .networkUnavailable)

        let networkObserver = NetworkReachabilityObserver { [weak scheduler, weak state] change in
            switch change {
            case .becameReachable:
                state?.updateNetworkReachability(true)
                scheduler?.resume(for: .networkUnavailable)
                state?.refresh(trigger: .networkRestored)
            case .becameUnreachable:
                scheduler?.pause(for: .networkUnavailable)
                state?.updateNetworkReachability(false)
            case .connectionChanged:
                state?.refresh(trigger: .networkChanged)
            }
        }
        networkObserver.start()

        // Sleep/wake: pause independently from reachability. After the wake
        // stabilization delay, restarting the path monitor produces one fresh
        // availability decision and, when reachable, one controlled refresh.
        let observer = SleepWakeObserver(
            wakeDelaySeconds: 5,
            onSleep: { [weak scheduler, weak networkObserver] in
                scheduler?.pause(for: .systemSleep)
                networkObserver?.stop()
            },
            onWake: { [weak scheduler, weak networkObserver] in
                scheduler?.resume(for: .systemSleep)
                networkObserver?.start()
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

        let authBoundaryObserver = CodexAuthBoundaryObserver { [weak state] in
            state?.accountBoundaryDidChange()
        }
        authBoundaryObserver.start()
        // Close the small launch window between AppState restoration and the
        // observer's initial sample before any cached quota remains visible.
        state.accountBoundaryDidChange()

        self.appState = state
        self.launchAtLoginManager = launchAtLoginManager
        self.popoverController = popoverController
        self.statusBarController = statusBarController
        self.refreshScheduler = scheduler
        self.sleepWakeObserver = observer
        self.networkReachabilityObserver = networkObserver
        self.systemClockObserver = clockObserver
        self.authBoundaryObserver = authBoundaryObserver
        self.widgetTimelineBridge = widgetTimelineBridge

        if shouldShowPopoverAfterLaunch {
            shouldShowPopoverAfterLaunch = false
            showPopoverAndActivate()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppLogger.lifecycle.info("Application will terminate")
        isTerminating = true
        singleInstanceCoordinator.prepareForShutdown()
        refreshScheduler?.stop()
        sleepWakeObserver?.stop()
        networkReachabilityObserver?.stop()
        systemClockObserver?.stop()
        authBoundaryObserver?.stop()
        appState?.shutdown()
        singleInstanceCoordinator.release()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        isTerminating = true
        singleInstanceCoordinator.prepareForShutdown()
        return .terminateNow
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        guard isPrimaryInstance else { return false }
        showPopoverAndActivate()
        return true
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

    private func handleForwardedActivation(_ action: SingleInstanceActivationAction) -> Bool {
        guard isPrimaryInstance, !isTerminating, action == .showPopover else { return false }
        guard statusBarController != nil, popoverController != nil else {
            shouldShowPopoverAfterLaunch = true
            return true
        }
        return showPopoverAndActivate()
    }

    @discardableResult
    private func showPopoverAndActivate() -> Bool {
        guard let button = statusBarController?.statusButton else {
            shouldShowPopoverAfterLaunch = true
            return false
        }
        NSApp.activate()
        popoverController?.show(relativeTo: button)
        return popoverController != nil
    }
}
