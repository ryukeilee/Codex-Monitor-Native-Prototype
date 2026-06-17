import Foundation

struct SnapshotStore {
    private let defaults: UserDefaults
    private let key: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        defaults: UserDefaults = .standard,
        key: String = "codex.monitor.native.prototype.snapshot"
    ) {
        self.defaults = defaults
        self.key = key
    }

    func loadSnapshot() -> QuotaSnapshot? {
        guard let data = defaults.data(forKey: key) else {
            AppLogger.snapshot.info("No persisted snapshot found for key \(self.key, privacy: .public)")
            return nil
        }

        let snapshot = try? decoder.decode(QuotaSnapshot.self, from: data)
        if snapshot != nil {
            AppLogger.snapshot.info("Loaded persisted snapshot for key \(self.key, privacy: .public)")
        } else {
            AppLogger.snapshot.error("Failed to decode persisted snapshot for key \(self.key, privacy: .public)")
        }
        return snapshot
    }

    func saveSnapshot(_ snapshot: QuotaSnapshot) {
        guard let data = try? encoder.encode(snapshot) else {
            AppLogger.snapshot.error("Failed to encode snapshot for persistence")
            return
        }

        defaults.set(data, forKey: key)
        AppLogger.snapshot.info("Saved snapshot weekly=\(snapshot.weeklyQuotaPercent)% fiveHour=\(snapshot.fiveHourQuotaPercent)%")
    }
}
