import Foundation
import ServiceManagement

protocol LoginItemManaging {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

struct SystemLoginItemManager: LoginItemManaging {
    var status: SMAppService.Status {
        SMAppService.mainApp.status
    }

    func register() throws {
        try SMAppService.mainApp.register()
    }

    func unregister() throws {
        try SMAppService.mainApp.unregister()
    }
}

private struct LaunchAtLoginReconciliationFailure: Codable, Equatable {
    // Version 1 persisted transient failures as permanent launch suppression.
    // Rejecting it makes an upgraded app perform one fresh reconciliation.
    static let currentSchemaVersion = 2

    let schemaVersion: Int
    let desiredLaunchAtLogin: Bool
    let installationIdentity: AppInstallationIdentity?
    let systemStatusKey: String
    let errorSummary: String

    init(
        desiredLaunchAtLogin: Bool,
        installationIdentity: AppInstallationIdentity?,
        systemStatusKey: String,
        errorSummary: String
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.desiredLaunchAtLogin = desiredLaunchAtLogin
        self.installationIdentity = installationIdentity
        self.systemStatusKey = systemStatusKey
        self.errorSummary = errorSummary
    }
}

@MainActor
final class LaunchAtLoginManager: ObservableObject {
    enum StatusInfo: Equatable {
        case enabled
        case notRegistered
        case requiresApproval
        case notFound
        case registrationNeedsRepair
        case unavailable(String)
        case unknown(String)

        var isEnabled: Bool {
            self == .enabled
        }

        var message: String {
            switch self {
            case .enabled:
                return "已启用"
            case .notRegistered:
                return "未启用"
            case .requiresApproval:
                return "需在系统设置中批准"
            case .notFound:
                return "未找到登录项"
            case .registrationNeedsRepair:
                return "登录项未绑定到当前 App"
            case let .unavailable(reason):
                return reason
            case let .unknown(reason):
                return reason
            }
        }
    }

    @Published private(set) var isEnabled = false
    @Published private(set) var statusInfo: StatusInfo = .notRegistered
    @Published private(set) var isUpdating = false
    @Published private(set) var lastErrorSummary: String?
    @Published private(set) var desiredLaunchAtLogin = false

    private let loginItemManager: LoginItemManaging
    private let defaults: UserDefaults
    private let preferenceKey: String
    private let registrationIdentityKey: String
    private let reconciliationFailureKey: String
    private let currentInstallationIdentity: AppInstallationIdentity?
    private let allowsAutomaticReconciliation: Bool
    private var hasAuthoritativePreference = false
    private var didReconcileAtLaunch = false
    private var failedDesiredLaunchAtLogin: Bool?

    init(
        loginItemManager: LoginItemManaging = SystemLoginItemManager(),
        defaults: UserDefaults = .standard,
        preferenceKey: String = "codex.monitor.native.launchAtLogin.desired.v2",
        registrationIdentityKey: String = "codex.monitor.native.launchAtLogin.registrationIdentity.v1",
        reconciliationFailureKey: String = "codex.monitor.native.launchAtLogin.reconciliationFailure.v1",
        currentInstallationIdentity: AppInstallationIdentity? = SystemAppInstallationIdentityProvider()
            .identity(for: Bundle.main.bundleURL),
        allowsAutomaticReconciliation: Bool = true
    ) {
        self.loginItemManager = loginItemManager
        self.defaults = defaults
        self.preferenceKey = preferenceKey
        self.registrationIdentityKey = registrationIdentityKey
        self.reconciliationFailureKey = reconciliationFailureKey
        self.currentInstallationIdentity = currentInstallationIdentity
        self.allowsAutomaticReconciliation = allowsAutomaticReconciliation

        if let storedPreference = defaults.object(forKey: preferenceKey) as? Bool {
            desiredLaunchAtLogin = storedPreference
            hasAuthoritativePreference = true
        } else {
            switch loginItemManager.status {
            case .enabled, .requiresApproval:
                // Preserve a legacy request that either completed or is still
                // awaiting approval. `requiresApproval` is not effective
                // registration, but it is evidence that the user asked for it.
                desiredLaunchAtLogin = true
                hasAuthoritativePreference = true
                defaults.set(true, forKey: preferenceKey)
            case .notRegistered, .notFound:
                desiredLaunchAtLogin = false
            @unknown default:
                desiredLaunchAtLogin = false
            }
        }
        refreshStatus()
    }

