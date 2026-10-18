import Foundation
import CryptoKit
import Darwin
import OSLog

// Darwin's `flock` function collides with its imported `flock` structure in
// Swift, so bind the C symbol under an unambiguous name.
@_silgen_name("flock")
func codexMonitorFlock(_ fileDescriptor: CInt, _ operation: CInt) -> CInt

private enum PersistenceLog {
    static let logger = Logger(subsystem: "com.ryukeilee.CodexMonitorNativePrototype", category: "Persistence")
}

/// Shared versioned/checksummed envelope for app and widget persistence.
struct PersistenceEnvelope: Codable {
    static let currentFormatVersion = 1

    let formatVersion: Int
    let revision: UInt64
    let payload: Data
    let checksum: String
    let writtenAt: Date

    init<T: Encodable>(value: T, revision: UInt64, encoder: JSONEncoder = PersistenceEnvelope.encoder) throws {
        try self.init(payload: encoder.encode(value), revision: revision)
    }

    /// Builds the envelope around an already-encoded payload. A writer that also
    /// needs the raw payload bytes (the widget store mirrors them at the top
    /// level for pre-envelope readers) can reuse them instead of encoding the
    /// same value twice.
    init(payload: Data, revision: UInt64) {
        self.formatVersion = Self.currentFormatVersion
        self.revision = revision
        self.payload = payload
        self.checksum = Self.checksum(payload)
        self.writtenAt = .now
    }

    func decode<T: Decodable>(_ type: T.Type, decoder: JSONDecoder = PersistenceEnvelope.decoder) throws -> T {
        guard hasValidChecksum else { throw PersistenceError.checksumMismatch }
        guard formatVersion == Self.currentFormatVersion else { throw PersistenceError.unsupportedFormat(formatVersion) }
        return try decoder.decode(type, from: payload)
    }

