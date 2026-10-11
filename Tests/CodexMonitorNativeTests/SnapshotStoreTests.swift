import XCTest
@testable import CodexMonitorNative

final class SnapshotStoreTests: XCTestCase {
    private func makeDefaults() -> (defaults: UserDefaults, suiteName: String) {
        let suiteName = "SnapshotStoreTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suiteName)!, suiteName)
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
    /// revision, trust, account-boundary, and newer-version decisions.
    func testWarmCommitValidatesPrimaryExactlyOnce() throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SnapshotStore(defaults: defaults, key: "snapshot")

        XCTAssertTrue(store.saveState(realState(weekly: 90)))

        let before = SnapshotStore.debugPersistenceDecodeCount
        XCTAssertTrue(store.saveState(realState(weekly: 80)))
        let decodes = SnapshotStore.debugPersistenceDecodeCount - before

        // One audit (envelope + payload + the raw-snapshot probe every datum
        // needs) and one write readback (envelope + payload). The pre-change
        // commit spent ten decodes on the same commit.
        XCTAssertEqual(decodes, 6)
        XCTAssertEqual(store.loadSnapshot()?.weeklyQuotaPercent, 80)
    }

    /// The raw-snapshot probe runs for every datum, including one that also
    /// decodes as a valid envelope, so a hybrid shape that declares a newer raw
    /// schema is still refused exactly as `containsNewerPersistenceVersion` did.
    func testSaveStillRefusesFutureRawSnapshotHiddenInsideCurrentEnvelope() throws {        let (defaults, suiteName) = makeDefaults()
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
}
