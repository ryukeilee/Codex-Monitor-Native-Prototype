import XCTest
@testable import CodexMonitorNative

final class SnapshotStoreTests: XCTestCase {
    private func makeDefaults() -> (defaults: UserDefaults, suiteName: String) {
        let suiteName = "SnapshotStoreTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suiteName)!, suiteName)
    }

    private func makeTamperer() -> (SnapshotStoreReadbackTamperer, String) {
        let suiteName = "SnapshotStoreTests.readback.\(UUID().uuidString)"
        let defaults = SnapshotStoreReadbackTamperer(suiteName: suiteName)!
        defaults.primaryKey = "snapshot"
        return (defaults, suiteName)
    }

    private func realState(
        weekly: Int,
        refreshedAt: Date = Date(timeIntervalSince1970: 100)
    ) -> PersistedAppState {
        let snapshot = QuotaSnapshot(
            weeklyQuotaPercent: weekly,
            fiveHourQuotaPercent: 60,
            refreshedAt: refreshedAt,
            dataSource: .real,
            accountBoundary: .testDefault
        )
        return PersistedAppState(
            snapshot: snapshot,
            status: .success,
            lastSuccessAt: snapshot.refreshedAt,
            lastAttemptAt: nil,
            failureCount: 0
        )
    }

    /// A commit that replaces an already-valid primary used to decode that datum
    /// three times (`containsNewerPersistenceVersion`, `loadEnvelope`, and
    /// `isTrustedPersistenceData`) and probe it twice more for a raw snapshot.
    /// The single audit pass must validate it once and reuse the result for the
    /// revision, trust, account-boundary, and newer-version decisions, and the
    /// write readback must compare bytes instead of re-decoding the buffer it
    /// just encoded.
    func testWarmCommitValidatesPrimaryExactlyOnce() throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SnapshotStore(defaults: defaults, key: "snapshot")

        XCTAssertTrue(store.saveState(realState(weekly: 90)))

        let before = SnapshotStore.debugPersistenceDecodeCount
        XCTAssertTrue(store.saveState(realState(weekly: 80)))
        let decodes = SnapshotStore.debugPersistenceDecodeCount - before