    var hasValidChecksum: Bool {
        Self.checksum(payload) == checksum
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
    private static let decoder = JSONDecoder()

    private static func checksum(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

enum PersistenceError: Error, Equatable {
    case checksumMismatch
    case unsupportedFormat(Int)
    case invalidEnvelopeEncoding
}

struct PersistedAppState: Codable, Equatable {
    static let currentSchemaVersion = 1
    let snapshot: QuotaSnapshot
    let status: QuotaRefreshStatus
    let lastSuccessAt: Date?
    let lastAttemptAt: Date?
    let failureCount: Int
    let savedAt: Date
    let schemaVersion: Int

    init(snapshot: QuotaSnapshot, status: QuotaRefreshStatus, lastSuccessAt: Date?, lastAttemptAt: Date?, failureCount: Int, savedAt: Date = .now, schemaVersion: Int = currentSchemaVersion) {
        self.snapshot = snapshot
        self.status = status
        self.lastSuccessAt = lastSuccessAt
        self.lastAttemptAt = lastAttemptAt
        self.failureCount = max(0, failureCount)
        self.savedAt = savedAt
        self.schemaVersion = schemaVersion
    }
}

enum CodexMonitorWidgetConstants {
    static let kind = "CodexMonitorQuotaWidget"
    static let appGroupIdentifier = "JYL9G28DP3.com.ryukeilee.CodexMonitorNativePrototype"
    static let stateFileName = "WidgetDisplayState.json"
}

/// A pure WidgetKit timeline contract shared with the host target for tests.
/// Semantic entries update known quota state exactly; calendar entries keep
/// day-relative labels correct without waking the host app. `reloadAfter` is a
/// low-frequency revalidation checkpoint for presentation-environment changes
/// that cannot be observed while the extension is not running.
struct WidgetTimelinePlan: Equatable {
    static let activeRevalidationInterval: TimeInterval = 30 * 60
    static let passiveRevalidationInterval: TimeInterval = 60 * 60
    static let disconnectedRevalidationInterval: TimeInterval = 6 * 60 * 60
    static let calendarDayLookaheadCount = 7

    let entryDates: [Date]
    let calendarDayEntryDates: [Date]
    let reloadAfter: Date
}

struct WidgetDisplayState: Codable, Equatable {
    /// A Widget payload should never claim that an abandoned request is still
    /// running forever. Real refreshes normally time out within seconds; two
    /// minutes leaves headroom for executable fallback and detail enrichment.
    static let refreshingLeaseInterval: TimeInterval = 2 * 60

    let snapshot: QuotaSnapshot
    let status: QuotaRefreshStatus
    let lastSuccessAt: Date?
    let lastAttemptAt: Date?
    let effectiveFiveHourResetAt: Date?
    let resetCreditFooterLine: String?
    let savedAt: Date

    /// In-memory marker used only when the host has observed a wall-clock
    /// rollback. It is intentionally excluded from the persisted payload so
    /// older app and Widget readers keep the same wire format.
    let allowsOlderRealSnapshot: Bool

    private enum CodingKeys: String, CodingKey {
        case snapshot
        case status
        case lastSuccessAt
        case lastAttemptAt
        case effectiveFiveHourResetAt
        case resetCreditFooterLine
        case savedAt
    }

    static func make(
        snapshot: QuotaSnapshot,
        status: QuotaRefreshStatus,
        lastSuccessAt: Date?,
        lastAttemptAt: Date?,
        effectiveFiveHourResetAt: Date?,
        resetCreditFooterLine: String? = nil,
        savedAt: Date = .now,
        allowsOlderRealSnapshot: Bool = false
    ) -> WidgetDisplayState {
        WidgetDisplayState(
            snapshot: snapshot,
            status: status,
            lastSuccessAt: lastSuccessAt,
            lastAttemptAt: lastAttemptAt,
            effectiveFiveHourResetAt: effectiveFiveHourResetAt,
            resetCreditFooterLine: resetCreditFooterLine ?? Self.makeResetCreditFooterLine(
                for: snapshot,
                now: savedAt
            ),
            savedAt: savedAt,
            allowsOlderRealSnapshot: allowsOlderRealSnapshot
        )
    }

    init(
        snapshot: QuotaSnapshot,
        status: QuotaRefreshStatus,
        lastSuccessAt: Date?,
        lastAttemptAt: Date?,
        effectiveFiveHourResetAt: Date?,
        resetCreditFooterLine: String?,
        savedAt: Date,
        allowsOlderRealSnapshot: Bool = false
    ) {
        self.snapshot = snapshot
        self.status = status
        self.lastSuccessAt = lastSuccessAt
        self.lastAttemptAt = lastAttemptAt
        self.effectiveFiveHourResetAt = effectiveFiveHourResetAt
        self.resetCreditFooterLine = resetCreditFooterLine
        self.savedAt = savedAt
        self.allowsOlderRealSnapshot = allowsOlderRealSnapshot
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let snapshot = try container.decode(QuotaSnapshot.self, forKey: .snapshot)
        let savedAt = try container.decode(Date.self, forKey: .savedAt)
        self.init(
            snapshot: snapshot,
            status: try container.decode(QuotaRefreshStatus.self, forKey: .status),
            lastSuccessAt: try container.decodeIfPresent(Date.self, forKey: .lastSuccessAt),
            lastAttemptAt: try container.decodeIfPresent(Date.self, forKey: .lastAttemptAt),
            effectiveFiveHourResetAt: try container.decodeIfPresent(Date.self, forKey: .effectiveFiveHourResetAt),
            resetCreditFooterLine: try container.decodeIfPresent(String.self, forKey: .resetCreditFooterLine) ?? Self.makeResetCreditFooterLine(
                for: snapshot,
                now: savedAt
            ),
            savedAt: savedAt,
            allowsOlderRealSnapshot: false
        )
    }

    static let placeholder = WidgetDisplayState(
        snapshot: .notConnected,
        status: .noSnapshot,
        lastSuccessAt: nil,
        lastAttemptAt: nil,
        effectiveFiveHourResetAt: nil,
        resetCreditFooterLine: nil,
        savedAt: .now
    )

    var statusText: String {
        statusText(now: .now)
    }

    func effectiveStatus(at now: Date) -> QuotaRefreshStatus {
        if status == .refreshing {
            guard !hasActiveRefreshingLease(at: now) else { return .refreshing }
            guard snapshot.dataSource == .real else {
                return lastSuccessAt == nil ? .noSnapshot : .demoMode
            }
            return .stale
        }

        guard snapshot.dataSource == .real else {
            return status
        }

        guard status == .success else { return status }
        let freshnessReference = lastSuccessAt ?? snapshot.refreshedAt

        // The host requests new data after a clock change. If it is not
        // running, fail closed instead of presenting a future-dated snapshot
        // as newly successful after a wall-clock rollback.
        guard freshnessReference <= now else { return .stale }

        return QuotaTemporalSemantics.freshness(
            lastSuccessAt: freshnessReference,
            now: now,
            staleAfterInterval: QuotaTemporalSemantics.defaultStaleAfterInterval
        ).isFresh ? .success : .stale
    }

    func statusText(now: Date) -> String {
        StatusPopoverFormatting.titleSummary(for: effectiveStatus(at: now))
    }

    func quotaItems(now: Date = .now) -> [StatusPopoverFormatting.QuotaWindowDisplayItem] {
        StatusPopoverFormatting.quotaWindowDisplayItems(
            snapshot: snapshot,
            status: effectiveStatus(at: now),
            now: now
        )
    }

    func quotaSelection(
        capacity: Int,
        now: Date = .now
    ) -> StatusPopoverFormatting.QuotaWindowSelection {
        StatusPopoverFormatting.quotaWindowSelection(
            snapshot: snapshot,
            status: effectiveStatus(at: now),
            capacity: capacity,
            now: now
        )
    }

    var fiveHourQuotaText: String {
        StatusPopoverFormatting.quotaValueText(
            for: .fiveHour,
            snapshot: snapshot,
            status: effectiveStatus(at: .now)
        )
    }

    var fiveHourQuotaDisplay: StatusPopoverFormatting.QuotaValueDisplay {
        StatusPopoverFormatting.quotaValueDisplay(
            for: .fiveHour,
            snapshot: snapshot,
            status: effectiveStatus(at: .now)
        )
    }

    var weeklyQuotaText: String {
        StatusPopoverFormatting.quotaValueText(
            for: .weekly,
            snapshot: snapshot,
            status: effectiveStatus(at: .now)
        )
    }

    var weeklyQuotaDisplay: StatusPopoverFormatting.QuotaValueDisplay {
        StatusPopoverFormatting.quotaValueDisplay(
            for: .weekly,
            snapshot: snapshot,
            status: effectiveStatus(at: .now)
        )
    }

    func recoveryDetails(now: Date = .now) -> StatusPopoverFormatting.RecoveryDetails {
        StatusPopoverFormatting.recoveryDetails(
            resetAt: effectiveFiveHourResetAt,
            status: effectiveStatus(at: now),
            now: now
        )
    }

    func nextTemporalTransition(after now: Date) -> Date? {
        temporalTransitionDates(after: now).first
    }

    func temporalTransitionDates(after now: Date) -> [Date] {
        var dates = QuotaTemporalSemantics.upcomingTransitions(
            snapshot: snapshot,
            status: effectiveStatus(at: now),
            lastSuccessAt: lastSuccessAt ?? (snapshot.dataSource == .real ? snapshot.refreshedAt : nil),
            now: now
        )
        .map(\.date)

        if let refreshingLeaseExpiry = refreshingLeaseExpiry(after: now) {
            dates.append(refreshingLeaseExpiry)
        }

        return Array(Set(dates)).sorted()
    }

    func timelineEntryDates(startingAt now: Date) -> [Date] {
        [now] + temporalTransitionDates(after: now)
    }

    func timelinePlan(
        startingAt now: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) -> WidgetTimelinePlan {
        let calendarDayEntryDates = Self.calendarDayEntryDates(
            after: now,
            calendar: calendar,
            count: WidgetTimelinePlan.calendarDayLookaheadCount
        )
        let reloadAfter = now.addingTimeInterval(revalidationInterval(at: now))
        let entryDates = Array(Set(
            timelineEntryDates(startingAt: now) +
            calendarDayEntryDates +
            [reloadAfter]
        )).sorted()

        return WidgetTimelinePlan(
            entryDates: entryDates,
            calendarDayEntryDates: calendarDayEntryDates,
            reloadAfter: reloadAfter
        )
    }

    func refreshDisplayDate(at now: Date = .now) -> Date? {
        if let lastSuccessAt {
            return lastSuccessAt
        }
        if snapshot.dataSource == .real || effectiveStatus(at: now) == .demoMode {
            return snapshot.refreshedAt
        }
        return nil
    }

    func updatedLine(now: Date = .now) -> String {
        StatusPopoverFormatting.updatedLine(
            lastSuccess: refreshDisplayDate(at: now),
            lastAttempt: lastAttemptAt,
            now: now
        )
    }

    var resetCreditFooterText: String? {
        resetCreditFooterText(now: .now)
    }

    func resetCreditFooterText(
        now: Date,
        locale: Locale = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> String? {
        Self.resetCreditLine(
            snapshot: snapshot,
            at: now,
            locale: locale,
            timeZone: timeZone
        )
    }

    /// Alias kept for the diagnostics/persistence callers that ask for the
    /// earliest reset-credit line directly. Both spellings resolve through the
    /// same formatter, so they can never disagree.
    func earliestResetCreditLine(
        now: Date = .now,
        locale: Locale = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> String? {
        resetCreditFooterText(now: now, locale: locale, timeZone: timeZone)
    }

    /// The single source for "which available reset credit expires first".
    /// The persisted footer line, the live footer, and the diagnostics line
    /// ask the same question and must never drift apart.
    private static func earliestAvailableResetCreditExpiry(
        in snapshot: QuotaSnapshot,
        at now: Date
    ) -> Date? {
        snapshot.resetCreditDetails
            .filter { QuotaTemporalSemantics.isAvailableResetCredit($0, at: now) }
            .compactMap(\.expiresAt)
            .min()
    }

    private static func resetCreditLine(
        snapshot: QuotaSnapshot,
        at now: Date,
        locale: Locale,
        timeZone: TimeZone
    ) -> String? {
        guard let earliestExpiry = earliestAvailableResetCreditExpiry(in: snapshot, at: now) else {
            return nil
        }

        let timeText = StatusPopoverFormatting.dateString(
            from: earliestExpiry,
            format: "M/d HH:mm",
            locale: locale,
            timeZone: timeZone
        )
        let prefix = snapshot.resetCreditDetailsState == .unavailable ? "上次重置" : "最早重置"
        return "\(prefix) \(timeText)"
    }

    private static func makeResetCreditFooterLine(
        for snapshot: QuotaSnapshot,
        now: Date
    ) -> String? {
        resetCreditLine(
            snapshot: snapshot,
            at: now,
            locale: .autoupdatingCurrent,
            timeZone: .autoupdatingCurrent
        )
    }

    private func hasActiveRefreshingLease(at now: Date) -> Bool {
        guard status == .refreshing else { return false }
        let startedAt = lastAttemptAt ?? savedAt
        guard startedAt <= now else { return false }
        return now < startedAt.addingTimeInterval(Self.refreshingLeaseInterval)
    }

    private func refreshingLeaseExpiry(after now: Date) -> Date? {
        guard status == .refreshing else { return nil }
        let startedAt = lastAttemptAt ?? savedAt
        guard startedAt <= now else { return nil }
        let expiry = startedAt.addingTimeInterval(Self.refreshingLeaseInterval)
        return now < expiry ? expiry : nil
    }

    private func revalidationInterval(at now: Date) -> TimeInterval {
        guard snapshot.dataSource == .real else {
            return WidgetTimelinePlan.disconnectedRevalidationInterval
        }

        switch effectiveStatus(at: now) {
        case .success, .refreshing:
            return WidgetTimelinePlan.activeRevalidationInterval
        case .stale, .networkFailed, .authRequired, .parseFailed:
            return WidgetTimelinePlan.passiveRevalidationInterval
        case .idle, .noSnapshot, .demoMode:
            return WidgetTimelinePlan.disconnectedRevalidationInterval
        }
    }

    private static func calendarDayEntryDates(
        after now: Date,
        calendar: Calendar,
        count: Int
    ) -> [Date] {
        guard count > 0 else { return [] }
        var dates: [Date] = []
        var cursor = now

        for _ in 0..<count {
            guard let boundary = calendar.dateInterval(of: .day, for: cursor)?.end,
                  boundary > cursor else {
                break
            }
            dates.append(boundary)
            cursor = boundary.addingTimeInterval(1)
        }

        return dates
    }

    static func == (lhs: WidgetDisplayState, rhs: WidgetDisplayState) -> Bool {
        lhs.snapshot == rhs.snapshot &&
        lhs.status == rhs.status &&
        lhs.lastSuccessAt == rhs.lastSuccessAt &&
        lhs.lastAttemptAt == rhs.lastAttemptAt &&
        lhs.effectiveFiveHourResetAt == rhs.effectiveFiveHourResetAt &&
        lhs.resetCreditFooterLine == rhs.resetCreditFooterLine
    }

    func isEquivalent(to other: WidgetDisplayState) -> Bool {
        self == other && allowsOlderRealSnapshot == other.allowsOlderRealSnapshot
    }
}

/// The immutable presentation snapshot shared by the app, menu bar, popover,
/// and widget. Keep `WidgetDisplayState` as the concrete persisted type so
/// existing widget payloads remain source- and wire-compatible.
typealias QuotaPresentationSnapshot = WidgetDisplayState

/// Maximum clock skew tolerance (in seconds) for comparing widget-state timestamps
/// between the server (refreshedAt), the local writer (savedAt), and the widget
/// extension reader. Without this tolerance a server clock that is even slightly
/// ahead of the Mac can cause the widget to reject valid data and show placeholder
/// for the entire freshness window.
let widgetTimestampSkewTolerance: TimeInterval = 120

enum WidgetDisplayStateStore {
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()
    private static let lock = NSLock()
    private static let envelopeMetadataKeys: Set<String> = [
        "formatVersion", "revision", "payload", "checksum", "writtenAt"
    ]

    // MARK: - Test instrumentation

#if DEBUG
    /// Deterministic counts of the JSON work this store performs, so redundancy
    /// tests can assert that one load or commit classifies its persisted bytes
    /// once instead of re-parsing them per decision. `checksumValidations`
    /// counts checksum verification attempts, not the single checksum generated
    /// when an envelope is written. Compiled out of release builds.
    struct Instrumentation: Equatable {
        var decodes = 0
        var payloadEncodes = 0
        var checksumValidations = 0
    }

    private static let instrumentationLock = NSLock()
    nonisolated(unsafe) private static var instrumentation = Instrumentation()

    static var debugWidgetStateInstrumentation: Instrumentation {
        instrumentationLock.lock()
        defer { instrumentationLock.unlock() }
        return instrumentation
    }

    private static func recordDecode() { recordInstrumentation { $0.decodes += 1 } }
    private static func recordPayloadEncode() { recordInstrumentation { $0.payloadEncodes += 1 } }
    private static func recordChecksumValidation() { recordInstrumentation { $0.checksumValidations += 1 } }

    private static func recordInstrumentation(_ update: (inout Instrumentation) -> Void) {
        instrumentationLock.lock()
        defer { instrumentationLock.unlock() }
        update(&instrumentation)
    }
#else
    private static func recordDecode() {}
    private static func recordPayloadEncode() {}
    private static func recordChecksumValidation() {}
#endif

    /// One decode/validation pass over a single persisted widget-state datum
    /// (the primary or its backup).
    ///
    /// `load` and `saveUnlocked` need the same facts about those bytes: whether
    /// a newer persistence version wrote them, whether they are a current-format
    /// envelope with a revision, whether they are a supported legacy payload, and
    /// whether either can be trusted. Classifying each datum once keeps those
    /// answers consistent and removes the repeated envelope, payload, checksum,
    /// and raw-state parses the call sites used to run independently.
    private struct WidgetStateAudit {
        struct Envelope {
            let state: WidgetDisplayState
            let revision: UInt64
        }

        /// Present when the datum is a current-format envelope whose checksum
        /// verifies, whose payload decodes, and whose schema is supported.
        let envelope: Envelope?
        /// The unwrapped legacy payload, decoded only for a datum that carries
        /// no envelope metadata at all.
        let legacyState: WidgetDisplayState?
        /// The datum was written by a newer persistence format, or by a newer
        /// snapshot schema, than this binary understands.
        let isNewerPersistenceVersion: Bool

        /// A datum that either the envelope or the legacy path accepted.
        var isTrusted: Bool { envelope != nil || legacyState != nil }

        static let absent = WidgetStateAudit(
            envelope: nil,
            legacyState: nil,
            isNewerPersistenceVersion: false
        )
    }

    /// How this binary can treat the snapshot schema of a decoded widget state.
    private enum SchemaSupport {
        case newerVersion
        case supported
        case unsupported
    }

    private static func classifySchemaSupport(_ state: WidgetDisplayState) -> SchemaSupport {
        if state.snapshot.schemaVersion > QuotaSnapshot.currentSchemaVersion {
            return .newerVersion
        }
        return isSupported(state) ? .supported : .unsupported
    }

    private static func audit(_ data: Data?) -> WidgetStateAudit {
        guard let data else { return .absent }

        var envelope: WidgetStateAudit.Envelope?
        var legacyState: WidgetDisplayState?
        var isNewerPersistenceVersion = false

        if let rawEnvelope = decodePersistedEnvelope(data) {
            // Envelope metadata is present, so the flattened legacy fields can
            // never describe this datum: a checksum failure must not fall
            // through to them.
            if validateChecksum(of: rawEnvelope) {
                if rawEnvelope.formatVersion > PersistenceEnvelope.currentFormatVersion {
                    isNewerPersistenceVersion = true
                } else if rawEnvelope.formatVersion == PersistenceEnvelope.currentFormatVersion,
                          let state = decodePayload(from: rawEnvelope) {
                    switch classifySchemaSupport(state) {
                    case .newerVersion:
                        isNewerPersistenceVersion = true
                    case .supported:
                        envelope = WidgetStateAudit.Envelope(
                            state: state,
                            revision: rawEnvelope.revision
                        )
                    case .unsupported:
                        break
                    }
                }
            }
        } else if !containsEnvelopeMetadata(data),
                  let state = decodeState(data) {
            switch classifySchemaSupport(state) {
            case .newerVersion:
                isNewerPersistenceVersion = true
            case .supported:
                legacyState = state
            case .unsupported:
                break
            }
        }

        return WidgetStateAudit(
            envelope: envelope,
            legacyState: legacyState,
            isNewerPersistenceVersion: isNewerPersistenceVersion
        )
    }

    static func load(fileManager: FileManager = .default) -> WidgetDisplayState {
        lock.lock()
        defer { lock.unlock() }
        guard let transactionLock = acquireTransactionLock(fileManager: fileManager) else {
            PersistenceLog.logger.error("Cannot acquire widget state transaction lock; using not-connected placeholder")
            return .placeholder
        }
        defer { transactionLock.release() }

        let url = stateURL(fileManager: fileManager)
        let primary = audit(try? Data(contentsOf: url))

        if let envelope = primary.envelope {
            return envelope.state
        }

        // Read pre-envelope files once and immediately migrate them.
        if let legacy = primary.legacyState {
            saveUnlocked(legacy, fileManager: fileManager)
            return legacy
        }

        let backupURL = url.appendingPathExtension("backup")
        let backupData = try? Data(contentsOf: backupURL)
        let backup = audit(backupData)
        if primary.isNewerPersistenceVersion {
            if let envelope = backup.envelope {
                PersistenceLog.logger.error("Widget state uses a newer persistence version; displaying backup without replacing primary")
                return envelope.state
            }
            if let legacyBackup = backup.legacyState {
                PersistenceLog.logger.error("Widget state uses a newer persistence version; displaying legacy backup without replacing primary")
                return legacyBackup
            }
            PersistenceLog.logger.error("Widget state uses a newer persistence version; preserving primary and using placeholder")
            return .placeholder
        }

        if let backupData {
            if let envelope = backup.envelope {
                quarantine(url: url, fileManager: fileManager)
                if restoreEnvelopeBackup(backupData, to: url) {
                    PersistenceLog.logger.error("Recovered widget state from backup after primary corruption")
                } else {
                    PersistenceLog.logger.error("Widget backup was readable but could not be restored to primary storage")
                }
                return envelope.state
            }

            if let legacyBackup = backup.legacyState {
                quarantine(url: url, fileManager: fileManager)
                try? backupData.write(to: url, options: .atomic)
                saveUnlocked(legacyBackup, fileManager: fileManager)
                // The migration round-trip is the one place worth re-decoding:
                // it proves the flattened legacy payload survived the envelope
                // re-encode written by `saveUnlocked`.
                if let readback = try? Data(contentsOf: url), audit(readback).envelope?.state == legacyBackup {
                    PersistenceLog.logger.error("Recovered and migrated legacy widget state from backup after primary corruption")
                } else {
                    PersistenceLog.logger.error("Legacy widget backup was readable but migration could not be persisted")
                }
                return legacyBackup
            }
        }

        quarantine(url: url, fileManager: fileManager)
        PersistenceLog.logger.error("Widget state was corrupt or truncated; using not-connected placeholder")
        return .placeholder
    }

    @discardableResult
    static func save(_ state: WidgetDisplayState, fileManager: FileManager = .default) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let transactionLock = acquireTransactionLock(fileManager: fileManager) else {
            PersistenceLog.logger.error("Cannot acquire widget state transaction lock; save was skipped")
            return false
        }
        defer { transactionLock.release() }

        return saveUnlocked(state, fileManager: fileManager)
    }

    private static func acquireTransactionLock(fileManager: FileManager) -> WidgetStateTransactionLock? {
        let url = lockURL(fileManager: fileManager)
        do {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            PersistenceLog.logger.error("Cannot create widget state directory for transaction lock: \(error.localizedDescription, privacy: .public)")
            return nil
        }

        let flags = O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW
        let fileDescriptor = Darwin.open(url.path, flags, S_IRUSR | S_IWUSR)
        guard fileDescriptor >= 0 else {
            let errorDescription = String(cString: strerror(errno))
            PersistenceLog.logger.error("Cannot open widget state transaction lock: \(errorDescription, privacy: .public)")
            return nil
        }

        while codexMonitorFlock(fileDescriptor, LOCK_EX) != 0 {
            if errno == EINTR {
                continue
            }
            let errorDescription = String(cString: strerror(errno))
            Darwin.close(fileDescriptor)
            PersistenceLog.logger.error("Cannot lock widget state transaction file: \(errorDescription, privacy: .public)")
            return nil
        }

        return WidgetStateTransactionLock(fileDescriptor: fileDescriptor)
    }

    @discardableResult
    private static func saveUnlocked(_ state: WidgetDisplayState, fileManager: FileManager) -> Bool {
        guard isSupported(state) else {
            PersistenceLog.logger.error("Cannot persist widget state from unsupported snapshot schemaV\(state.snapshot.schemaVersion)")
            return false
        }

        let url = stateURL(fileManager: fileManager)

        do {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let currentData = try? Data(contentsOf: url)
            // The Widget cannot independently read the current Codex identity.
            // Any explicit host invalidation therefore has to remove every old
            // real recovery source, even when the primary is missing, corrupt,
            // or from a newer format that this binary cannot decode.
            let explicitlyInvalidatesRealSnapshot = state.snapshot.dataSource != .real
                && state.status != .demoMode
            let current = audit(currentData)
            if current.isNewerPersistenceVersion, !explicitlyInvalidatesRealSnapshot {
                PersistenceLog.logger.error("Cannot overwrite widget state written by a newer persistence version")
                return false
            }
            let currentState = current.envelope?.state ?? current.legacyState
            let crossesAccountBoundary = currentState.map {
                guard let currentBoundary = $0.snapshot.accountBoundary,
                      let newBoundary = state.snapshot.accountBoundary else {
                    return false
                }
                return $0.snapshot.dataSource == .real
                    && state.snapshot.dataSource == .real
                    && !newBoundary.matches(currentBoundary)
            } ?? false
            if let currentState {
                // Block every non-real write over real data unless this write is
                // the explicit fail-closed invalidation.
                if currentState.snapshot.dataSource == .real
                    && state.snapshot.dataSource != .real
                    && !explicitlyInvalidatesRealSnapshot {
                    PersistenceLog.logger.info("Ignored widget state write: non-real over real without explicit invalidation")
                    return false
                }
                // Block real writes that are older than the current real snapshot.
                // Use refreshedAt (semantic timestamp) for real data.
                if state.snapshot.dataSource == .real
                    && currentState.snapshot.dataSource == .real
                    && !crossesAccountBoundary
                    && !state.allowsOlderRealSnapshot
                    && state.snapshot.refreshedAt < currentState.snapshot.refreshedAt {
                    PersistenceLog.logger.info("Ignored older real widget state write refreshedAt=\(state.snapshot.refreshedAt.timeIntervalSince1970, format: .fixed(precision: 0))")
                    return false
                }
                // Block older non-real writes (use savedAt as ordering key for
                // non-real states where refreshedAt is not semantically meaningful).
                if state.snapshot.dataSource != .real
                    && currentState.snapshot.dataSource != .real
                    && state.savedAt < currentState.savedAt {
                    PersistenceLog.logger.info("Ignored older non-real widget state write savedAt=\(state.savedAt.timeIntervalSince1970, format: .fixed(precision: 0))")
                    return false
                }
            }

            let currentRevision = current.envelope?.revision ?? 0
            guard currentRevision < UInt64.max else {
                PersistenceLog.logger.error("Cannot persist widget state: revision reached UInt64.max")
                return false
            }
            let revision = currentRevision + 1
            let payload = try encodePayload(state)
            let data = try encodedEnvelopeData(payload: payload, revision: revision)
            let backupURL = url.appendingPathExtension("backup")
            if explicitlyInvalidatesRealSnapshot || crossesAccountBoundary {
                try? fileManager.removeItem(at: backupURL)
            } else if let currentData, current.isTrusted {
                try currentData.write(to: backupURL, options: .atomic)
                guard let backupReadback = try? Data(contentsOf: backupURL), backupReadback == currentData else {
                    PersistenceLog.logger.error("Widget state backup verification failed; primary was not replaced")
                    return false
                }
            }
            let temporaryURL = url.appendingPathExtension("tmp-\(UUID().uuidString)")
            defer {
                try? fileManager.removeItem(at: temporaryURL)
            }
            try data.write(to: temporaryURL, options: .atomic)

            // Write to the final destination.
            // Use replaceItemAt when the file exists (preserves inode for file
            // coordination), otherwise moveItem.
            if fileManager.fileExists(atPath: url.path) {
                let writeURL: URL
                do {
                    writeURL = try fileManager.replaceItemAt(url, withItemAt: temporaryURL) ?? url
                } catch {
                    PersistenceLog.logger.error("Widget state replaceItemAt threw: \(error.localizedDescription, privacy: .public); trying remove+move")
                    try fileManager.removeItem(at: url)
                    try fileManager.moveItem(at: temporaryURL, to: url)
                    writeURL = url
                }
                guard let readback = try? Data(contentsOf: writeURL),
                      readback == data,
                      isEnvelope(data, atRevision: revision) else {
                    PersistenceLog.logger.error("Widget state write verification failed at revision \(revision); restoring backup")
                    try? fileManager.removeItem(at: writeURL)
                    if let currentData { try? currentData.write(to: url, options: .atomic) }
                    return false
                }
            } else {
                try fileManager.moveItem(at: temporaryURL, to: url)
                guard let readback = try? Data(contentsOf: url),
                      readback == data,
                      isEnvelope(data, atRevision: revision) else {
                    PersistenceLog.logger.error("Widget state write verification failed at revision \(revision); rolling back")
                    try? fileManager.removeItem(at: url)
                    if let current = currentData { try? current.write(to: url, options: .atomic) }
                    return false
                }
            }
            return true
        } catch {
            PersistenceLog.logger.error("Failed to persist widget state: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private static func decodePersistedEnvelope(_ data: Data) -> PersistenceEnvelope? {
        recordDecode()
        return try? decoder.decode(PersistenceEnvelope.self, from: data)
    }

    private static func decodePayload(from envelope: PersistenceEnvelope) -> WidgetDisplayState? {
        recordDecode()
        return try? decoder.decode(WidgetDisplayState.self, from: envelope.payload)
    }

    private static func decodeState(_ data: Data) -> WidgetDisplayState? {
        recordDecode()
        return try? decoder.decode(WidgetDisplayState.self, from: data)
    }

    private static func encodePayload(_ state: WidgetDisplayState) throws -> Data {
        recordPayloadEncode()
        return try encoder.encode(state)
    }

    private static func validateChecksum(of envelope: PersistenceEnvelope) -> Bool {
        recordChecksumValidation()
        return envelope.hasValidChecksum
    }

    /// Verifies the envelope bytes this store just produced. The payload is not
    /// re-decoded: this same call encoded it from an already-supported state.
    private static func isEnvelope(_ data: Data, atRevision revision: UInt64) -> Bool {
        guard let envelope = decodePersistedEnvelope(data),
              validateChecksum(of: envelope),
              envelope.formatVersion == PersistenceEnvelope.currentFormatVersion else {
            return false
        }
        return envelope.revision == revision
    }

    private static func containsEnvelopeMetadata(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return object.keys.contains { envelopeMetadataKeys.contains($0) }
    }

    private static func isSupported(_ state: WidgetDisplayState) -> Bool {
        guard (1...QuotaSnapshot.currentSchemaVersion).contains(state.snapshot.schemaVersion) else {
            return false
        }
        return state.snapshot.dataSource != .real
            || state.snapshot.accountBoundary?.isValid == true
    }

    private static func restoreEnvelopeBackup(_ data: Data, to url: URL) -> Bool {
        do {
            try data.write(to: url, options: .atomic)
            // Exact readback equality preserves the validation this call already
            // performed on the same bytes, so the restored primary is not
            // decoded a second time.
            guard let readback = try? Data(contentsOf: url), readback == data else {
                PersistenceLog.logger.error("Widget state backup restore verification failed")
                return false
            }
            return true
        } catch {
            PersistenceLog.logger.error("Failed to restore widget state backup: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private static func encodedEnvelopeData(payload: Data, revision: UInt64) throws -> Data {
        let envelope = PersistenceEnvelope(payload: payload, revision: revision)
        guard var envelopeObject = try JSONSerialization.jsonObject(
            with: encoder.encode(envelope)
        ) as? [String: Any],
              let legacyObject = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            throw PersistenceError.invalidEnvelopeEncoding
        }

        // Keep the payload fields at the top level for older Widget extensions
        // that predate the checksummed envelope and decode WidgetDisplayState
        // directly. New readers still verify the envelope checksum first. The
        // payload bytes come from the single encode of `state`.
        for (key, value) in legacyObject {
            envelopeObject[key] = value
        }
        return try JSONSerialization.data(withJSONObject: envelopeObject, options: [.sortedKeys])
    }

    private static func quarantine(url: URL, fileManager: FileManager) {
        guard fileManager.fileExists(atPath: url.path) else { return }
        let corruptURL = url.appendingPathExtension("corrupt")
        try? fileManager.removeItem(at: corruptURL)
        try? fileManager.moveItem(at: url, to: corruptURL)
    }

    static func stateURL(fileManager: FileManager = .default) -> URL {
        if let groupURL = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: CodexMonitorWidgetConstants.appGroupIdentifier
        ) {
            return groupURL.appendingPathComponent(CodexMonitorWidgetConstants.stateFileName)
        }

        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let baseURL = appSupport ?? fileManager.temporaryDirectory
        return baseURL
            .appendingPathComponent("CodexMonitorNative", isDirectory: true)
            .appendingPathComponent(CodexMonitorWidgetConstants.stateFileName)
    }

    static func lockURL(fileManager: FileManager = .default) -> URL {
        stateURL(fileManager: fileManager).appendingPathExtension("lock")
    }

    /// Removes only a stale quarantine artifact. The primary and backup are
    /// deliberately left to the locked load/recovery path: either one may be
    /// the only readable copy after a failed startup sync, and a future-format
    /// primary must never be deleted by an older host.
    static func cleanCache(fileManager: FileManager = .default) {
        lock.lock()
        defer { lock.unlock() }
        guard let transactionLock = acquireTransactionLock(fileManager: fileManager) else {
            PersistenceLog.logger.error("Cannot acquire widget state transaction lock; cache cleanup was skipped")
            return
        }
        defer { transactionLock.release() }

        let url = stateURL(fileManager: fileManager)
        let corruptURL = url.appendingPathExtension("corrupt")
        if fileManager.fileExists(atPath: corruptURL.path) {
            try? fileManager.removeItem(at: corruptURL)
        }
    }

    private final class WidgetStateTransactionLock {
        private var fileDescriptor: Int32?

        init(fileDescriptor: Int32) {
            self.fileDescriptor = fileDescriptor
        }

        func release() {
            guard let fileDescriptor else { return }
            self.fileDescriptor = nil

            while codexMonitorFlock(fileDescriptor, LOCK_UN) != 0 {
                if errno == EINTR {
                    continue
                }
                let errorDescription = String(cString: strerror(errno))
                PersistenceLog.logger.error("Cannot unlock widget state transaction file: \(errorDescription, privacy: .public)")
                break
            }
            Darwin.close(fileDescriptor)
        }

        deinit {
            release()
        }
    }
}
