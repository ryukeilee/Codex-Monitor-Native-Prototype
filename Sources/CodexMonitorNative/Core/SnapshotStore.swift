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

    // MARK: - Test instrumentation

#if DEBUG
    /// Counts every JSON decode this store performs against persisted state so
    /// redundancy tests can assert that one commit validates its primary data
    /// once instead of inferring it from timing. Compiled out of release builds.
    private static let decodeCountLock = NSLock()
    nonisolated(unsafe) private static var decodeCount = 0

    static var debugPersistenceDecodeCount: Int {
        decodeCountLock.lock()
        defer { decodeCountLock.unlock() }
        return decodeCount
    }

    private static func recordPersistenceDecode() {
        decodeCountLock.lock()
        defer { decodeCountLock.unlock() }
        decodeCount += 1
    }
#else
    private static func recordPersistenceDecode() {}
#endif

    func loadSnapshot() -> QuotaSnapshot? {
        loadState()?.snapshot
    }

    func loadState() -> PersistedAppState? {
        lock.lock()
        defer { lock.unlock() }
        let primary = auditPersistenceData(defaults.data(forKey: key))
        if let envelope = primary.envelope, isSupported(envelope.value) {
            return migratePersistedStateIfNeeded(envelope.value)
        }

        if let state = primary.legacyState {
            saveStateUnlocked(state)
            AppLogger.snapshot.info("Migrated legacy snapshot schemaV\(state.snapshot.schemaVersion) to unified persistence")
            return state
        }

        if let state = recoverStateFromBackup(preservingPrimary: primary.isNewerPersistenceVersion) {
            return state
        }

        if primary.isNewerPersistenceVersion {
            AppLogger.snapshot.error("Persisted app state uses a newer persistence version; preserving primary and starting not-connected")
            return nil
        }

        AppLogger.snapshot.error("No trusted persisted app state remained; starting not-connected")
        return nil
    }

    @discardableResult
    func saveSnapshot(_ snapshot: QuotaSnapshot) -> Bool {
        let status: QuotaRefreshStatus = snapshot.dataSource == .real ? .success : .demoMode
        return saveState(PersistedAppState(
            snapshot: snapshot,
            status: status,
            lastSuccessAt: snapshot.dataSource == .real ? snapshot.refreshedAt : nil,
            lastAttemptAt: nil,
            failureCount: 0
        ))
    }

    @discardableResult
    func saveState(
        _ state: PersistedAppState,
        allowOlderRealSnapshot: Bool = false
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        let currentData = defaults.data(forKey: key)
        guard isSupported(state) else {
            AppLogger.snapshot.error("Refused to persist app state with an unsupported schema")
            return false
        }
        let current = auditPersistenceData(currentData)
        guard !current.isNewerPersistenceVersion else {
            AppLogger.snapshot.error("Refused to overwrite persisted app state written by a newer persistence version")
            return false
        }
        if let envelope = current.envelope, !isSupported(envelope.value) {
            AppLogger.snapshot.error("Refused to overwrite persisted app state with a newer schema")
            return false
        }
        if let envelope = current.envelope, shouldReject(
            state: state,
            existing: envelope.value,
            allowOlderRealSnapshot: allowOlderRealSnapshot
        ) {
            AppLogger.snapshot.info("Ignored persisted app state revision \(envelope.revision) because it is older or non-real")
            return false
        }

        let currentRevision = current.envelope?.revision ?? 0
        let explicitlyInvalidatesRealSnapshot = current.envelope.map {
            isExplicitRealSnapshotInvalidation(state: state, existing: $0.value)
        } ?? false
        let crossesAccountBoundary = current.envelope.map {
            isRealSnapshotBoundaryReplacement(state: state, existing: $0.value)
        } ?? false
        guard currentRevision < UInt64.max else {
            AppLogger.snapshot.error("Cannot persist app state: revision reached UInt64.max")
            return false
        }
        let nextRevision = currentRevision + 1
        do {
            let nextEnvelope = try PersistenceEnvelope(value: state, revision: nextRevision)
            let data = try encoder.encode(nextEnvelope)
            let trustedData = (current.isTrusted ? currentData : nil) ?? trustedBackupData()
            if explicitlyInvalidatesRealSnapshot || crossesAccountBoundary {
                defaults.removeObject(forKey: backupKey)
            } else if let currentData, current.isTrusted {
                defaults.set(currentData, forKey: backupKey)
                // Exact readback equality preserves the validation of currentData.
                guard defaults.data(forKey: backupKey) == currentData else {
                    AppLogger.snapshot.error("Backup verification failed; primary app state was not replaced")
                    return false
                }
            }
            defaults.set(data, forKey: key)
            // `data` is the buffer this call just encoded from `nextEnvelope`, so
            // byte equality already proves every fact `loadEnvelope` used to
            // re-derive: the format version is current, the checksum matches the
            // payload, the payload decodes, and the revision is `nextRevision`.
            // Re-decoding the same buffer cannot add evidence — byte equality is
            // strictly stronger than "decodes to this revision" — so the readback
            // check stays exactly as strong while doing no JSON work.
            guard let readback = defaults.data(forKey: key), readback == data else {
                AppLogger.snapshot.error("App state write verification failed at revision \(nextRevision); restoring trusted backup")
                if let trustedData { defaults.set(trustedData, forKey: key) } else { defaults.removeObject(forKey: key) }
                return false
            }
            AppLogger.snapshot.info("Saved app state schemaV\(state.schemaVersion) status=\(state.status.rawValue, privacy: .public) revision=\(nextRevision)")
            return true
        } catch {
            AppLogger.snapshot.error("Failed to persist app state: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    // MARK: - Envelope and migration

    private struct DecodedEnvelope<T> {
        let value: T
        let revision: UInt64
    }

    /// One decode/validation pass over a single persisted-state datum.
    ///
    /// `saveState`, `saveStateUnlocked`, `loadState`, and backup recovery all
    /// need the same facts about the primary or backup bytes: whether a newer
    /// persistence version wrote them, whether their schema is supported, their
    /// revision, and their decode-backed trustworthiness. Classifying the datum
    /// once keeps those answers consistent and removes the repeated envelope,
    /// payload, and raw-snapshot parses those call sites used to run
    /// independently.
    private struct PersistenceDataAudit {
        /// Present when the datum is a current-format envelope whose checksum
        /// and payload both decode. The payload is retained even when its schema
        /// is out of range so callers can report that instead of trusting it.
        let envelope: DecodedEnvelope<PersistedAppState>?
        /// The unwrapped legacy state, decoded only when the envelope path
        /// cannot describe the datum.
        let legacyState: PersistedAppState?
        let isNewerPersistenceVersion: Bool
        let isTrusted: Bool
    }

    private func auditPersistenceData(_ data: Data?) -> PersistenceDataAudit {
        guard let data else {
            return PersistenceDataAudit(
                envelope: nil,
                legacyState: nil,
                isNewerPersistenceVersion: false,
                isTrusted: false
            )
        }

        var envelope: DecodedEnvelope<PersistedAppState>?
        var isNewerPersistenceVersion = false
        // A structurally valid envelope with a broken checksum was never probed
        // for a newer raw snapshot; keep that behavior while sharing the probe
        // with the structural-failure path. The probe itself must stay
        // unconditional otherwise: JSON decodes `"weeklyQuota\u0050ercent"` to
        // the legacy key, so only a real decode can rule a raw snapshot out.
        var shouldProbeRawSnapshot = true

        if let rawEnvelope = decodeEnvelope(from: data) {
            if !rawEnvelope.hasValidChecksum {
                shouldProbeRawSnapshot = false
            } else if rawEnvelope.formatVersion > PersistenceEnvelope.currentFormatVersion {
                isNewerPersistenceVersion = true
                shouldProbeRawSnapshot = false
            } else if rawEnvelope.formatVersion == PersistenceEnvelope.currentFormatVersion,
                      let value = decodePayload(from: rawEnvelope) {
                if value.schemaVersion > PersistedAppState.currentSchemaVersion
                    || value.snapshot.schemaVersion > QuotaSnapshot.currentSchemaVersion {
                    isNewerPersistenceVersion = true
                } else {
                    envelope = DecodedEnvelope(value: value, revision: rawEnvelope.revision)
                }
            }
        }

        if !isNewerPersistenceVersion, shouldProbeRawSnapshot,
           rawSnapshotSchemaVersion(data) > QuotaSnapshot.currentSchemaVersion {
            isNewerPersistenceVersion = true
        }

        let envelopeIsSupported = envelope.map { isSupported($0.value) } ?? false
        // An unsupported envelope still falls back to the legacy shape: the old
        // `decodeState` reported it as "no state" and let `loadState` try
        // `decodeLegacyState`, which made a hand-written hybrid recoverable.
        let legacyState = envelopeIsSupported ? nil : decodeLegacyState(from: data)
        return PersistenceDataAudit(
            envelope: envelope,
            legacyState: legacyState,
            isNewerPersistenceVersion: isNewerPersistenceVersion,
            isTrusted: envelopeIsSupported || (envelope == nil && legacyState != nil)
        )
    }

    private func decodeEnvelope(from data: Data) -> PersistenceEnvelope? {
        Self.recordPersistenceDecode()
        return try? decoder.decode(PersistenceEnvelope.self, from: data)
    }

    private func decodePayload(from envelope: PersistenceEnvelope) -> PersistedAppState? {
        Self.recordPersistenceDecode()
        return try? decoder.decode(PersistedAppState.self, from: envelope.payload)
    }

    private func loadEnvelope(from data: Data?) -> DecodedEnvelope<PersistedAppState>? {
        guard let data, let envelope = decodeEnvelope(from: data),
              envelope.hasValidChecksum,
              envelope.formatVersion == PersistenceEnvelope.currentFormatVersion,
              let value = decodePayload(from: envelope) else {
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
        let backupAudit = auditPersistenceData(backup)

        if preservingPrimary {
            if let envelope = backupAudit.envelope, isSupported(envelope.value) {
                AppLogger.snapshot.error("Persisted app state uses a newer version; using backup without replacing primary")
                return migratePersistedStateIfNeeded(envelope.value, persist: false)
            }
            if let state = backupAudit.legacyState {
                AppLogger.snapshot.error("Persisted app state uses a newer version; using legacy backup without replacing primary")
                return state
            }
            return nil
        }

        quarantinePrimary()

        guard let backup else { return nil }

        if let envelope = backupAudit.envelope, isSupported(envelope.value) {
            defaults.set(backup, forKey: key)
            AppLogger.snapshot.error("Recovered persisted app state from backup after primary corruption")
            return migratePersistedStateIfNeeded(envelope.value)
        }

        if let state = backupAudit.legacyState {
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

    private func isTrustedPersistenceData(_ data: Data) -> Bool {
        if let envelope = loadEnvelope(from: data) {
            return isSupported(envelope.value)
        }
        return decodeLegacyState(from: data) != nil
    }

    private func trustedBackupData() -> Data? {
        guard let data = defaults.data(forKey: backupKey), isTrustedPersistenceData(data) else {
            return nil
        }
        return data
    }

    /// The newer-schema probe only needs a "newer than current" verdict, and
    /// `decodeRawSnapshot`'s built-in `LegacySnapshot` fallback hard-codes
    /// `schemaVersion: 1`, which can never exceed `QuotaSnapshot.currentSchemaVersion`
    /// (8 today, and never below 1). The two probes can therefore only disagree
    /// when modern decoding fails and the legacy fallback succeeds: the old probe
    /// then read 1 and this one reads 0, and both are `<= currentSchemaVersion`,
    /// so `isNewerPersistenceVersion` is identical either way. Probing only the
    /// modern shape drops a guaranteed-useless second parse of the same bytes.
    /// `decodeRawSnapshot` keeps its legacy fallback for the real recovery path
    /// in `decodeLegacyState`.
    private func rawSnapshotSchemaVersion(_ data: Data) -> Int {
        Self.recordPersistenceDecode()
        return (try? decoder.decode(QuotaSnapshot.self, from: data))?.schemaVersion ?? 0
    }

    private func decodeRawSnapshot(_ data: Data) -> QuotaSnapshot? {
        Self.recordPersistenceDecode()
        if let snapshot = try? decoder.decode(QuotaSnapshot.self, from: data) {
            return snapshot
        }

        struct LegacySnapshot: Decodable {
            let weeklyQuotaPercent: Int
            let fiveHourQuotaPercent: Int
            let refreshedAt: Date
        }
        Self.recordPersistenceDecode()
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
        Self.recordPersistenceDecode()
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return object["schemaVersion"] != nil
    }

    private func saveStateUnlocked(_ state: PersistedAppState) {
        let currentData = defaults.data(forKey: key)
        guard isSupported(state) else {
            AppLogger.snapshot.error("Cannot migrate app state with an unsupported schema")
            return
        }
        let current = auditPersistenceData(currentData)
        guard !current.isNewerPersistenceVersion else {
            AppLogger.snapshot.error("Cannot migrate over app state written by a newer persistence version")
            return
        }
        let currentRevision = current.envelope?.revision ?? 0
        guard currentRevision < UInt64.max else {
            AppLogger.snapshot.error("Cannot migrate app state: revision reached UInt64.max")
            return
        }
        let nextRevision = currentRevision + 1
        do {
            let data = try encoder.encode(PersistenceEnvelope(value: state, revision: nextRevision))
            let trustedData = (current.isTrusted ? currentData : nil) ?? trustedBackupData()
            if let currentData, current.isTrusted {
                defaults.set(currentData, forKey: backupKey)
                // Exact readback equality preserves the validation of currentData.
                guard defaults.data(forKey: backupKey) == currentData else {
                    AppLogger.snapshot.error("Backup verification failed; migrated primary app state was not replaced")
                    return
                }
            }
            defaults.set(data, forKey: key)
            // Same reasoning as `saveState`: the readback bytes are compared with
            // the exact buffer just encoded, which subsumes the envelope, checksum,
            // payload, and revision facts `loadEnvelope` would decode again.
            guard let readback = defaults.data(forKey: key), readback == data else {
                AppLogger.snapshot.error("App state migration write verification failed at revision \(nextRevision); restoring trusted backup")
                if let trustedData { defaults.set(trustedData, forKey: key) } else { defaults.removeObject(forKey: key) }
                return
            }
        } catch {
            AppLogger.snapshot.error("Failed to migrate persisted snapshot: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func shouldReject(
        state: PersistedAppState,
        existing: PersistedAppState,
        allowOlderRealSnapshot: Bool = false
    ) -> Bool {
        if existing.snapshot.dataSource == .real, state.snapshot.dataSource != .real {
            return !isExplicitRealSnapshotInvalidation(state: state, existing: existing)
        }
        guard existing.snapshot.dataSource == .real, state.snapshot.dataSource == .real else { return false }
        if let existingBoundary = existing.snapshot.accountBoundary,
           let newBoundary = state.snapshot.accountBoundary,
           !newBoundary.matches(existingBoundary) {
            return false
        }
        return !allowOlderRealSnapshot
            && state.snapshot.refreshedAt < existing.snapshot.refreshedAt
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
