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
        let primaryData = defaults.data(forKey: key)
        let primaryWasWrittenByNewerVersion = primaryData.map(containsNewerPersistenceVersion) ?? false

        if let state = decodeState(from: primaryData) {
            return migratePersistedStateIfNeeded(state)
        }

        if let data = primaryData, let state = decodeLegacyState(from: data) {
            saveStateUnlocked(state)
            AppLogger.snapshot.info("Migrated legacy snapshot schemaV\(state.snapshot.schemaVersion) to unified persistence")
            return state
        }

        if let state = recoverStateFromBackup(preservingPrimary: primaryWasWrittenByNewerVersion) {
            return state
        }

        if primaryWasWrittenByNewerVersion {
            AppLogger.snapshot.error("Persisted app state uses a newer persistence version; preserving primary and starting not-connected")
            return nil
        }

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
        guard isSupported(state) else {
            AppLogger.snapshot.error("Refused to persist app state with an unsupported schema")
            return
        }
        guard currentData.map(containsNewerPersistenceVersion) != true else {
            AppLogger.snapshot.error("Refused to overwrite persisted app state written by a newer persistence version")
            return
        }
        let current = loadEnvelope(from: currentData)
        if let current, !isSupported(current.value) {
            AppLogger.snapshot.error("Refused to overwrite persisted app state with a newer schema")
            return
        }
        if let current, shouldReject(state: state, existing: current.value) {
            AppLogger.snapshot.info("Ignored persisted app state revision \(current.revision) because it is older or non-real")
            return
        }

        let currentRevision = current?.revision ?? 0
        let explicitlyInvalidatesRealSnapshot = current.map {
            isExplicitRealSnapshotInvalidation(state: state, existing: $0.value)
        } ?? false
        let crossesAccountBoundary = current.map {
            isRealSnapshotBoundaryReplacement(state: state, existing: $0.value)
        } ?? false
        guard currentRevision < UInt64.max else {
            AppLogger.snapshot.error("Cannot persist app state: revision reached UInt64.max")
            return
        }
        let nextRevision = currentRevision + 1
        do {
            let envelope = try PersistenceEnvelope(value: state, revision: nextRevision)
            let data = try encoder.encode(envelope)
            let trustedData = currentData.flatMap { isTrustedPersistenceData($0) ? $0 : nil }
                ?? defaults.data(forKey: backupKey).flatMap { isTrustedPersistenceData($0) ? $0 : nil }
            if explicitlyInvalidatesRealSnapshot || crossesAccountBoundary {
                defaults.removeObject(forKey: backupKey)
            } else if let currentData, isTrustedPersistenceData(currentData) {
                defaults.set(currentData, forKey: backupKey)
                guard defaults.data(forKey: backupKey) == currentData,
                      defaults.data(forKey: backupKey).map(isTrustedPersistenceData) == true else {
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
        guard isSupported(envelope.value) else { return nil }
        return envelope.value
    }

    private func loadEnvelope(from data: Data?) -> DecodedEnvelope<PersistedAppState>? {
        guard let data, let envelope = try? decoder.decode(PersistenceEnvelope.self, from: data),
              let value = try? envelope.decode(PersistedAppState.self) else {
            return nil
        }
        return DecodedEnvelope(value: value, revision: envelope.revision)
    }

    private func decodeLegacyState(from data: Data) -> PersistedAppState? {
        guard let legacy = decodeRawSnapshot(data),
              (1...QuotaSnapshot.currentSchemaVersion).contains(legacy.schemaVersion) else {
            return nil
        }
        let shouldMigrate = legacy.schemaVersion < QuotaSnapshot.currentSchemaVersion
            && (legacy.dataSource == .real || hasSchemaVersion(in: data))
        let snapshot = shouldMigrate ? migrate(legacy) : legacy
        return PersistedAppState(
            snapshot: snapshot,
            status: snapshot.dataSource == .real ? .success : .demoMode,
            lastSuccessAt: snapshot.dataSource == .real ? snapshot.refreshedAt : nil,
            lastAttemptAt: nil,
            failureCount: 0
        )
    }

    private func recoverStateFromBackup(preservingPrimary: Bool) -> PersistedAppState? {
        let backup = defaults.data(forKey: backupKey)
        if preservingPrimary {
            if let backup, let state = decodeState(from: backup) {
                AppLogger.snapshot.error("Persisted app state uses a newer version; using backup without replacing primary")
                return migratePersistedStateIfNeeded(state, persist: false)
            }
            if let backup, let state = decodeLegacyState(from: backup) {
                AppLogger.snapshot.error("Persisted app state uses a newer version; using legacy backup without replacing primary")
                return state
            }
            return nil
        }

        quarantinePrimary()

        if let backup, let state = decodeState(from: backup) {
            defaults.set(backup, forKey: key)
            AppLogger.snapshot.error("Recovered persisted app state from backup after primary corruption")
            return migratePersistedStateIfNeeded(state)
        }

        if let backup, let state = decodeLegacyState(from: backup) {
            saveStateUnlocked(state)
            AppLogger.snapshot.error("Recovered legacy snapshot from backup after primary corruption")
            return state
        }

        return nil
    }

    private func isSupported(_ state: PersistedAppState) -> Bool {
        (1...PersistedAppState.currentSchemaVersion).contains(state.schemaVersion)
            && (1...QuotaSnapshot.currentSchemaVersion).contains(state.snapshot.schemaVersion)
    }

    private func containsNewerPersistenceVersion(_ data: Data) -> Bool {
        if let envelope = try? decoder.decode(PersistenceEnvelope.self, from: data) {
            guard envelope.hasValidChecksum else { return false }
            if envelope.formatVersion > PersistenceEnvelope.currentFormatVersion {
                return true
            }
            if envelope.formatVersion == PersistenceEnvelope.currentFormatVersion,
               let state = try? envelope.decode(PersistedAppState.self),
               (state.schemaVersion > PersistedAppState.currentSchemaVersion
                || state.snapshot.schemaVersion > QuotaSnapshot.currentSchemaVersion) {
                return true
            }
        }
        return (decodeRawSnapshot(data)?.schemaVersion ?? 0) > QuotaSnapshot.currentSchemaVersion
    }

    private func isTrustedPersistenceData(_ data: Data) -> Bool {
        if let envelope = loadEnvelope(from: data) {
            return isSupported(envelope.value)
        }
        return decodeLegacyState(from: data) != nil
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
        guard isSupported(state) else {
            AppLogger.snapshot.error("Cannot migrate app state with an unsupported schema")
            return
        }
        guard currentData.map(containsNewerPersistenceVersion) != true else {
            AppLogger.snapshot.error("Cannot migrate over app state written by a newer persistence version")
            return
        }
        let currentRevision = loadEnvelope(from: currentData)?.revision ?? 0
        guard currentRevision < UInt64.max else {
            AppLogger.snapshot.error("Cannot migrate app state: revision reached UInt64.max")
            return
        }
        let nextRevision = currentRevision + 1
        do {
            let data = try encoder.encode(PersistenceEnvelope(value: state, revision: nextRevision))
            let trustedData = currentData.flatMap { isTrustedPersistenceData($0) ? $0 : nil }
                ?? defaults.data(forKey: backupKey).flatMap { isTrustedPersistenceData($0) ? $0 : nil }
            if let currentData, isTrustedPersistenceData(currentData) {
                defaults.set(currentData, forKey: backupKey)
                guard defaults.data(forKey: backupKey) == currentData,
                      defaults.data(forKey: backupKey).map(isTrustedPersistenceData) == true else {
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
        if existing.snapshot.dataSource == .real, state.snapshot.dataSource != .real {
            return !isExplicitRealSnapshotInvalidation(state: state, existing: existing)
        }
        guard existing.snapshot.dataSource == .real, state.snapshot.dataSource == .real else { return false }
        if let existingBoundary = existing.snapshot.accountBoundary,
           let newBoundary = state.snapshot.accountBoundary,
           !newBoundary.matches(existingBoundary) {
            return false
        }
        return state.snapshot.refreshedAt < existing.snapshot.refreshedAt
    }

    private func isExplicitRealSnapshotInvalidation(
        state: PersistedAppState,
        existing: PersistedAppState
    ) -> Bool {
        existing.snapshot.dataSource == .real
            && state.snapshot.dataSource != .real
            && state.status != .demoMode
    }

    private func isRealSnapshotBoundaryReplacement(
        state: PersistedAppState,
        existing: PersistedAppState
    ) -> Bool {
        guard existing.snapshot.dataSource == .real,
              state.snapshot.dataSource == .real,
              let existingBoundary = existing.snapshot.accountBoundary,
              let newBoundary = state.snapshot.accountBoundary else {
            return false
        }
        return !newBoundary.matches(existingBoundary)
    }

    private func migratePersistedStateIfNeeded(
        _ state: PersistedAppState,
        persist: Bool = true
    ) -> PersistedAppState {
        guard state.schemaVersion < PersistedAppState.currentSchemaVersion
                || state.snapshot.schemaVersion < QuotaSnapshot.currentSchemaVersion else {
            return state
        }
        let snapshot = state.snapshot.schemaVersion < QuotaSnapshot.currentSchemaVersion
            ? migrate(state.snapshot)
            : state.snapshot
        let migrated = PersistedAppState(
            snapshot: snapshot,
            status: state.status,
            lastSuccessAt: state.lastSuccessAt,
            lastAttemptAt: state.lastAttemptAt,
            failureCount: state.failureCount,
            savedAt: state.savedAt,
            schemaVersion: PersistedAppState.currentSchemaVersion
        )
        if persist {
            saveStateUnlocked(migrated)
            AppLogger.snapshot.info("Migrated envelope snapshot schemaV\(state.snapshot.schemaVersion) to schemaV\(snapshot.schemaVersion)")
        }
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
            schemaVersion: QuotaSnapshot.currentSchemaVersion,
            quotaWindows: snapshot.quotaWindows,
            accountBoundary: snapshot.accountBoundary
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
                    resetTimeStatus: snapshot.fiveHourResetAt == nil ? .unexposed : .actual
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
                    resetTimeStatus: .unexposed
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