    var shouldLaunchAtLogin: Bool {
        isEnabled
    }

    var helperText: String {
        statusInfo.message
    }

    var toggleValue: Bool {
        isEnabled
            || (failedDesiredLaunchAtLogin == false
                && matchingReconciliationFailure(desiredValue: false) != nil)
    }

    func refreshStatus() {
        let status = translatedStatus(for: loginItemManager.status)
        statusInfo = status
        isEnabled = status.isEnabled
        if status == .enabled {
            lastErrorSummary = nil
        }
        AppLogger.system.info("Launch at login status refreshed: \(String(describing: status), privacy: .public)")
    }

    func reconcileAtLaunch() {
        guard !didReconcileAtLaunch else { return }
        didReconcileAtLaunch = true
        guard allowsAutomaticReconciliation else {
            refreshStatus()
            return
        }

        if let failure = matchingReconciliationFailure(
            desiredValue: desiredLaunchAtLogin
        ) {
            refreshStatus()
            failedDesiredLaunchAtLogin = failure.desiredLaunchAtLogin
            lastErrorSummary = failure.errorSummary
            return
        }
        clearReconciliationFailure()

        if desiredLaunchAtLogin {
            reconcileEnabledState(userInitiated: false)
        } else if hasAuthoritativePreference {
            reconcileDisabledState()
        } else {
            refreshStatus()
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        AppLogger.system.info("Launch at login preference changed to \(enabled, privacy: .public)")
        desiredLaunchAtLogin = enabled
        hasAuthoritativePreference = true
        defaults.set(enabled, forKey: preferenceKey)
        clearReconciliationFailure()
        lastErrorSummary = nil

        guard #available(macOS 13.0, *) else {
            statusInfo = .unavailable("开机启动需要 macOS 13 或更新版本")
            isEnabled = false
            lastErrorSummary = "开机启动不可用"
            AppLogger.system.error("Launch at login unavailable on this macOS version")
            return
        }

        if enabled {
            reconcileEnabledState(userInitiated: true)
        } else {
            reconcileDisabledState()
        }
    }

    private func reconcileEnabledState(userInitiated: Bool) {
        guard currentInstallationIdentity != nil else {
            lastErrorSummary = "无法验证当前 App 安装"
            refreshStatus()
            return
        }

        isUpdating = true
        defer { isUpdating = false }

        let systemStatus = loginItemManager.status
        switch systemStatus {
        case .enabled:
            if registrationMatchesCurrentInstallation {
                refreshStatus()
            } else {
                replaceRegistrationWithCurrentInstallation()
            }

        case .notRegistered:
            // `SMAppService.mainApp.status` does not expose which bundle URL
            // owns a residual slot. Clear it first so an old-path registration
            // cannot turn a direct register into AlreadyRegistered.
            replaceRegistrationWithCurrentInstallation()

        case .notFound:
            replaceRegistrationWithCurrentInstallation()

        case .requiresApproval:
            if registrationMatchesCurrentInstallation {
                if userInitiated {
                    lastErrorSummary = "需在系统设置中批准"
                }
                refreshStatus()
            } else if userInitiated {
                replaceRegistrationWithCurrentInstallation()
            } else {
                // A legacy pending request does not include a registration
                // identity to repair. Keep it pending and let the user decide
                // whether to approve it or turn it off; never retry on launch.
                refreshStatus()
            }

        @unknown default:
            lastErrorSummary = "开机启动返回未知系统状态"
            refreshStatus()
        }
    }

    private func reconcileDisabledState() {
        isUpdating = true
        defer { isUpdating = false }

        switch loginItemManager.status {
        case .notRegistered, .notFound:
            clearRegisteredInstallationIdentity()
            clearReconciliationFailure()
            refreshStatus()
        case .enabled, .requiresApproval:
            unregisterExistingRegistration()
        @unknown default:
            unregisterExistingRegistration()
        }
    }

    private func replaceRegistrationWithCurrentInstallation() {
        registerCurrentInstallation(replacingExistingRegistration: true)
    }

