import Darwin
import XCTest
@testable import CodexMonitorNative

@MainActor
final class SingleInstanceCoordinatorTests: XCTestCase {
    func testSecondaryForwardsActivationWithoutTakingOwnership() async throws {
        let fixture = makeFixture()
        defer { fixture.remove() }
        let ownerRecorder = SingleInstanceActivationRecorder()
        let secondaryRecorder = SingleInstanceActivationRecorder()
        let owner = SingleInstanceCoordinator(configuration: fixture.configuration)
        defer { owner.release() }

        XCTAssertEqual(
            owner.claim(using: .immediate { ownerRecorder.record($0) }),
            .owner
        )
        let before = try XCTUnwrap(readOwnerRecord(at: fixture.ownerURL))

        let secondary = SingleInstanceCoordinator(configuration: fixture.configuration)
        XCTAssertEqual(
            secondary.claim(using: .immediate { secondaryRecorder.record($0) }),
            .secondary(forwardedActivation: true)
        )
        await Task.yield()

        XCTAssertEqual(ownerRecorder.actions, [.showPopover])
        XCTAssertTrue(secondaryRecorder.actions.isEmpty)
        let after = try XCTUnwrap(readOwnerRecord(at: fixture.ownerURL))
        XCTAssertEqual(after.instanceID, before.instanceID)
        XCTAssertEqual(after.pid, before.pid)
        XCTAssertEqual(after.activationCount, before.activationCount + 1)
    }

    func testMultipleSecondaryLaunchesAreAcknowledgedByOneOwner() async throws {
        let fixture = makeFixture()
        defer { fixture.remove() }
        let recorder = SingleInstanceActivationRecorder()
        let owner = SingleInstanceCoordinator(configuration: fixture.configuration)
        defer { owner.release() }
        XCTAssertEqual(owner.claim(using: .immediate { recorder.record($0) }), .owner)

        for _ in 0..<8 {
            let secondary = SingleInstanceCoordinator(configuration: fixture.configuration)
            XCTAssertEqual(
                secondary.claim(using: .immediate { _ in
                    XCTFail("A secondary instance handled an owner action")
                    return false
                }),
                .secondary(forwardedActivation: true)
            )
        }
        for _ in 0..<8 { await Task.yield() }

        XCTAssertEqual(recorder.actions, Array(repeating: .showPopover, count: 8))
        XCTAssertEqual(readOwnerRecord(at: fixture.ownerURL)?.activationCount, 8)
    }

