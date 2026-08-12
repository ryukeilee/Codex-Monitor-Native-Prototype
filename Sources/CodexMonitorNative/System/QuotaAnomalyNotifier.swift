import Foundation
@preconcurrency import UserNotifications

struct QuotaAnomalyNotificationPayload: Equatable {
    let identifier: String
    let title: String
    let body: String

    static func make(for anomaly: QuotaAnomaly) -> Self {
        let change = anomaly.change
        let direction = change < 0 ? "下降" : "上升"
        let timestamp = anomaly.current.recordedAt.timeIntervalSince1970
        return Self(
            identifier: "codex.monitor.quota-anomaly.\(timestamp)",
            title: "Codex 额度异常变化",
            body: "周额度从 \(anomaly.previous.remainingPercent)%\(direction)到 \(anomaly.current.remainingPercent)%（\(abs(change)) 个百分点），请确认账号活动。"
        )
    }
}

@MainActor
final class QuotaAnomalyNotifier: NSObject, UNUserNotificationCenterDelegate {
    private let notificationCenter: UNUserNotificationCenter

    init(notificationCenter: UNUserNotificationCenter = .current()) {
        self.notificationCenter = notificationCenter
        super.init()
        notificationCenter.delegate = self
    }

    func notify(_ anomaly: QuotaAnomaly) {
        let payload = QuotaAnomalyNotificationPayload.make(for: anomaly)
        Task {
            do {
                let authorized = try await notificationCenter.requestAuthorization(
                    options: [.alert, .sound]
                )
                guard authorized else {
                    AppLogger.system.info("Quota anomaly notification permission is unavailable")
                    return
                }

                let content = UNMutableNotificationContent()
                content.title = payload.title
                content.body = payload.body
                content.sound = .default
                let request = UNNotificationRequest(
                    identifier: payload.identifier,
                    content: content,
                    trigger: nil
                )
                try await notificationCenter.add(request)
                AppLogger.system.info("Scheduled quota anomaly notification")
            } catch {
                AppLogger.system.error("Failed to schedule quota anomaly notification: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