    private func registerCurrentInstallation(replacingExistingRegistration: Bool) {
        var registrationSlotWasCleared = !replacingExistingRegistration
        if replacingExistingRegistration {
            do {
                try loginItemManager.unregister()
                registrationSlotWasCleared = true
                clearRegisteredInstallationIdentity()
                AppLogger.system.info("Removed stale launch at login registration before repair")
            } catch where isServiceManagementError(error, code: kSMErrorJobNotFound) {
                registrationSlotWasCleared = true
                clearRegisteredInstallationIdentity()
                AppLogger.system.info("No stale launch at login registration remained before repair")
            } catch {
                // Best-effort cleanup: an unexpected unregister error must not
                // block the actual registration attempt.
                AppLogger.system.error("Launch at login repair could not remove stale registration: \(error.localizedDescription, privacy: .public), proceeding to register anyway")
                refreshStatus()
            }
        }

        do {
            try loginItemManager.register()
            persistCurrentInstallationIdentity()
            AppLogger.system.info("Requested launch at login registration for current app installation")
        } catch {
            let refreshedSystemStatus = loginItemManager.status
            if refreshedSystemStatus == .requiresApproval,
               registrationSlotWasCleared,
               isServiceManagementError(error, code: kSMErrorLaunchDeniedByUser) {
                // A denied registration request still describes the current
                // main app after a confirmed empty/replaced registration slot.
                persistCurrentInstallationIdentity()
            }
            let errorSummary = shortErrorMessage(from: error)
            AppLogger.system.error("Launch at login registration failed: \(error.localizedDescription, privacy: .public)")
            refreshStatus()
            recordReconciliationFailure(
                errorSummary: errorSummary,
                suppressesAutomaticRetry: shouldSuppressAutomaticRetry(for: error)
            )
            return
        }

        clearReconciliationFailure()
        refreshStatus()
        if statusInfo != .enabled && statusInfo != .requiresApproval {
            recordReconciliationFailure(
                errorSummary: "开机启动未生效",
                suppressesAutomaticRetry: false
            )
        }
    }

    private func unregisterExistingRegistration() {
        do {
            try loginItemManager.unregister()
            clearRegisteredInstallationIdentity()
            clearReconciliationFailure()
            AppLogger.system.info("Requested launch at login unregistration for main app")
        } catch where isServiceManagementError(error, code: kSMErrorJobNotFound) {
            clearRegisteredInstallationIdentity()
            clearReconciliationFailure()
            AppLogger.system.info("Launch at login was already unregistered")
        } catch {
            let errorSummary = shortErrorMessage(from: error)
            AppLogger.system.error("Launch at login unregistration failed: \(error.localizedDescription, privacy: .public)")
            refreshStatus()
            recordReconciliationFailure(
                errorSummary: errorSummary,
                suppressesAutomaticRetry: shouldSuppressAutomaticRetry(for: error)
            )
            return
        }

        refreshStatus()
        if statusInfo != .notRegistered {
            recordReconciliationFailure(
                errorSummary: "开机启动关闭状态未确认",
                suppressesAutomaticRetry: false
            )
        }
    }

    private var registrationMatchesCurrentInstallation: Bool {
        guard let currentInstallationIdentity,
              let registeredIdentity = storedRegisteredInstallationIdentity() else {
            return false
        }
        return currentInstallationIdentity == registeredIdentity
    }

    private func translatedStatus(for status: SMAppService.Status) -> StatusInfo {
        switch status {
        case .enabled:
            guard currentInstallationIdentity != nil else {
                return .unavailable("无法验证当前 App 安装")
            }
            return registrationMatchesCurrentInstallation ? .enabled : .registrationNeedsRepair
        case .notRegistered:
            return .notRegistered
        case .requiresApproval:
            // Pending approval is never effective, so showing it does not
            // restore the old false-positive enabled state. It remains useful
            // even for pre-v2 registrations, which have no stored identity.
            return .requiresApproval
        case .notFound:
            return .notFound
        @unknown default:
            return .unknown("开机启动返回未知系统状态")
        }
    }