    func testReleaseKeepsPermanentLockFileAndAllowsSuccessor() throws {
        let fixture = makeFixture()
        defer { fixture.remove() }
        let first = SingleInstanceCoordinator(configuration: fixture.configuration)
        XCTAssertEqual(first.claim(using: .immediate { _ in true }), .owner)
        let firstID = try XCTUnwrap(readOwnerRecord(at: fixture.ownerURL)?.instanceID)
        let initialLockIdentity = try lockIdentity(at: fixture.lockURL)

        first.release()

        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.lockURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.ownerURL.path))
        XCTAssertEqual(try lockIdentity(at: fixture.lockURL), initialLockIdentity)

        let successor = SingleInstanceCoordinator(configuration: fixture.configuration)
        defer { successor.release() }
        XCTAssertEqual(successor.claim(using: .immediate { _ in true }), .owner)
        let successorID = try XCTUnwrap(readOwnerRecord(at: fixture.ownerURL)?.instanceID)
        XCTAssertNotEqual(successorID, firstID)
        XCTAssertEqual(try lockIdentity(at: fixture.lockURL), initialLockIdentity)
    }

    func testContendedLockWithoutReadyOwnerFailsClosed() throws {
        let fixture = makeFixture(
            ownerReadyTimeout: .milliseconds(40),
            acknowledgementTimeout: .milliseconds(40)
        )
        defer { fixture.remove() }
        try fixture.prepareDirectories()
        let descriptor = Darwin.open(
            fixture.lockURL.path,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            mode_t(S_IRUSR | S_IWUSR)
        )
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        guard descriptor >= 0 else { return }
        defer { Darwin.close(descriptor) }
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)

        let contender = SingleInstanceCoordinator(configuration: fixture.configuration)
        XCTAssertEqual(
            contender.claim(using: .immediate { _ in
                XCTFail("A contender without ownership handled activation")
                return false
            }),
            .secondary(forwardedActivation: false)
        )
        XCTAssertNil(readOwnerRecord(at: fixture.ownerURL))
    }

    func testStaleMalformedMetadataCannotPreventTakingReleasedLock() throws {
        let fixture = makeFixture()
        defer { fixture.remove() }
        try fixture.prepareDirectories()
        try Data("not-json".utf8).write(to: fixture.ownerURL, options: .atomic)

        let coordinator = SingleInstanceCoordinator(configuration: fixture.configuration)
        defer { coordinator.release() }
        XCTAssertEqual(coordinator.claim(using: .immediate { _ in true }), .owner)

        let record = try XCTUnwrap(readOwnerRecord(at: fixture.ownerURL))
        XCTAssertEqual(record.protocolVersion, SingleInstanceOwnerRecord.currentProtocolVersion)
        XCTAssertEqual(record.activationCount, 0)
    }

    func testOwnerStopsAcknowledgingBeforeBusinessShutdownAndLaterReleasesOwnership() throws {
        let fixture = makeFixture(
            ownerReadyTimeout: .milliseconds(40),
            acknowledgementTimeout: .milliseconds(40)
        )
        defer { fixture.remove() }
        let ownerRecorder = SingleInstanceActivationRecorder()
        let owner = SingleInstanceCoordinator(configuration: fixture.configuration)
        XCTAssertEqual(owner.claim(using: .immediate { ownerRecorder.record($0) }), .owner)
        owner.prepareForShutdown()

        let contender = SingleInstanceCoordinator(configuration: fixture.configuration)
        XCTAssertEqual(
            contender.claim(using: .immediate { _ in
                XCTFail("A shutting-down owner transferred activation")
                return false
            }),
            .secondary(forwardedActivation: false)
        )
        XCTAssertTrue(ownerRecorder.actions.isEmpty)

        owner.release()
        XCTAssertEqual(contender.claim(using: .immediate { _ in true }), .owner)
        contender.release()
    }

    func testNewOwnerRemovesAbandonedTemporaryMailboxFiles() throws {
        let fixture = makeFixture()
        defer { fixture.remove() }
        try fixture.prepareDirectories()
        let requestTemporaryURL = fixture.rootURL
            .appendingPathComponent("requests", isDirectory: true)
            .appendingPathComponent(".tmp-abandoned-request")
        let acknowledgementTemporaryURL = fixture.rootURL
            .appendingPathComponent("acknowledgements", isDirectory: true)
            .appendingPathComponent(".tmp-abandoned-acknowledgement")
        XCTAssertTrue(FileManager.default.createFile(atPath: requestTemporaryURL.path, contents: Data()))
        XCTAssertTrue(FileManager.default.createFile(atPath: acknowledgementTemporaryURL.path, contents: Data()))

        let coordinator = SingleInstanceCoordinator(configuration: fixture.configuration)
        defer { coordinator.release() }
        XCTAssertEqual(coordinator.claim(using: .immediate { _ in true }), .owner)

        XCTAssertFalse(FileManager.default.fileExists(atPath: requestTemporaryURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: acknowledgementTemporaryURL.path))
    }

    func testOwnerAcceptsEarliestV1RequestShapeWithoutExpiresAt() throws {
        let fixture = makeFixture()
        defer { fixture.remove() }
        let recorder = SingleInstanceActivationRecorder()
        let owner = SingleInstanceCoordinator(configuration: fixture.configuration)
        defer { owner.release() }
        XCTAssertEqual(owner.claim(using: .immediate { recorder.record($0) }), .owner)
        let ownerID = try XCTUnwrap(readOwnerRecord(at: fixture.ownerURL)?.instanceID)
        let requestID = UUID()
        let createdAt = Date()
        let requestObject: [String: Any] = [
            "protocolVersion": SingleInstanceOwnerRecord.currentProtocolVersion,
            "targetInstanceID": ownerID.uuidString,
            "requestID": requestID.uuidString,
            "action": SingleInstanceActivationAction.showPopover.rawValue,
            "createdAt": createdAt.timeIntervalSince1970 * 1_000
        ]
        let data = try JSONSerialization.data(withJSONObject: requestObject, options: [.sortedKeys])
        try data.write(to: fixture.requestURL(for: requestID), options: .atomic)

        XCTAssertEqual(recorder.wait(until: .now() + .seconds(1)), .success)
        XCTAssertEqual(recorder.actions, [.showPopover])
    }

    func testExpiredRequestIsRemovedWithoutLateActivation() throws {
        let fixture = makeFixture()
        defer { fixture.remove() }
        let recorder = SingleInstanceActivationRecorder()
        let owner = SingleInstanceCoordinator(configuration: fixture.configuration)
        defer { owner.release() }
        XCTAssertEqual(owner.claim(using: .immediate { recorder.record($0) }), .owner)
        let ownerID = try XCTUnwrap(readOwnerRecord(at: fixture.ownerURL)?.instanceID)
        let requestID = UUID()
        let requestURL = fixture.requestURL(for: requestID)
        let requestObject: [String: Any] = [
            "protocolVersion": SingleInstanceOwnerRecord.currentProtocolVersion,
            "targetInstanceID": ownerID.uuidString,
            "requestID": requestID.uuidString,
            "action": SingleInstanceActivationAction.showPopover.rawValue,
            "createdAt": Date().addingTimeInterval(-10).timeIntervalSince1970 * 1_000,
            "expiresAt": Date().addingTimeInterval(-5).timeIntervalSince1970 * 1_000
        ]
        let data = try JSONSerialization.data(withJSONObject: requestObject, options: [.sortedKeys])
        try data.write(to: requestURL, options: .atomic)

        XCTAssertEqual(recorder.wait(until: .now() + .milliseconds(100)), .timedOut)
        XCTAssertTrue(recorder.actions.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: requestURL.path))
    }

    func testSymlinkAtPermanentLockPathFailsClosed() throws {
        let fixture = makeFixture()
        defer { fixture.remove() }
        try fixture.prepareDirectories()
        let targetURL = fixture.rootURL.appendingPathComponent("untrusted-target")
        XCTAssertTrue(FileManager.default.createFile(atPath: targetURL.path, contents: Data()))
        XCTAssertEqual(Darwin.symlink(targetURL.path, fixture.lockURL.path), 0)

        let coordinator = SingleInstanceCoordinator(configuration: fixture.configuration)
        let result = coordinator.claim(using: .immediate { _ in
            XCTFail("Unsafe lock path became owner")
            return false
        })
        guard case .failed(let reason) = result else {
            return XCTFail("Expected a fail-closed result, got \(result)")
        }
        XCTAssertTrue(reason.contains("owner.lock"))
    }

    private func makeFixture(
        ownerReadyTimeout: DispatchTimeInterval = .milliseconds(200),
        acknowledgementTimeout: DispatchTimeInterval = .milliseconds(500)
    ) -> SingleInstanceFixture {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexMonitorNativeTests.singleInstance.\(UUID().uuidString)", isDirectory: true)
        return SingleInstanceFixture(
            rootURL: rootURL,
            configuration: SingleInstanceConfiguration(
                namespaceURL: rootURL,
                ownerReadyTimeout: ownerReadyTimeout,
                acknowledgementTimeout: acknowledgementTimeout
            )
        )
    }

    private func readOwnerRecord(at url: URL) -> SingleInstanceOwnerRecord? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try? decoder.decode(SingleInstanceOwnerRecord.self, from: data)
    }

    private func lockIdentity(at url: URL) throws -> SingleInstanceLockIdentity {
        var metadata = stat()
        guard Darwin.lstat(url.path, &metadata) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return SingleInstanceLockIdentity(device: metadata.st_dev, inode: metadata.st_ino)
    }
}