        // One audit: the envelope, its payload, and a single modern-shape probe
        // for a newer raw snapshot. The legacy-shape probe fallback is gone
        // because it always reported schema version 1, and the write readback
        // compares bytes instead of re-decoding the buffer just encoded.
        XCTAssertEqual(decodes, 3)
        XCTAssertEqual(store.loadSnapshot()?.weeklyQuotaPercent, 80)
    }

    /// The raw-snapshot probe runs for every datum, including one that also
    /// decodes as a valid envelope, so a hybrid shape that declares a newer raw
    /// schema is still refused exactly as `containsNewerPersistenceVersion` did.
    func testSaveStillRefusesFutureRawSnapshotHiddenInsideCurrentEnvelope() throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SnapshotStore(defaults: defaults, key: "snapshot")

        let trusted = realState(weekly: 70)
        let envelope = try PersistenceEnvelope(value: trusted, revision: 1)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(envelope)) as? [String: Any]
        )
        // A valid current envelope whose outer JSON also carries a raw snapshot
        // that declares a newer schema. The envelope checksum still matches,
        // because it covers only the payload.
        object["weeklyQuotaPercent"] = 90
        object["fiveHourQuotaPercent"] = 80
        object["refreshedAt"] = Date(timeIntervalSince1970: 300).timeIntervalSinceReferenceDate
        object["dataSource"] = QuotaDataSource.real.rawValue
        object["schemaVersion"] = QuotaSnapshot.currentSchemaVersion + 1
        let primary = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        defaults.set(primary, forKey: "snapshot")

        XCTAssertFalse(store.saveState(realState(weekly: 10, refreshedAt: Date(timeIntervalSince1970: 400))))
        XCTAssertEqual(defaults.data(forKey: "snapshot"), primary)
    }

    /// A raw snapshot may spell the legacy key with JSON unicode escapes, which
    /// decode to `weeklyQuotaPercent` but share no literal bytes with it. The
    /// newer-version refusal must be driven by decoding, never by a byte scan.
    func testSaveRefusesFutureRawSnapshotWithUnicodeEscapedKey() throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SnapshotStore(defaults: defaults, key: "snapshot")
        let primary = Data(
            #"{"weeklyQuota\u0050ercent":90,"fiveHourQuotaPercent":80,"refreshedAt":300,"dataSource":"real","schemaVersion":9}"#.utf8
        )
        defaults.set(primary, forKey: "snapshot")

        XCTAssertFalse(store.saveState(realState(weekly: 10, refreshedAt: Date(timeIntervalSince1970: 400))))
        XCTAssertEqual(defaults.data(forKey: "snapshot"), primary)
        XCTAssertNil(store.loadSnapshot())
    }

    /// A raw legacy primary still migrates through the audit and the migration
    /// write, and the audit must not treat the un-enveloped shape as an
    /// unsupported schema.
    func testRawLegacyPrimaryMigratesThroughSingleAudit() throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let legacy = QuotaSnapshot(
            weeklyQuotaPercent: 80,
            fiveHourQuotaPercent: 60,
            refreshedAt: Date(timeIntervalSince1970: 100),
            dataSource: .real
        )
        defaults.set(try JSONEncoder().encode(legacy), forKey: "snapshot")

        let store = SnapshotStore(defaults: defaults, key: "snapshot")
        let loaded = try XCTUnwrap(store.loadState())

        XCTAssertEqual(loaded.snapshot.schemaVersion, QuotaSnapshot.currentSchemaVersion)
        XCTAssertEqual(loaded.schemaVersion, PersistedAppState.currentSchemaVersion)
        XCTAssertEqual(loaded.snapshot.weeklyQuotaPercent, 80)
        let primary = try XCTUnwrap(defaults.data(forKey: "snapshot"))
        let envelope = try JSONDecoder().decode(PersistenceEnvelope.self, from: primary)
        XCTAssertEqual(try envelope.decode(PersistedAppState.self).snapshot.schemaVersion, QuotaSnapshot.currentSchemaVersion)
    }

    /// A post-write readback that returns different bytes must fail the commit,
    /// put the trusted bytes back, and leave the previous snapshot loadable. The
    /// audit read that precedes the write must still see the real datum, which is
    /// why the tamper only fires on the first primary read after a primary write.
    func testFailedReadbackOverTrustedPrimaryRestoresTrustedBytes() throws {
        let (defaults, suiteName) = makeTamperer()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SnapshotStore(defaults: defaults, key: "snapshot")

        XCTAssertTrue(store.saveState(realState(weekly: 90)))
        let trustedPrimary = try XCTUnwrap(defaults.data(forKey: "snapshot"))

        let tamperedBytes = Data("unrelated readback bytes".utf8)
        defaults.armReadbackTamper(returning: tamperedBytes)
        XCTAssertFalse(store.saveState(realState(weekly: 80, refreshedAt: Date(timeIntervalSince1970: 200))))

        // The audit read saw the trusted datum; only the post-write readback lied.
        XCTAssertEqual(defaults.primaryReads.count, 2)
        XCTAssertEqual(defaults.primaryReads[0].stored, trustedPrimary)
        XCTAssertEqual(defaults.primaryReads[0].returned, trustedPrimary)
        XCTAssertFalse(defaults.primaryReads[0].isTampered)
        // The new bytes did land before the readback; only its return value lied.
        XCTAssertNotEqual(defaults.primaryReads[1].stored, trustedPrimary)
        XCTAssertEqual(defaults.primaryReads[1].returned, tamperedBytes)
        XCTAssertTrue(defaults.primaryReads[1].isTampered)
        // The rejected write is rolled back: one attempted primary write, then one
        // restore of the trusted bytes.
        XCTAssertEqual(defaults.primaryWrites, 2)
        XCTAssertEqual(defaults.primaryRemovals, 0)
        XCTAssertEqual(defaults.data(forKey: "snapshot"), trustedPrimary)
        XCTAssertEqual(defaults.data(forKey: "snapshot.backup"), trustedPrimary)
        XCTAssertEqual(store.loadSnapshot()?.weeklyQuotaPercent, 90)
        XCTAssertEqual(store.loadState()?.snapshot.weeklyQuotaPercent, 90)
    }

    /// With no trusted datum anywhere, a failed readback must delete the
    /// unverified primary rather than leave bytes that never validated.
    func testFailedReadbackOverEmptyStoreDeletesPrimary() throws {
        let (defaults, suiteName) = makeTamperer()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SnapshotStore(defaults: defaults, key: "snapshot")

        defaults.armReadbackTamper(returning: nil)
        XCTAssertFalse(store.saveState(realState(weekly: 80)))

        XCTAssertEqual(defaults.primaryReads.count, 2)
        XCTAssertNil(defaults.primaryReads[0].stored)
        XCTAssertFalse(defaults.primaryReads[0].isTampered)
        XCTAssertTrue(defaults.primaryReads[1].isTampered)
        XCTAssertEqual(defaults.primaryWrites, 1)
        XCTAssertEqual(defaults.primaryRemovals, 1)
        XCTAssertNil(defaults.data(forKey: "snapshot"))
        XCTAssertNil(store.loadSnapshot())
        XCTAssertNil(store.loadState())
    }

    /// An untrusted primary is not a recovery source, so the same failed readback
    /// must delete it even though the readback returned non-nil bytes that differ
    /// from what was written.
    func testFailedReadbackOverUntrustedPrimaryDeletesPrimary() throws {
        let (defaults, suiteName) = makeTamperer()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SnapshotStore(defaults: defaults, key: "snapshot")
        let untrustedPrimary = Data("not a persisted app state".utf8)
        defaults.set(untrustedPrimary, forKey: "snapshot")

        defaults.armReadbackTamper(returning: Data("still not the written bytes".utf8))
        XCTAssertFalse(store.saveState(realState(weekly: 80)))

        XCTAssertEqual(defaults.primaryReads.count, 2)
        XCTAssertEqual(defaults.primaryReads[0].stored, untrustedPrimary)
        XCTAssertFalse(defaults.primaryReads[0].isTampered)
        XCTAssertTrue(defaults.primaryReads[1].isTampered)
        XCTAssertEqual(defaults.primaryWrites, 1)
        XCTAssertEqual(defaults.primaryRemovals, 1)
        XCTAssertNil(defaults.data(forKey: "snapshot"))
        XCTAssertNil(store.loadState())
    }

    /// `loadState` migrates a raw legacy primary through `saveStateUnlocked`.
    /// When that migration write cannot be read back, the unverified envelope
    /// must be replaced by the legacy bytes the store started from.
    func testFailedReadbackDuringLegacyPrimaryMigrationRestoresLegacyBytes() throws {
        let (defaults, suiteName) = makeTamperer()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let legacy = QuotaSnapshot(
            weeklyQuotaPercent: 80,
            fiveHourQuotaPercent: 60,
            refreshedAt: Date(timeIntervalSince1970: 100),
            dataSource: .real,
            schemaVersion: 1
        )
        let legacyBytes = try JSONEncoder().encode(legacy)
        defaults.set(legacyBytes, forKey: "snapshot")

        let store = SnapshotStore(defaults: defaults, key: "snapshot")
        defaults.armReadbackTamper(returning: nil)
        let loaded = try XCTUnwrap(store.loadState())

        // The decoded state is still returned, but the migration write was not
        // committed: the legacy datum is back on disk.
        XCTAssertEqual(loaded.snapshot.weeklyQuotaPercent, 80)
        XCTAssertEqual(loaded.snapshot.schemaVersion, QuotaSnapshot.currentSchemaVersion)
        XCTAssertEqual(defaults.primaryReads.count, 3)
        XCTAssertEqual(defaults.primaryReads[0].stored, legacyBytes)
        XCTAssertFalse(defaults.primaryReads[0].isTampered)
        XCTAssertEqual(defaults.primaryReads[1].stored, legacyBytes)
        XCTAssertFalse(defaults.primaryReads[1].isTampered)
        XCTAssertTrue(defaults.primaryReads[2].isTampered)
        XCTAssertEqual(defaults.primaryWrites, 2)
        XCTAssertEqual(defaults.primaryRemovals, 0)
        let rolledBack = try XCTUnwrap(defaults.data(forKey: "snapshot"))
        XCTAssertEqual(rolledBack, legacyBytes)
        XCTAssertEqual(try JSONDecoder().decode(QuotaSnapshot.self, from: rolledBack).schemaVersion, 1)
    }

    /// An envelope whose payload declares an older snapshot schema routes
    /// `loadState` through `migratePersistedStateIfNeeded` into
    /// `saveStateUnlocked`. A failed readback there restores the pre-migration
    /// envelope instead of leaving the unverified rewrite in place.
    func testFailedReadbackDuringEnvelopeSchemaMigrationRestoresOriginalEnvelope() throws {
        let (defaults, suiteName) = makeTamperer()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let oldState = PersistedAppState(
            snapshot: QuotaSnapshot(
                weeklyQuotaPercent: 80,
                fiveHourQuotaPercent: 60,
                refreshedAt: Date(timeIntervalSince1970: 100),
                dataSource: .real,
                schemaVersion: 1,
                accountBoundary: .testDefault
            ),
            status: .success,
            lastSuccessAt: Date(timeIntervalSince1970: 100),
            lastAttemptAt: nil,
            failureCount: 0
        )
        let originalEnvelope = try JSONEncoder().encode(PersistenceEnvelope(value: oldState, revision: 1))
        defaults.set(originalEnvelope, forKey: "snapshot")

        let store = SnapshotStore(defaults: defaults, key: "snapshot")
        defaults.armReadbackTamper(returning: Data("unrelated readback bytes".utf8))
        let loaded = try XCTUnwrap(store.loadState())

        XCTAssertEqual(loaded.snapshot.weeklyQuotaPercent, 80)
        XCTAssertEqual(loaded.snapshot.schemaVersion, QuotaSnapshot.currentSchemaVersion)
        XCTAssertEqual(defaults.primaryReads.count, 3)
        XCTAssertEqual(defaults.primaryReads[0].stored, originalEnvelope)
        XCTAssertFalse(defaults.primaryReads[0].isTampered)
        XCTAssertEqual(defaults.primaryReads[1].stored, originalEnvelope)
        XCTAssertFalse(defaults.primaryReads[1].isTampered)
        XCTAssertTrue(defaults.primaryReads[2].isTampered)
        XCTAssertEqual(defaults.primaryWrites, 2)
        XCTAssertEqual(defaults.primaryRemovals, 0)
        XCTAssertEqual(defaults.data(forKey: "snapshot"), originalEnvelope)
    }
}

