import AppKit

enum ClaimedInstallationRevalidationDecision: Equatable {
    case continueUsing(
        identity: AppInstallationIdentity?,
        shouldPersist: Bool,
        allowsAutomaticLoginItemReconciliation: Bool
    )
    case redirect(AppInstallationIdentity)
    case reject(String)
}

@MainActor
enum ClaimedInstallationRevalidationPolicy {
    static func decide(
        claimedIdentity: AppInstallationIdentity?,
        resolution: AppInstallationAuthority.Resolution
    ) -> ClaimedInstallationRevalidationDecision {
        switch resolution {
        case let .useCurrent(identity, shouldPersist, allowsAutomaticReconciliation):
            guard identity != claimedIdentity else {
                return .continueUsing(
                    identity: identity,
                    shouldPersist: shouldPersist,
                    allowsAutomaticLoginItemReconciliation: allowsAutomaticReconciliation
                )
            }
            guard let identity else {
                return .reject("App installation identity disappeared after ownership claim")
            }
            return .redirect(identity)

        case .redirect(let preferredIdentity):
            return .redirect(preferredIdentity)

        case .reject(let reason):
            return .reject(reason)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let installationAuthority = AppInstallationAuthority()
    private let singleInstanceCoordinator = SingleInstanceCoordinator()
    private var isPrimaryInstance = false
    private var isTerminating = false
    private var isRedirectingToPreferredInstallation = false
    private var didStopOwnedServices = false
    private var shouldShowPopoverAfterLaunch = false
    private var currentInstallationIdentity: AppInstallationIdentity?
    private var allowsAutomaticLoginItemReconciliation = false
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
    private var preferredRedirectTimeoutTask: Task<Void, Never>?

    func applicationWillFinishLaunching(_ notification: Notification) {
        switch installationAuthority.resolveCurrentInstallation() {
        case let .useCurrent(identity, _, allowsAutomaticReconciliation):
            currentInstallationIdentity = identity
            allowsAutomaticLoginItemReconciliation = allowsAutomaticReconciliation

        case .redirect(let preferredIdentity):
            redirectToPreferredInstallation(preferredIdentity)
            return

        case .reject(let reason):
            AppLogger.lifecycle.error("App installation validation failed closed: \(reason, privacy: .public)")
            NSApp.terminate(nil)
            return
        }

        let claim = claimSingleInstanceOwnership()
        switch claim {
        case .owner:
            // Close the resolve/claim race before this process becomes the
            // authoritative owner or writes an installation preference. Never
            // relabel this already-running process with a different on-disk code
            // identity after a same-path cover install.
            guard finalizeClaimedOwnership(
                claimedIdentity: currentInstallationIdentity,
                failureContext: "after ownership claim"
            ) else { return }
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
        let launchAtLoginManager = LaunchAtLoginManager(
            currentInstallationIdentity: currentInstallationIdentity,
            allowsAutomaticReconciliation: allowsAutomaticLoginItemReconciliation
        )
        launchAtLoginManager.reconcileAtLaunch()

        let scheduler = RefreshScheduler { [weak state] trigger in
            guard let state else { return }
            await state.refreshNow(trigger: trigger)
        }
        state.onRefreshSchedulingStateChanged = { [weak scheduler] schedulingState in
            scheduler?.updateSchedule(with: schedulingState)
        }
        state.onRefreshRequested = { [weak scheduler] trigger in
            scheduler?.requestRefresh(trigger)
        }
        scheduler.updateSchedule(with: state.refreshSchedulingState)

        let popoverController = PopoverController(
            appState: state,
            launchAtLoginManager: launchAtLoginManager,
            onRefresh: { [weak scheduler] in
                scheduler?.requestRefresh(.manual)
            }
        )
        let statusBarController = StatusBarController(appState: state)
        let widgetTimelineBridge = WidgetTimelineBridge(appState: state)
        AppLogger.statusBar.info("Status bar controller created")

        statusBarController.setTarget(self, action: #selector(togglePopover(_:)))

        scheduler.start()
        scheduler.pause(for: .networkUnavailable)

        let networkObserver = NetworkReachabilityObserver { [weak scheduler, weak state] change in
            switch change {
            case .becameReachable:
                state?.updateNetworkReachability(true)
                scheduler?.resume(for: .networkUnavailable)
                scheduler?.requestRefresh(.networkRestored)
            case .becameUnreachable:
                scheduler?.pause(for: .networkUnavailable)
                state?.updateNetworkReachability(false)
            case .connectionChanged:
                scheduler?.requestRefresh(.networkChanged)
            }
        }
        networkObserver.start()

        // Sleep/wake: pause independently from reachability. After the wake
        // stabilization delay, both the explicit wake and the renewed path
        // availability decision enter the same coalescing scheduler.
        let observer = SleepWakeObserver(
            wakeDelaySeconds: 5,
            onSleep: { [weak scheduler, weak networkObserver] in
                scheduler?.pause(for: .systemSleep)
                networkObserver?.stop()
            },
            onWake: { [weak scheduler, weak networkObserver] in
                scheduler?.resume(for: .systemSleep)
                networkObserver?.start()
                scheduler?.requestRefresh(.wake)
            }
        )
        observer.start()

        // Wall-clock and presentation-environment changes can invalidate an
        // already scheduled deadline. Reconcile immediately; only a true
        // clock adjustment needs a new server request.
        let clockObserver = SystemClockObserver { [weak scheduler, weak state] changes in
            state?.reconcileTemporalState()
            if changes.contains(.clock) {
                scheduler?.requestRefresh(.systemClockChange)
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
        stopOwnedServicesForShutdown()
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

    private func claimSingleInstanceOwnership() -> SingleInstanceClaimResult {
        singleInstanceCoordinator.claim(
            installationIdentity: currentInstallationIdentity,
            shouldRelinquish: { [weak self] requestedIdentity in
                self?.shouldRelinquishOwnership(to: requestedIdentity) ?? false
            },
            commitRelinquishment: { [weak self] in
                self?.commitOwnershipRelinquishment() ?? false
            },
            didRelinquish: { [weak self] in
                self?.finishOwnershipRelinquishment()
            },
            onActivation: { [weak self] action in
                self?.handleForwardedActivation(action) ?? false
            }
        )
    }

    private func finalizeClaimedOwnership(
        claimedIdentity: AppInstallationIdentity?,
        failureContext: String
    ) -> Bool {
        let decision = ClaimedInstallationRevalidationPolicy.decide(
            claimedIdentity: claimedIdentity,
            resolution: installationAuthority.resolveCurrentInstallation()
        )
        switch decision {
        case let .continueUsing(identity, shouldPersist, allowsAutomaticReconciliation):
            currentInstallationIdentity = identity
            allowsAutomaticLoginItemReconciliation = allowsAutomaticReconciliation
            guard singleInstanceCoordinator.updateOwnedInstallationIdentity(identity) else {
                singleInstanceCoordinator.release()
                AppLogger.lifecycle.error("Failed to publish the verified owner installation identity \(failureContext, privacy: .public)")
                NSApp.terminate(nil)
                return false
            }
            if shouldPersist, let identity {
                installationAuthority.persistPreferredInstallation(identity)
            }
            isPrimaryInstance = true
            return true

        case .redirect(let revalidatedIdentity):
            singleInstanceCoordinator.release()
            AppLogger.lifecycle.info("Installation identity changed \(failureContext, privacy: .public); restarting from the revalidated bundle")
            redirectToPreferredInstallation(revalidatedIdentity)
            return false

        case .reject(let reason):
            singleInstanceCoordinator.release()
            AppLogger.lifecycle.error("App installation validation failed \(failureContext, privacy: .public): \(reason, privacy: .public)")
            NSApp.terminate(nil)
            return false
        }
    }

    private func shouldRelinquishOwnership(
        to requestedIdentity: AppInstallationIdentity
    ) -> Bool {
        guard isPrimaryInstance,
              !isTerminating,
              let currentIdentity = currentInstallationIdentity,
              currentInstallationIdentity != requestedIdentity,
              currentIdentity.signingAnchorDigest != nil,
              currentIdentity.signingAnchorDigest == requestedIdentity.signingAnchorDigest,
              let currentVersion = currentIdentity.version,
              let requestedVersion = requestedIdentity.version,
              requestedVersion.isNotOlder(than: currentVersion),
              installationAuthority.revalidateRedirectTarget(requestedIdentity) else {
            return false
        }

        if !currentVersion.isNotOlder(than: requestedVersion),
           currentIdentity.hasCertificateBackedSignature,
           requestedIdentity.hasCertificateBackedSignature {
            // An explicitly launched, same-signer newer build must not be
            // forced back to an already-running older copy solely by path rank.
            return true
        }

        if installationAuthority.isValidMovedSuccessor(
            requestedIdentity,
            replacing: currentIdentity
        ) {
            return true
        }

        if installationAuthority.isRecordedPreferredInstallation(requestedIdentity) {
            return true
        }

        switch installationAuthority.resolveCurrentInstallation() {
        case .redirect(let preferredIdentity):
            return preferredIdentity == requestedIdentity

        case .useCurrent(let onDiskIdentity, _, _):
            // A same-path cover install can replace the executable and signing
            // envelope while the old process is still alive. The identity
            // captured by that process remains the proof that it is stale.
            return onDiskIdentity == requestedIdentity
                && currentInstallationIdentity?.bundlePath == requestedIdentity.bundlePath
                && currentInstallationIdentity != requestedIdentity

        case .reject:
            return false
        }
    }

    private func commitOwnershipRelinquishment() -> Bool {
        guard isPrimaryInstance, !isTerminating else { return false }
        isPrimaryInstance = false
        isTerminating = true
        stopOwnedServicesForShutdown()
        AppLogger.lifecycle.info("Stopped owner services before committed installation handoff")
        return true
    }

    private func finishOwnershipRelinquishment() {
        NSApp.setActivationPolicy(.prohibited)
        AppLogger.lifecycle.info("Committed installation handoff released single-instance ownership")
        NSApp.terminate(nil)
    }

    private func stopOwnedServicesForShutdown() {
        guard !didStopOwnedServices else { return }
        didStopOwnedServices = true
        preferredRedirectTimeoutTask?.cancel()
        preferredRedirectTimeoutTask = nil
        popoverController?.teardown()
        statusBarController?.teardown()
        popoverController = nil
        statusBarController = nil
        singleInstanceCoordinator.prepareForShutdown()
        refreshScheduler?.stop()
        sleepWakeObserver?.stop()
        networkReachabilityObserver?.stop()
        systemClockObserver?.stop()
        authBoundaryObserver?.stop()
        appState?.shutdown()
    }

    private func redirectToPreferredInstallation(_ preferredIdentity: AppInstallationIdentity) {
        guard !isRedirectingToPreferredInstallation else { return }
        isRedirectingToPreferredInstallation = true
        isTerminating = true
        NSApp.setActivationPolicy(.prohibited)

        guard installationAuthority.revalidateRedirectTarget(preferredIdentity) else {
            AppLogger.lifecycle.error("Preferred app redirect target changed before launch; failing closed")
            NSApp.terminate(nil)
            return
        }

        let expectedURL = preferredIdentity.bundleURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
        preferredRedirectTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled,
                  self?.isRedirectingToPreferredInstallation == true else {
                return
            }
            self?.finishPreferredInstallationRedirect(
                ownerConfirmed: false,
                errorDescription: "launch confirmation timed out"
            )
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(
            at: preferredIdentity.bundleURL,
            configuration: configuration
        ) { [weak self] application, error in
            let launchedURL = application?.bundleURL.map {
                $0.resolvingSymlinksInPath().standardizedFileURL
            }
            let errorDescription = error?.localizedDescription
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard launchedURL == expectedURL, error == nil else {
                    self.finishPreferredInstallationRedirect(
                        ownerConfirmed: false,
                        errorDescription: errorDescription ?? "unexpected launched path"
                    )
                    return
                }
                self.beginPreferredOwnerConfirmation(preferredIdentity)
            }
        }
    }

    private func beginPreferredOwnerConfirmation(
        _ expectedIdentity: AppInstallationIdentity
    ) {
        preferredRedirectTimeoutTask?.cancel()
        preferredRedirectTimeoutTask = Task { @MainActor [weak self] in
            for _ in 0..<50 {
                guard !Task.isCancelled,
                      self?.isRedirectingToPreferredInstallation == true else {
                    return
                }
                if self?.preferredInstallationOwnsSingleInstance(expectedIdentity) == true {
                    self?.finishPreferredInstallationRedirect(
                        ownerConfirmed: true,
                        errorDescription: nil
                    )
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard !Task.isCancelled else { return }
            self?.finishPreferredInstallationRedirect(
                ownerConfirmed: false,
                errorDescription: "preferred process launched but never became the verified owner"
            )
        }
    }

    private func preferredInstallationOwnsSingleInstance(
        _ expectedIdentity: AppInstallationIdentity
    ) -> Bool {
        guard installationAuthority.revalidateRedirectTarget(expectedIdentity),
              let owner = singleInstanceCoordinator.stableOwnerRecordHoldingLock(),
              owner.installationIdentity == expectedIdentity,
              let runningOwner = NSRunningApplication(processIdentifier: owner.pid),
              !runningOwner.isTerminated,
              runningOwner.bundleIdentifier == expectedIdentity.bundleIdentifier,
              runningOwner.bundleURL?.resolvingSymlinksInPath().standardizedFileURL
                == expectedIdentity.bundleURL.resolvingSymlinksInPath().standardizedFileURL else {
            return false
        }
        return true
    }

    private func finishPreferredInstallationRedirect(
        ownerConfirmed: Bool,
        errorDescription: String?
    ) {
        guard isRedirectingToPreferredInstallation else { return }
        isRedirectingToPreferredInstallation = false
        preferredRedirectTimeoutTask?.cancel()
        preferredRedirectTimeoutTask = nil

        if ownerConfirmed {
            if let token = redirectVerificationToken {
                AppLogger.lifecycle.info("Verified redirect to the recorded preferred app installation token=\(token, privacy: .public)")
            } else {
                AppLogger.lifecycle.info("Verified redirect to the recorded preferred app installation")
            }
        } else {
            AppLogger.lifecycle.error(
                "Preferred app redirect failed closed: \(errorDescription ?? "unexpected launched path", privacy: .public)"
            )
        }
        NSApp.terminate(nil)
    }

    private var redirectVerificationToken: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--codex-monitor-redirect-verification-token"),
              arguments.indices.contains(index + 1),
              UUID(uuidString: arguments[index + 1]) != nil else {
            return nil
        }
        return arguments[index + 1]
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
