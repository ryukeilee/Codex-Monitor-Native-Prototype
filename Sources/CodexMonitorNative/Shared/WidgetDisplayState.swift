import Foundation
import CryptoKit
import OSLog

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
        let payload = try encoder.encode(value)
        self.formatVersion = Self.currentFormatVersion
        self.revision = revision
        self.payload = payload
        self.checksum = Self.checksum(payload)
        self.writtenAt = .now
    }

    func decode<T: Decodable>(_ type: T.Type, decoder: JSONDecoder = PersistenceEnvelope.decoder) throws -> T {
        guard formatVersion == Self.currentFormatVersion else { throw PersistenceError.unsupportedFormat(formatVersion) }
        guard Self.checksum(payload) == checksum else { throw PersistenceError.checksumMismatch }
        return try decoder.decode(type, from: payload)
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
    static let appGroupIdentifier = "group.com.ryukeilee.CodexMonitorNativePrototype"
    static let stateFileName = "WidgetDisplayState.json"
}

struct WidgetDisplayState: Codable, Equatable {
    let snapshot: QuotaSnapshot
    let status: QuotaRefreshStatus
    let lastSuccessAt: Date?
    let lastAttemptAt: Date?
    let effectiveFiveHourResetAt: Date?
    let resetCreditFooterLine: String?
    let savedAt: Date

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
        savedAt: Date = .now
    ) -> WidgetDisplayState {
        WidgetDisplayState(
            snapshot: snapshot,
            status: status,
            lastSuccessAt: lastSuccessAt,
            lastAttemptAt: lastAttemptAt,
            effectiveFiveHourResetAt: effectiveFiveHourResetAt,
            resetCreditFooterLine: resetCreditFooterLine ?? Self.makeResetCreditFooterLine(for: snapshot),
            savedAt: savedAt
        )
    }

    init(
        snapshot: QuotaSnapshot,
        status: QuotaRefreshStatus,
        lastSuccessAt: Date?,
        lastAttemptAt: Date?,
        effectiveFiveHourResetAt: Date?,
        resetCreditFooterLine: String?,
        savedAt: Date
    ) {
        self.snapshot = snapshot
        self.status = status
        self.lastSuccessAt = lastSuccessAt
        self.lastAttemptAt = lastAttemptAt
        self.effectiveFiveHourResetAt = effectiveFiveHourResetAt
        self.resetCreditFooterLine = resetCreditFooterLine
        self.savedAt = savedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let snapshot = try container.decode(QuotaSnapshot.self, forKey: .snapshot)
        self.init(
            snapshot: snapshot,
            status: try container.decode(QuotaRefreshStatus.self, forKey: .status),
            lastSuccessAt: try container.decodeIfPresent(Date.self, forKey: .lastSuccessAt),
            lastAttemptAt: try container.decodeIfPresent(Date.self, forKey: .lastAttemptAt),
            effectiveFiveHourResetAt: try container.decodeIfPresent(Date.self, forKey: .effectiveFiveHourResetAt),
            resetCreditFooterLine: try container.decodeIfPresent(String.self, forKey: .resetCreditFooterLine) ?? Self.makeResetCreditFooterLine(for: snapshot),
            savedAt: try container.decode(Date.self, forKey: .savedAt)
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
        StatusPopoverFormatting.titleSummary(for: status)
    }

    func quotaItems(now: Date = .now) -> [StatusPopoverFormatting.QuotaWindowDisplayItem] {
        StatusPopoverFormatting.quotaWindowDisplayItems(
            snapshot: snapshot,
            status: status,
            now: now
        )
    }

    func quotaSelection(
        capacity: Int,
        now: Date = .now
    ) -> StatusPopoverFormatting.QuotaWindowSelection {
        StatusPopoverFormatting.quotaWindowSelection(
            snapshot: snapshot,
            status: status,
            capacity: capacity,
            now: now
        )
    }

    var fiveHourQuotaText: String {
        StatusPopoverFormatting.quotaValueText(for: .fiveHour, snapshot: snapshot, status: status)
    }

    var fiveHourQuotaDisplay: StatusPopoverFormatting.QuotaValueDisplay {
        StatusPopoverFormatting.quotaValueDisplay(for: .fiveHour, snapshot: snapshot, status: status)
    }

    var weeklyQuotaText: String {
        StatusPopoverFormatting.quotaValueText(for: .weekly, snapshot: snapshot, status: status)
    }

    var weeklyQuotaDisplay: StatusPopoverFormatting.QuotaValueDisplay {
        StatusPopoverFormatting.quotaValueDisplay(for: .weekly, snapshot: snapshot, status: status)
    }

    func recoveryDetails(now: Date = .now) -> StatusPopoverFormatting.RecoveryDetails {
        StatusPopoverFormatting.recoveryDetails(
            resetAt: effectiveFiveHourResetAt,
            status: status,
            now: now
        )
    }

    func updatedLine(now: Date = .now) -> String {
        StatusPopoverFormatting.updatedLine(
            lastSuccess: lastSuccessAt ?? snapshot.refreshedAt,
            lastAttempt: lastAttemptAt,
            now: now
        )
    }

    var earliestResetCreditExpiresAt: Date? {
        snapshot.resetCreditDetails
            .filter { normalizedResetCreditStatus($0.status) == "available" }
            .compactMap(\.expiresAt)
            .min()
    }

    private func normalizedResetCreditStatus(_ status: String) -> String {
        status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var resetCreditFooterText: String? {
        resetCreditFooterLine ?? earliestResetCreditLine()
    }

    func earliestResetCreditLine(
        locale: Locale = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> String? {
        guard let earliestResetCreditExpiresAt else {
            return nil
        }

        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateFormat = "M/d HH:mm"
        return "最早重置 \(formatter.string(from: earliestResetCreditExpiresAt))"
    }

    private static func makeResetCreditFooterLine(for snapshot: QuotaSnapshot) -> String? {
        let earliestExpiry = snapshot.resetCreditDetails
            .filter { $0.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "available" }
            .compactMap(\.expiresAt)
            .min()

        guard let earliestExpiry else {
            return nil
        }

        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "M/d HH:mm"
        return "最早重置 \(formatter.string(from: earliestExpiry))"
    }

    func isEquivalent(to other: WidgetDisplayState) -> Bool {
        snapshot == other.snapshot &&
        status == other.status &&
        lastSuccessAt == other.lastSuccessAt &&
        lastAttemptAt == other.lastAttemptAt &&
        effectiveFiveHourResetAt == other.effectiveFiveHourResetAt &&
        resetCreditFooterLine == other.resetCreditFooterLine
    }
}

enum WidgetDisplayStateStore {
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()
    private static let lock = NSLock()

    static func load(fileManager: FileManager = .default) -> WidgetDisplayState {
        lock.lock()
        defer { lock.unlock() }
        let url = stateURL(fileManager: fileManager)

        if let data = try? Data(contentsOf: url) {
            if let state = decodeEnvelope(data) {
                return state
            }

            // Read pre-envelope files once and immediately migrate them.
            if let legacy = try? decoder.decode(WidgetDisplayState.self, from: data) {
                saveUnlocked(legacy, fileManager: fileManager)
                return legacy
            }
        }

        let backupURL = url.appendingPathExtension("backup")
        if let backupData = try? Data(contentsOf: backupURL), let backup = decodeEnvelope(backupData) {
            quarantine(url: url, fileManager: fileManager)
            try? backupData.write(to: url, options: .atomic)
            PersistenceLog.logger.error("Recovered widget state from backup after primary corruption")
            return backup
        }

        quarantine(url: url, fileManager: fileManager)
        PersistenceLog.logger.error("Widget state was corrupt or truncated; using not-connected placeholder")
        return .placeholder
    }

    static func save(_ state: WidgetDisplayState, fileManager: FileManager = .default) {
        lock.lock()
        defer { lock.unlock() }
        saveUnlocked(state, fileManager: fileManager)
    }

    private static func saveUnlocked(_ state: WidgetDisplayState, fileManager: FileManager) {
        let url = stateURL(fileManager: fileManager)

        do {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let currentData = try? Data(contentsOf: url)
            if let current = currentData, let currentState = decodeEnvelope(current) {
                if (currentState.snapshot.dataSource == .real && state.snapshot.dataSource != .real) ||
                    state.savedAt < currentState.savedAt ||
                    (state.snapshot.dataSource == .real && currentState.snapshot.dataSource == .real && state.snapshot.refreshedAt < currentState.snapshot.refreshedAt) {
                    PersistenceLog.logger.info("Ignored older widget state write savedAt=\(state.savedAt.timeIntervalSince1970, format: .fixed(precision: 0))")
                    return
                }
            }

            let currentRevision = currentData.flatMap { envelopeRevision($0) } ?? 0
            guard currentRevision < UInt64.max else {
                PersistenceLog.logger.error("Cannot persist widget state: revision reached UInt64.max")
                return
            }
            let revision = currentRevision + 1
            let envelope = try PersistenceEnvelope(value: state, revision: revision)
            let data = try encodedEnvelopeData(envelope, preservingLegacyPayload: state)
            if let current = currentData, decodeEnvelope(current) != nil {
                try? current.write(to: url.appendingPathExtension("backup"), options: .atomic)
            }
            let temporaryURL = url.appendingPathExtension("tmp-\(UUID().uuidString)")
            try data.write(to: temporaryURL, options: .atomic)
            if fileManager.fileExists(atPath: url.path) {
                _ = try fileManager.replaceItemAt(url, withItemAt: temporaryURL)
            } else {
                try fileManager.moveItem(at: temporaryURL, to: url)
            }
            guard let readback = try? Data(contentsOf: url), readback == data, envelopeRevision(readback) == revision else {
                PersistenceLog.logger.error("Widget state write verification failed at revision \(revision); restoring trusted backup")
                if let current = currentData { try? current.write(to: url, options: .atomic) } else { try? fileManager.removeItem(at: url) }
                return
            }
        } catch {
            PersistenceLog.logger.error("Failed to persist widget state: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func decodeEnvelope(_ data: Data) -> WidgetDisplayState? {
        guard let envelope = try? decoder.decode(PersistenceEnvelope.self, from: data) else { return nil }
        return try? envelope.decode(WidgetDisplayState.self)
    }

    private static func encodedEnvelopeData(
        _ envelope: PersistenceEnvelope,
        preservingLegacyPayload state: WidgetDisplayState
    ) throws -> Data {
        guard var envelopeObject = try JSONSerialization.jsonObject(
            with: encoder.encode(envelope)
        ) as? [String: Any],
              let legacyObject = try JSONSerialization.jsonObject(
                with: encoder.encode(state)
              ) as? [String: Any] else {
            throw PersistenceError.invalidEnvelopeEncoding
        }

        // Keep the payload fields at the top level for older Widget extensions
        // that predate the checksummed envelope and decode WidgetDisplayState
        // directly. New readers still verify the envelope checksum first.
        for (key, value) in legacyObject {
            envelopeObject[key] = value
        }
        return try JSONSerialization.data(withJSONObject: envelopeObject, options: [.sortedKeys])
    }

    private static func envelopeRevision(_ data: Data) -> UInt64? {
        try? decoder.decode(PersistenceEnvelope.self, from: data).revision
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
}