private final class SingleInstanceActivationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let signal = DispatchSemaphore(value: 0)
    private var recordedActions: [SingleInstanceActivationAction] = []

    var actions: [SingleInstanceActivationAction] {
        lock.lock()
        defer { lock.unlock() }
        return recordedActions
    }

    func record(_ action: SingleInstanceActivationAction) -> Bool {
        lock.lock()
        recordedActions.append(action)
        lock.unlock()
        signal.signal()
        return true
    }

    func wait(until deadline: DispatchTime) -> DispatchTimeoutResult {
        signal.wait(timeout: deadline)
    }
}

private struct SingleInstanceFixture {
    let rootURL: URL
    let configuration: SingleInstanceConfiguration

    var lockURL: URL { rootURL.appendingPathComponent("owner.lock") }
    var ownerURL: URL { rootURL.appendingPathComponent("owner.json") }

    func requestURL(for requestID: UUID) -> URL {
        rootURL
            .appendingPathComponent("requests", isDirectory: true)
            .appendingPathComponent("request-\(requestID.uuidString).json")
    }

    func prepareDirectories() throws {
        try FileManager.default.createDirectory(
            at: rootURL.appendingPathComponent("requests", isDirectory: true),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.createDirectory(
            at: rootURL.appendingPathComponent("acknowledgements", isDirectory: true),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: rootURL.path)
    }

    func remove() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}

private struct SingleInstanceLockIdentity: Equatable {
    let device: dev_t
    let inode: ino_t
}
