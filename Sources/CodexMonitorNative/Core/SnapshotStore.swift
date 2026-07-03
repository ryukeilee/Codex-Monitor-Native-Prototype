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

        do {
            let snapshot = try decoder.decode(QuotaSnapshot.self, from: data)
            AppLogger.snapshot.info("Loaded persisted snapshot schemaV\(snapshot.schemaVersion) source=\(snapshot.dataSource.rawValue, privacy: .public)")

            if snapshot.schemaVersion < QuotaSnapshot.currentSchemaVersion {
                let migrated = migrate(snapshot)
                AppLogger.snapshot.info("Migrated snapshot from schemaV\(snapshot.schemaVersion) to schemaV\(migrated.schemaVersion)")
                return migrated
            }

            return snapshot
        } catch {
            AppLogger.snapshot.error("Failed to decode persisted snapshot: \(error.localizedDescription, privacy: .public)")
            return loadLegacySnapshot(from: data)
        }
    }

    func saveSnapshot(_ snapshot: QuotaSnapshot) {
        guard let data = try? encoder.encode(snapshot) else {
            AppLogger.snapshot.error("Failed to encode snapshot for persistence")
            return
        }

        defaults.set(data, forKey: key)
        AppLogger.snapshot.info("Saved snapshot schemaV\(snapshot.schemaVersion) source=\(snapshot.dataSource.rawValue, privacy: .public) weekly=\(snapshot.weeklyQuotaPercent)% fiveHour=\(snapshot.fiveHourQuotaPercent)%")
    }

    // MARK: - Legacy Support

    private func loadLegacySnapshot(from data: Data) -> QuotaSnapshot? {
        struct LegacySnapshot: Decodable {
            let weeklyQuotaPercent: Int
            let fiveHourQuotaPercent: Int
            let refreshedAt: Date
        }

        guard let legacy = try? decoder.decode(LegacySnapshot.self, from: data) else {
            return nil
        }

        AppLogger.snapshot.info("Loaded legacy snapshot (schemaV1), treating as mock data source")

        return QuotaSnapshot(
            weeklyQuotaPercent: legacy.weeklyQuotaPercent,
            fiveHourQuotaPercent: legacy.fiveHourQuotaPercent,
            resetAvailableCount: nil,
            resetCreditDetailsState: .appServerCountOnly,
            resetCreditDiagnostic: nil,
            resetCreditDetails: [],
            resetCreditStatusSummary: [],
            resetCreditTimeEntries: [],
            resetCreditRawFields: [],
            fiveHourResetAt: nil,
            resetBanks: [],
            refreshedAt: legacy.refreshedAt,
            dataSource: .mock,
            errorMessage: nil,
            schemaVersion: 1
        )
    }

    private func migrate(_ snapshot: QuotaSnapshot) -> QuotaSnapshot {
        QuotaSnapshot(
            weeklyQuotaPercent: snapshot.weeklyQuotaPercent,
            fiveHourQuotaPercent: snapshot.fiveHourQuotaPercent,
            resetAvailableCount: snapshot.resetAvailableCount,
            resetCreditDetailsState: snapshot.resetCreditDetailsState,
            resetCreditDiagnostic: snapshot.resetCreditDiagnostic,
            resetCreditDetails: snapshot.resetCreditDetails,
            resetCreditStatusSummary: snapshot.resetCreditStatusSummary,
            resetCreditTimeEntries: snapshot.resetCreditTimeEntries,
            resetCreditRawFields: snapshot.resetCreditRawFields,
            fiveHourResetAt: snapshot.fiveHourResetAt,
            resetBanks: migratedResetBanks(from: snapshot),
            refreshedAt: snapshot.refreshedAt,
            dataSource: snapshot.dataSource,
            errorMessage: snapshot.errorMessage,
            schemaVersion: QuotaSnapshot.currentSchemaVersion
        )
    }

    private func migratedResetBanks(from snapshot: QuotaSnapshot) -> [ResetBankSnapshot] {
        if !snapshot.resetBanks.isEmpty {
            return Array(snapshot.resetBanks.sorted(by: compareResetBanks).prefix(3))
        }

        guard snapshot.dataSource == .real else {
            return []
        }

        return [
            ResetBankSnapshot(
                limitId: "codex",
                windowId: "primary",
                displayName: "5小时额度",
                remainingPercent: snapshot.fiveHourQuotaPercent,
                resetAt: snapshot.fiveHourResetAt,
                resetTimeStatus: snapshot.fiveHourResetAt == nil ? .unexposed : .actual,
                rawResetFields: []
            ),
            ResetBankSnapshot(
                limitId: "codex",
                windowId: "secondary",
                displayName: "周额度",
                remainingPercent: snapshot.weeklyQuotaPercent,
                resetAt: nil,
                resetTimeStatus: .unexposed,
                rawResetFields: []
            )
        ]
        .sorted(by: compareResetBanks)
    }

    private func compareResetBanks(_ lhs: ResetBankSnapshot, _ rhs: ResetBankSnapshot) -> Bool {
        switch (lhs.resetAt, rhs.resetAt) {
        case let (left?, right?):
            if left != right {
                return left < right
            }
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case (nil, nil):
            break
        }

        if lhs.displayName != rhs.displayName {
            return lhs.displayName < rhs.displayName
        }

        return lhs.id < rhs.id
    }
}