    private func persistCurrentInstallationIdentity() {
        guard let currentInstallationIdentity,
              let data = try? JSONEncoder().encode(currentInstallationIdentity) else {
            return
        }
        defaults.set(data, forKey: registrationIdentityKey)
    }

    private func clearRegisteredInstallationIdentity() {
        defaults.removeObject(forKey: registrationIdentityKey)
    }

    private func storedRegisteredInstallationIdentity() -> AppInstallationIdentity? {
        guard let data = defaults.data(forKey: registrationIdentityKey),
              let identity = try? JSONDecoder().decode(AppInstallationIdentity.self, from: data),
              identity.schemaVersion == AppInstallationIdentity.currentSchemaVersion else {
            return nil
        }
        return identity
    }

    private func recordReconciliationFailure(
        errorSummary: String,
        suppressesAutomaticRetry: Bool
    ) {
        lastErrorSummary = errorSummary
        failedDesiredLaunchAtLogin = desiredLaunchAtLogin
        guard suppressesAutomaticRetry else {
            defaults.removeObject(forKey: reconciliationFailureKey)
            return
        }
        let failure = LaunchAtLoginReconciliationFailure(
            desiredLaunchAtLogin: desiredLaunchAtLogin,
            installationIdentity: currentInstallationIdentity,
            systemStatusKey: systemStatusKey(loginItemManager.status),
            errorSummary: errorSummary
        )
        guard let data = try? JSONEncoder().encode(failure) else { return }
        defaults.set(data, forKey: reconciliationFailureKey)
    }

    private func matchingReconciliationFailure(
        desiredValue: Bool
    ) -> LaunchAtLoginReconciliationFailure? {
        guard let data = defaults.data(forKey: reconciliationFailureKey),
              let failure = try? JSONDecoder().decode(
                LaunchAtLoginReconciliationFailure.self,
                from: data
              ),
              failure.schemaVersion == LaunchAtLoginReconciliationFailure.currentSchemaVersion,
              failure.desiredLaunchAtLogin == desiredValue,
              failure.installationIdentity == currentInstallationIdentity,
              failure.systemStatusKey == systemStatusKey(loginItemManager.status) else {
            return nil
        }
        return failure
    }

    private func clearReconciliationFailure() {
        failedDesiredLaunchAtLogin = nil
        defaults.removeObject(forKey: reconciliationFailureKey)
    }

    private func shouldSuppressAutomaticRetry(for error: Error) -> Bool {
        isServiceManagementError(error, code: kSMErrorInvalidSignature)
            || isServiceManagementError(error, code: kSMErrorLaunchDeniedByUser)
            || isServiceManagementError(error, code: kSMErrorAlreadyRegistered)
    }

    private func systemStatusKey(_ status: SMAppService.Status) -> String {
        switch status {
        case .enabled:
            return "enabled"
        case .notRegistered:
            return "notRegistered"
        case .requiresApproval:
            return "requiresApproval"
        case .notFound:
            return "notFound"
        @unknown default:
            return "unknown:\(String(describing: status))"
        }
    }

    private func isServiceManagementError(_ error: Error, code: Int) -> Bool {
        let error = error as NSError
        if #available(macOS 15.0, *) {
            return error.domain == SMAppServiceErrorDomain && error.code == code
        }
        // The public domain constant is new in macOS 15 even though the errors
        // returned by SMAppService on macOS 14 already use the same domain name.
        return error.domain == "SMAppServiceErrorDomain" && error.code == code
    }

    private func shortErrorMessage(from error: Error) -> String {
        if isServiceManagementError(error, code: kSMErrorInvalidSignature) {
            return "当前 App 签名无效"
        }
        if isServiceManagementError(error, code: kSMErrorLaunchDeniedByUser) {
            return "需在系统设置中批准"
        }
        if isServiceManagementError(error, code: kSMErrorAlreadyRegistered) {
            return "系统仍保留其他 App 登录项"
        }
        if isServiceManagementError(error, code: kSMErrorServiceUnavailable) {
            return "登录项服务暂不可用"
        }

        let message = error.localizedDescription.lowercased()
        if message.contains("permission") || message.contains("not permitted") {
            return "登录会话不可用"
        }
        return "开机启动更新失败"
    }
}
