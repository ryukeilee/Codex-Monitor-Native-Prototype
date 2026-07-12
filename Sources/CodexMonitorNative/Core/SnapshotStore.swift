import Foundation

struct SnapshotStore {
    private static let lockRegistry = SnapshotStoreLockRegistry()
    private let defaults: UserDefaults
    private let key: String
    private let lock: NSLock
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        defaults: UserDefaults = .standard,
        key: String = "codex.monitor.native.prototype.snapshot",
        lock: NSLock? = nil
    ) {
        self.defaults = defaults
        self.key = key
        self.lock = lock ?? Self.sharedLock(for: defaults, key: key)
    }

    private static func sharedLock(for defaults: UserDefaults, key: String) -> NSLock {
        // UserDefaults instances for the same suite are distinct objects; keying
        // by persistence key still serializes cross-instance writers safely.
        let registryKey = key
        lockRegistry.lock.lock()
        defer { lockRegistry.lock.unlock() }
        if let existing = lockRegistry.values[registryKey] { return existing }
        let created = NSLock()
        lockRegistry.values[registryKey] = created
        return created
    }

    func loadSnapshot() -> QuotaSnapshot? {
        loadState()?.snapshot
    }

    func loadState() -> PersistedAppState? {
        lock.lock()
        defer { lock.unlock() }

        if let state = decodeState(from: defaults.data(forKey: key)) {
            return migratePersistedStateIfNeeded(state)
        }

        if let data = defaults.data(forKey: key), let legacy = decodeRawSnapshot(data) {
            let migrated = hasSchemaVersion(in: data) && legacy.schemaVersion < QuotaSnapshot.currentSchemaVersion ? migrate(legacy) : legacy
            let state = PersistedAppState(
                snapshot: migrated,
                status: migrated.dataSource == .real ? .success : .demoMode,
                lastSuccessAt: migrated.dataSource == .real ? migrated.refreshedAt : nil,
                lastAttemptAt: nil,
                failureCount: 0
            )
            saveStateUnlocked(state)
            AppLogger.snapshot.info("Migrated legacy snapshot schemaV\(legacy.schemaVersion) to unified persistence")
            return state
        }

        if let backup = defaults.data(forKey: backupKey), let state = decodeState(from: backup) {
            quarantinePrimary()
            defaults.set(backup, forKey: key)
            AppLogger.snapshot.error("Recovered persisted app state from backup after primary corruption")
            return migratePersistedStateIfNeeded(state)
        }

        quarantinePrimary()
        AppLogger.snapshot.error("No trusted persisted app state remained; starting not-connected")
        return nil
    }

    func saveSnapshot(_ snapshot: QuotaSnapshot) {
        let status: QuotaRefreshStatus = snapshot.dataSource == .real ? .success : .demoMode
        saveState(PersistedAppState(
            snapshot: snapshot,
            status: status,
            lastSuccessAt: snapshot.dataSource == .real ? snapshot.refreshedAt : nil,
            lastAttemptAt: nil,
            failureCount: 0
        ))
    }

    func saveState(_ state: PersistedAppState) {
        lock.lock()
        defer { lock.unlock() }

        let currentData = defaults.data(forKey: key)
        let current = loadEnvelope(from: currentData)
        if let current, shouldReject(state: state, existing: current.value) {
            AppLogger.snapshot.info("Ignored persisted app state revision \(current.revision) because it is older or non-real")
            return
        }

        let currentRevision = current?.revision ?? 0
        guard currentRevision < UInt64.max else {
            AppLogger.snapshot.error("Cannot persist app state: revision reached UInt64.max")
            return
        }
        let nextRevision = currentRevision + 1
        do {
            let envelope = try PersistenceEnvelope(value: state, revision: nextRevision)
            let data = try encoder.encode(envelope)
            let trustedData = currentData.flatMap { loadEnvelope(from: $0) != nil ? $0 : defaults.data(forKey: backupKey) }
            if let currentData = currentData, loadEnvelope(from: currentData) != nil {
                defaults.set(currentData, forKey: backupKey)
                guard defaults.data(forKey: backupKey) == currentData,
                      defaults.data(forKey: backupKey).flatMap({ loadEnvelope(from: $0) }) != nil else {
                    AppLogger.snapshot.error("Backup verification failed; primary app state was not replaced")
                    return
                }
            }
            defaults.set(data, forKey: key)
            guard let readback = defaults.data(forKey: key), readback == data, loadEnvelope(from: readback)?.revision == nextRevision else {
                AppLogger.snapshot.error("App state write verification failed at revision \(nextRevision); restoring trusted backup")
                if let trustedData { defaults.set(trustedData, forKey: key) } else { defaults.removeObject(forKey: key) }
                return
            }
            AppLogger.snapshot.info("Saved app state schemaV\(state.schemaVersion) status=\(state.status.rawValue, privacy: .public) revision=\(nextRevision)")
        } catch {
            AppLogger.snapshot.error("Failed to persist app state: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Envelope and migration

    private struct DecodedEnvelope<T> {
        let value: T
        let revision: UInt64
    }

    private func decodeState(from data: Data?) -> PersistedAppState? {
        guard let data else { return nil }
        guard let envelope = loadEnvelope(from: data) else { return nil }
        return envelope.value
    }

    private func loadEnvelope(from data: Data?) -> DecodedEnvelope<PersistedAppState>? {
        guard let data, let envelope = try? decoder.decode(PersistenceEnvelope.self, from: data),
              let value = try? envelope.decode(PersistedAppState.self) else {
            return nil
        }
        return DecodedEnvelope(value: value, revision: envelope.revision)
    }

    private func decodeRawSnapshot(_ data: Data) -> QuotaSnapshot? {
        if let snapshot = try? decoder.decode(QuotaSnapshot.self, from: data) {
            return snapshot
        }

        struct LegacySnapshot: Decodable {
            let weeklyQuotaPercent: Int
            let fiveHourQuotaPercent: Int
            let refreshedAt: Date
        }
        guard let legacy = try? decoder.decode(LegacySnapshot.self, from: data) else { return nil }
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

    private func hasSchemaVersion(in data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return object["schemaVersion"] != nil
    }

    private func saveStateUnlocked(_ state: PersistedAppState) {
        let currentData = defaults.data(forKey: key)
        let currentRevision = loadEnvelope(from: currentData)?.revision ?? 0
        guard currentRevision < UInt64.max else {
            AppLogger.snapshot.error("Cannot migrate app state: revision reached UInt64.max")
            return
        }
        let nextRevision = currentRevision + 1
        do {
            let data = try encoder.encode(PersistenceEnvelope(value: state, revision: nextRevision))
            let trustedData = currentData.flatMap { loadEnvelope(from: $0) != nil ? $0 : defaults.data(forKey: backupKey) }
            if let currentData = currentData, loadEnvelope(from: currentData) != nil {
                defaults.set(currentData, forKey: backupKey)
                guard defaults.data(forKey: backupKey) == currentData,
                      defaults.data(forKey: backupKey).flatMap({ loadEnvelope(from: $0) }) != nil else {
                    AppLogger.snapshot.error("Backup verification failed; migrated primary app state was not replaced")
                    return
                }
            }
            defaults.set(data, forKey: key)
            guard let readback = defaults.data(forKey: key), readback == data, loadEnvelope(from: readback)?.revision == nextRevision else {
                AppLogger.snapshot.error("App state migration write verification failed at revision \(nextRevision); restoring trusted backup")
                if let trustedData { defaults.set(trustedData, forKey: key) } else { defaults.removeObject(forKey: key) }
                return
            }
        } catch {
            AppLogger.snapshot.error("Failed to migrate persisted snapshot: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func shouldReject(state: PersistedAppState, existing: PersistedAppState) -> Bool {
        if existing.snapshot.dataSource == .real, state.snapshot.dataSource != .real { return true }
        guard existing.snapshot.dataSource == .real, state.snapshot.dataSource == .real else { return false }
        return state.snapshot.refreshedAt < existing.snapshot.refreshedAt
    }

    private func migratePersistedStateIfNeeded(_ state: PersistedAppState) -> PersistedAppState {
        guard state.snapshot.schemaVersion < QuotaSnapshot.currentSchemaVersion else { return state }
        let snapshot = migrate(state.snapshot)
        let migrated = PersistedAppState(
            snapshot: snapshot,
            status: state.status,
            lastSuccessAt: state.lastSuccessAt,
            lastAttemptAt: state.lastAttemptAt,
            failureCount: state.failureCount,
            savedAt: state.savedAt,
            schemaVersion: PersistedAppState.currentSchemaVersion
        )
        saveStateUnlocked(migrated)
        AppLogger.snapshot.info("Migrated envelope snapshot schemaV\(state.snapshot.schemaVersion) to schemaV\(snapshot.schemaVersion)")
        return migrated
    }

    private func quarantinePrimary() {
        guard let data = defaults.data(forKey: key) else { return }
        defaults.set(data, forKey: corruptKey)
        defaults.removeObject(forKey: key)
    }

    private var backupKey: String { "\(key).backup" }
    private var corruptKey: String { "\(key).corrupt" }

    // MARK: - Legacy migration

    private func migrate(_ snapshot: QuotaSnapshot) -> QuotaSnapshot {
        QuotaSnapshot(
            weeklyQuotaPercent: snapshot.weeklyQuotaPercent,
            fiveHourQuotaPercent: snapshot.fiveHourQuotaPercent,
            weeklyQuotaState: snapshot.weeklyQuotaState,
            fiveHourQuotaState: snapshot.fiveHourQuotaState,
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
        if !snapshot.resetBanks.isEmpty { return Array(snapshot.resetBanks.sorted(by: compareResetBanks).prefix(3)) }
        guard snapshot.dataSource == .real else { return [] }
        var banks: [ResetBankSnapshot] = []
        if snapshot.fiveHourQuotaState.isDisplayable {
            banks.append(
                ResetBankSnapshot(
                    limitId: "codex",
                    windowId: "primary",
                    displayName: "5小时额度",
                    remainingPercent: snapshot.fiveHourQuotaPercent,
                    resetAt: snapshot.fiveHourResetAt,
                    resetTimeStatus: snapshot.fiveHourResetAt == nil ? .unexposed : .actual,
                    rawResetFields: []
                )
            )
        }
        if snapshot.weeklyQuotaState.isDisplayable {
            banks.append(
                ResetBankSnapshot(
                    limitId: "codex",
                    windowId: "secondary",
                    displayName: "周额度",
                    remainingPercent: snapshot.weeklyQuotaPercent,
                    resetAt: nil,
                    resetTimeStatus: .unexposed,
                    rawResetFields: []
                )
            )
        }
        return banks.sorted(by: compareResetBanks)
    }

    private func compareResetBanks(_ lhs: ResetBankSnapshot, _ rhs: ResetBankSnapshot) -> Bool {
        switch (lhs.resetAt, rhs.resetAt) {
        case let (left?, right?): if left != right { return left < right }
        case (_?, nil): return true
        case (nil, _?): return false
        case (nil, nil): break
        }
        if lhs.displayName != rhs.displayName { return lhs.displayName < rhs.displayName }
        return lhs.id < rhs.id
    }
}

private final class SnapshotStoreLockRegistry: @unchecked Sendable {
    let lock = NSLock()
    var values: [String: NSLock] = [:]
}