/// Deterministic fault injection for `SnapshotStore`'s post-write readback.
///
/// `saveState` and `saveStateUnlocked` audit the existing primary first and then
/// verify the bytes they just wrote by reading the key back. Both of those reads
/// go through `data(forKey:)`, so the tamper fires only on the first primary read
/// that follows a primary write after `armReadbackTamper(returning:)`, and only
/// once: the audit read before the write, every read of another key (notably the
/// backup verification readback), and every read after the tampered one stay
/// truthful. That is the only observable state a failing `UserDefaults` can be in
/// and the only way to reach the rollback branch that restores the trusted bytes
/// or deletes the primary.
private final class SnapshotStoreReadbackTamperer: UserDefaults {
    struct PrimaryRead {
        let stored: Data?
        let returned: Data?
        let isTampered: Bool
    }

    /// The store's primary key. Reads and writes of every other key pass through.
    var primaryKey = ""

    private(set) var primaryReads: [PrimaryRead] = []
    private(set) var primaryWrites = 0
    private(set) var primaryRemovals = 0

    private var isTamperArmed = false
    private var isReadbackPending = false
    private var tamperedValue: Data?

    /// Makes the next post-write primary read return `value` instead of the stored
    /// bytes, exactly once. `nil` models a read that comes back empty. Read,
    /// write, and removal counters restart so the exercised call can be asserted
    /// on its own.
    func armReadbackTamper(returning value: Data?) {
        primaryReads.removeAll()
        primaryWrites = 0
        primaryRemovals = 0
        tamperedValue = value
        isReadbackPending = false
        isTamperArmed = true
    }

    /// `UserDefaults.removeObject(forKey:)` routes through `set(nil, forKey:)`,
    /// so only a non-nil store counts as a write; removals are tracked apart from
    /// it. A removal also must not arm the readback tamper.
    override func set(_ value: Any?, forKey defaultName: String) {
        if defaultName == primaryKey, value != nil {
            primaryWrites += 1
            if isTamperArmed { isReadbackPending = true }
        }
        super.set(value, forKey: defaultName)
    }

    override func removeObject(forKey defaultName: String) {
        if defaultName == primaryKey { primaryRemovals += 1 }
        super.removeObject(forKey: defaultName)
    }

    override func data(forKey defaultName: String) -> Data? {
        let stored = super.data(forKey: defaultName)
        guard defaultName == primaryKey else { return stored }
        guard isReadbackPending else {
            primaryReads.append(PrimaryRead(stored: stored, returned: stored, isTampered: false))
            return stored
        }
        isReadbackPending = false
        isTamperArmed = false
        primaryReads.append(PrimaryRead(stored: stored, returned: tamperedValue, isTampered: true))
        return tamperedValue
    }
}
