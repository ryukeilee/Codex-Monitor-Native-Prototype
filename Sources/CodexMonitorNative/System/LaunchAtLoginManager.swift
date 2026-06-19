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

@MainActor
final class LaunchAtLoginManager: ObservableObject {
    enum StatusInfo: Equatable {
        case enabled
        case notRegistered
        case requiresApproval
        case notFound
        case unavailable(String)
        case unknown(String)

        var isEnabled: Bool {
            switch self {
            case .enabled, .requiresApproval:
                return true
            case .notRegistered, .notFound, .unavailable, .unknown:
                return false
            }
        }

        var message: String {
            switch self {
            case .enabled:
                return "Launch at login is enabled."
            case .notRegistered:
                return "Launch at login is disabled."
            case .requiresApproval:
                return "Launch at login needs approval in System Settings > Login Items."
            case .notFound:
                return "macOS could not find this app's login item registration."
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

    private let loginItemManager: LoginItemManaging

    init(
        loginItemManager: LoginItemManaging = SystemLoginItemManager()
    ) {
        self.loginItemManager = loginItemManager
        refreshStatus()
    }

    var shouldLaunchAtLogin: Bool {
        isEnabled
    }

    var helperText: String {
        statusInfo.message
    }

    func refreshStatus() {
        let status = serviceStatus()
        statusInfo = status
        isEnabled = status.isEnabled
        AppLogger.system.info("Launch at login status refreshed: \(String(describing: status), privacy: .public)")
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        AppLogger.system.info("Launch at login preference changed to \(enabled, privacy: .public)")
        lastErrorSummary = nil

        guard #available(macOS 13.0, *) else {
            statusInfo = .unavailable("Launch at login requires macOS 13 or later.")
            isEnabled = false
            lastErrorSummary = "Launch at login unavailable"
            AppLogger.system.error("Launch at login unavailable on this macOS version")
            return
        }

        isUpdating = true
        defer { isUpdating = false }

        do {
            if enabled {
                try loginItemManager.register()
                AppLogger.system.info("Requested launch at login registration for main app")
            } else {
                try loginItemManager.unregister()
                AppLogger.system.info("Requested launch at login unregistration for main app")
            }
            refreshStatus()
        } catch {
            lastErrorSummary = shortErrorMessage(from: error)
            AppLogger.system.error("Launch at login update failed: \(error.localizedDescription, privacy: .public)")
            refreshStatus()
        }
    }

    private func serviceStatus() -> StatusInfo {
        guard #available(macOS 13.0, *) else {
            return .unavailable("Launch at login requires macOS 13 or later.")
        }

        switch loginItemManager.status {
        case .enabled:
            return .enabled
        case .notRegistered:
            return .notRegistered
        case .requiresApproval:
            return .requiresApproval
        case .notFound:
            return .notFound
        @unknown default:
            return .unknown("Launch at login returned an unknown system status.")
        }
    }

    private func shortErrorMessage(from error: Error) -> String {
        let message = error.localizedDescription.lowercased()
        if message.contains("permission") || message.contains("not permitted") {
            return "Login session unavailable"
        }
        return "Launch at login update failed"
    }
}
