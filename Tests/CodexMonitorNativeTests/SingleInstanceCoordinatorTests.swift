import Darwin
import XCTest
@testable import CodexMonitorNative

@MainActor
final class SingleInstanceCoordinatorTests: XCTestCase {
    func testApprovedIdentityBoundHandoffMakesClaimantTheVerifiedOwner() throws {
        let fixture = makeFixture()
        defer { fixture.remove() }
        let oldIdentity = installationIdentity(
            path: "/Users/test/Downloads/CodexMonitorNative.app",
            digest: "old"
        )
        let preferredIdentity = installationIdentity(
            path: "/Applications/CodexMonitorNative.app",
            digest: "preferred"
        )
        let owner = SingleInstanceCoordinator(configuration: fixture.configuration)
        defer { owner.release() }
        let claimant = SingleInstanceCoordinator(configuration: fixture.configuration)
        defer { claimant.release() }
        let handoffRecorder = SingleInstanceHandoffRecorder()

        XCTAssertEqual(
            owner.claim(
                using: .immediate(
                    { _ in true },
                    shouldRelinquish: { $0 == preferredIdentity },
                    commitRelinquishment: {
                        handoffRecorder.recordCommit()
                        return true
                    },
                    didRelinquish: {
                        handoffRecorder.recordRelinquished()
                    }
                ),
                installationIdentity: oldIdentity
            ),
            .owner
        )

        XCTAssertEqual(
            claimant.claim(
                using: .immediate { _ in true },
                installationIdentity: preferredIdentity
            ),
            .owner
        )

        XCTAssertTrue(handoffRecorder.committed)
        XCTAssertTrue(handoffRecorder.relinquished)
        XCTAssertEqual(readOwnerRecord(at: fixture.ownerURL)?.installationIdentity, preferredIdentity)
        XCTAssertEqual(claimant.stableOwnerRecordHoldingLock()?.installationIdentity, preferredIdentity)
    }

    func testApprovedHandoffCommitCanCompleteAfterRequestDeadline() throws {
        let fixture = makeFixture(
            acknowledgementTimeout: .seconds(1),
            handoffCompletionTimeout: .seconds(5)
        )
        defer { fixture.remove() }
        let oldIdentity = installationIdentity(
            path: "/Users/test/Downloads/CodexMonitorNative.app",
            digest: "old"
        )
        let preferredIdentity = installationIdentity(
            path: "/Applications/CodexMonitorNative.app",
            digest: "preferred"
        )
        let handoffRecorder = SingleInstanceHandoffRecorder()
        let ownerExecutor = SingleInstanceActivationExecutor(
            submitAction: { _, expiresAt, completion in
                completion(expiresAt > .now)
            },
            submitRelinquishment: { identity, expiresAt, completion in
                handoffRecorder.recordRequestDeadline(expiresAt)
                completion(expiresAt > .now && identity == preferredIdentity)
            },
            commitRelinquishment: { expiresAt, begin, completion in
                guard expiresAt > .now, begin() else {
                    completion(false)
                    return
                }
                handoffRecorder.recordCommit()
                let requestDeadline = handoffRecorder.requestDeadline ?? .now
                let completionDelayNanoseconds = max(
                    0,
                    Int(
                        requestDeadline
                            .addingTimeInterval(0.2)
                            .timeIntervalSinceNow * 1_000_000_000
                    )
                )
                DispatchQueue.global(qos: .userInitiated).asyncAfter(
                    deadline: .now() + .nanoseconds(completionDelayNanoseconds)
                ) {
                    completion(expiresAt > .now)
                }
            },
            notifyRelinquished: {
                handoffRecorder.recordRelinquished()
            }
        )
        let owner = SingleInstanceCoordinator(configuration: fixture.configuration)
        defer { owner.release() }
        XCTAssertEqual(
            owner.claim(using: ownerExecutor, installationIdentity: oldIdentity),
            .owner
        )

        let claimant = SingleInstanceCoordinator(configuration: fixture.configuration)
        defer { claimant.release() }
        XCTAssertEqual(
            claimant.claim(
                using: .immediate { _ in true },
                installationIdentity: preferredIdentity
            ),
            .owner
        )

        XCTAssertTrue(handoffRecorder.committed)
        XCTAssertTrue(handoffRecorder.relinquished)
        XCTAssertEqual(readOwnerRecord(at: fixture.ownerURL)?.installationIdentity, preferredIdentity)
    }

    func testCommitCallbackAfterHandoffDeadlineKeepsClaimantAuthoritative() throws {
        let fixture = makeFixture(
            acknowledgementTimeout: .milliseconds(300),
            handoffCompletionTimeout: .milliseconds(80)
        )
        defer { fixture.remove() }
        let oldIdentity = installationIdentity(
            path: "/Users/test/Downloads/CodexMonitorNative.app",
            digest: "old"
        )
        let preferredIdentity = installationIdentity(
            path: "/Applications/CodexMonitorNative.app",
            digest: "preferred"
        )
        let recorder = SingleInstanceHandoffRecorder()
        let ownerExecutor = SingleInstanceActivationExecutor(
            submitAction: { _, _, completion in completion(true) },
            submitRelinquishment: { identity, _, completion in
                completion(identity == preferredIdentity)
            },
            commitRelinquishment: { _, begin, completion in
                guard begin() else {
                    completion(false)
                    return
                }
                recorder.recordCommit()
                DispatchQueue.global(qos: .userInitiated).asyncAfter(
                    deadline: .now() + .milliseconds(180)
                ) {
                    completion(true)
                }
            },
            notifyRelinquished: {
                recorder.recordRelinquished()
            }
        )
        let owner = SingleInstanceCoordinator(configuration: fixture.configuration)
        defer { owner.release() }
        XCTAssertEqual(owner.claim(using: ownerExecutor, installationIdentity: oldIdentity), .owner)

        let claimant = SingleInstanceCoordinator(configuration: fixture.configuration)
        defer { claimant.release() }
        XCTAssertEqual(
            claimant.claim(
                using: .immediate { _ in true },
                installationIdentity: preferredIdentity
            ),
            .owner
        )

        XCTAssertTrue(recorder.committed)
        XCTAssertEqual(readOwnerRecord(at: fixture.ownerURL)?.installationIdentity, preferredIdentity)
        XCTAssertEqual(claimant.stableOwnerRecordHoldingLock()?.installationIdentity, preferredIdentity)
        XCTAssertEqual(recorder.waitForRelinquishment(until: .now() + .seconds(1)), .success)
        XCTAssertTrue(recorder.relinquished)
        XCTAssertEqual(claimant.stableOwnerRecordHoldingLock()?.installationIdentity, preferredIdentity)
    }

    func testAbandonedAuthorizedClaimantRestoresOwnerAndLaterClaimantCanTakeOver() throws {
        let fixture = makeFixture(
            acknowledgementTimeout: .milliseconds(300),
            handoffCompletionTimeout: .milliseconds(80)
        )
        defer { fixture.remove() }
        let oldIdentity = installationIdentity(
            path: "/Users/test/Downloads/CodexMonitorNative.app",
            digest: "old"
        )
        let preferredIdentity = installationIdentity(
            path: "/Applications/CodexMonitorNative.app",
            digest: "preferred"
        )
        let recorder = SingleInstanceHandoffRecorder()
        let owner = SingleInstanceCoordinator(configuration: fixture.configuration)
        defer { owner.release() }
        XCTAssertEqual(
            owner.claim(
                using: .immediate(
                    { _ in true },
                    shouldRelinquish: { $0 == preferredIdentity },
                    commitRelinquishment: {
                        recorder.recordCommit()
                        return true
                    },
                    didRelinquish: {
                        recorder.recordRelinquished()
                    }
                ),
                installationIdentity: oldIdentity
            ),
            .owner
        )
        let ownerID = try XCTUnwrap(readOwnerRecord(at: fixture.ownerURL)?.instanceID)
        let abandonedRequestID = UUID()
        let abandonedProcess = Process()
        abandonedProcess.executableURL = URL(fileURLWithPath: "/bin/sleep")
        abandonedProcess.arguments = ["5"]
        try abandonedProcess.run()
        defer {
            if abandonedProcess.isRunning {
                abandonedProcess.terminate()
            }
        }
        let abandonedProcessIdentity = try XCTUnwrap(
            SingleInstanceProcessIdentity.read(
                processID: abandonedProcess.processIdentifier
            )
        )
        try writeHandoffRequest(
            requestID: abandonedRequestID,
            ownerInstanceID: ownerID,
            installationIdentity: preferredIdentity,
            processIdentity: abandonedProcessIdentity,
            to: fixture.requestURL(for: abandonedRequestID)
        )

        XCTAssertTrue(waitUntil(timeout: 1) {
            FileManager.default.fileExists(atPath: fixture.acknowledgementURL(for: abandonedRequestID).path)
        })
        XCTAssertEqual(
            acknowledgementAccepted(at: fixture.acknowledgementURL(for: abandonedRequestID)),
            true
        )
        abandonedProcess.terminate()
        abandonedProcess.waitUntilExit()
        XCTAssertTrue(waitUntil(timeout: 1) {
            owner.stableOwnerRecordHoldingLock()?.instanceID == ownerID
                && !FileManager.default.fileExists(atPath: fixture.handoffURL.path)
        })
        XCTAssertFalse(recorder.committed)
        XCTAssertFalse(recorder.relinquished)
        XCTAssertEqual(readOwnerRecord(at: fixture.ownerURL)?.installationIdentity, oldIdentity)

        let laterClaimant = SingleInstanceCoordinator(configuration: fixture.configuration)
        defer { laterClaimant.release() }
        XCTAssertEqual(
            laterClaimant.claim(
                using: .immediate { _ in true },
                installationIdentity: preferredIdentity
            ),
            .owner
        )
        XCTAssertTrue(recorder.committed)
        XCTAssertTrue(recorder.relinquished)
        XCTAssertEqual(laterClaimant.stableOwnerRecordHoldingLock()?.installationIdentity, preferredIdentity)
    }

    func testExitedKernelProcessIdentityCannotAuthorizeHandoff() throws {
        let fixture = makeFixture()
        defer { fixture.remove() }
        let oldIdentity = installationIdentity(
            path: "/Users/test/Downloads/CodexMonitorNative.app",
            digest: "old"
        )
        let preferredIdentity = installationIdentity(
            path: "/Applications/CodexMonitorNative.app",
            digest: "preferred"
        )
        let recorder = SingleInstanceHandoffRecorder()
        let owner = SingleInstanceCoordinator(configuration: fixture.configuration)
        defer { owner.release() }
        XCTAssertEqual(
            owner.claim(
                using: .immediate(
                    { _ in true },
                    shouldRelinquish: { $0 == preferredIdentity },
                    commitRelinquishment: {
                        recorder.recordCommit()
                        return true
                    }
                ),
                installationIdentity: oldIdentity
            ),
            .owner
        )
        let ownerID = try XCTUnwrap(readOwnerRecord(at: fixture.ownerURL)?.instanceID)

        let exitedProcess = Process()
        exitedProcess.executableURL = URL(fileURLWithPath: "/bin/sleep")
        exitedProcess.arguments = ["5"]
        try exitedProcess.run()
        let exitedIdentity = try XCTUnwrap(
            SingleInstanceProcessIdentity.read(processID: exitedProcess.processIdentifier)
        )
        exitedProcess.terminate()
        exitedProcess.waitUntilExit()

        let requestID = UUID()
        try writeHandoffRequest(
            requestID: requestID,
            ownerInstanceID: ownerID,
            installationIdentity: preferredIdentity,
            processIdentity: exitedIdentity,
            to: fixture.requestURL(for: requestID)
        )
        XCTAssertTrue(waitUntil(timeout: 1) {
            FileManager.default.fileExists(atPath: fixture.acknowledgementURL(for: requestID).path)
        })
        XCTAssertEqual(
            acknowledgementAccepted(at: fixture.acknowledgementURL(for: requestID)),
            false
        )

        XCTAssertFalse(recorder.committed)
        XCTAssertEqual(owner.stableOwnerRecordHoldingLock()?.instanceID, ownerID)
        XCTAssertEqual(readOwnerRecord(at: fixture.ownerURL)?.installationIdentity, oldIdentity)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.handoffURL.path))
    }

    func testClaimantExitingDuringRelinquishmentAuthorizationIsRejectedBeforeUnlock() throws {
        let fixture = makeFixture(
            acknowledgementTimeout: .seconds(1),
            handoffCompletionTimeout: .milliseconds(200)
        )
        defer { fixture.remove() }
        let oldIdentity = installationIdentity(
            path: "/Users/test/Downloads/CodexMonitorNative.app",
            digest: "old"
        )
        let preferredIdentity = installationIdentity(
            path: "/Applications/CodexMonitorNative.app",
            digest: "preferred"
        )
        let activationRecorder = SingleInstanceActivationRecorder()
        let handoffRecorder = SingleInstanceHandoffRecorder()
        let authorization = SingleInstanceRelinquishmentAuthorizationHarness()
        let ownerExecutor = SingleInstanceActivationExecutor(
            submitAction: { action, expiresAt, completion in
                completion(expiresAt > .now && activationRecorder.record(action))
            },
            submitRelinquishment: { identity, _, completion in
                XCTAssertEqual(identity, preferredIdentity)
                authorization.capture(completion)
            },
            commitRelinquishment: { _, begin, completion in
                handoffRecorder.recordCommit()
                completion(begin())
            },
            notifyRelinquished: {
                handoffRecorder.recordRelinquished()
            }
        )
        let owner = SingleInstanceCoordinator(configuration: fixture.configuration)
        defer { owner.release() }
        XCTAssertEqual(owner.claim(using: ownerExecutor, installationIdentity: oldIdentity), .owner)
        let ownerID = try XCTUnwrap(readOwnerRecord(at: fixture.ownerURL)?.instanceID)

        let claimantProcess = Process()
        claimantProcess.executableURL = URL(fileURLWithPath: "/bin/sleep")
        claimantProcess.arguments = ["5"]
        try claimantProcess.run()
        defer {
            if claimantProcess.isRunning {
                claimantProcess.terminate()
            }
        }
        let claimantProcessIdentity = try XCTUnwrap(
            SingleInstanceProcessIdentity.read(processID: claimantProcess.processIdentifier)
        )
        let requestID = UUID()
        try writeHandoffRequest(
            requestID: requestID,
            ownerInstanceID: ownerID,
            installationIdentity: preferredIdentity,
            processIdentity: claimantProcessIdentity,
            requestLifetime: 1,
            to: fixture.requestURL(for: requestID)
        )
        XCTAssertEqual(authorization.waitUntilCaptured(until: .now() + .seconds(1)), .success)

        claimantProcess.terminate()
        claimantProcess.waitUntilExit()
        authorization.complete(accepted: true)

        XCTAssertTrue(waitUntil(timeout: 1) {
            acknowledgementAccepted(at: fixture.acknowledgementURL(for: requestID)) == false
        })
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.handoffURL.path))
        XCTAssertEqual(owner.stableOwnerRecordHoldingLock()?.instanceID, ownerID)
        XCTAssertEqual(readOwnerRecord(at: fixture.ownerURL)?.installationIdentity, oldIdentity)
        XCTAssertEqual(handoffRecorder.commitCount, 0)
        XCTAssertEqual(handoffRecorder.relinquishmentCount, 0)

        let secondary = SingleInstanceCoordinator(configuration: fixture.configuration)
        XCTAssertEqual(
            secondary.claim(using: .immediate { _ in true }),
            .secondary(forwardedActivation: true)
        )
        XCTAssertEqual(activationRecorder.actions, [.showPopover])
        XCTAssertEqual(owner.stableOwnerRecordHoldingLock()?.instanceID, ownerID)
    }

    func testProvisionalRecordLockProbeSandwichRejectsThirdContenderRace() throws {
        let fixture = makeFixture(
            acknowledgementTimeout: .milliseconds(300),
            handoffCompletionTimeout: .milliseconds(150)
        )
        defer { fixture.remove() }
        let oldIdentity = installationIdentity(
            path: "/Users/test/Downloads/CodexMonitorNative.app",
            digest: "old"
        )
        let preferredIdentity = installationIdentity(
            path: "/Applications/CodexMonitorNative.app",
            digest: "preferred"
        )
        let recorder = SingleInstanceHandoffRecorder()
        let race = SingleInstanceVerificationRaceHarness(
            ownerURL: fixture.ownerURL,
            lockURL: fixture.lockURL
        )
        let owner = SingleInstanceCoordinator(
            configuration: fixture.configuration,
            handoffVerificationObserver: { event in
                guard event == .didReadCandidateBeforeLockProbe else { return }
                race.interposeAfterCandidateRead()
            }
        )
        defer { owner.release() }
        XCTAssertEqual(
            owner.claim(
                using: .immediate(
                    { _ in true },
                    shouldRelinquish: { $0 == preferredIdentity },
                    commitRelinquishment: {
                        recorder.recordCommit()
                        return true
                    }
                ),
                installationIdentity: oldIdentity
            ),
            .owner
        )
        let ownerID = try XCTUnwrap(readOwnerRecord(at: fixture.ownerURL)?.instanceID)
        let claimantInstanceID = UUID()
        let requestID = UUID()
        let claimantProcessIdentity = try XCTUnwrap(SingleInstanceProcessIdentity.current())
        try writeHandoffRequest(
            requestID: requestID,
            ownerInstanceID: ownerID,
            claimantInstanceID: claimantInstanceID,
            installationIdentity: preferredIdentity,
            processIdentity: claimantProcessIdentity,
            to: fixture.requestURL(for: requestID)
        )
        XCTAssertTrue(waitUntil(timeout: 1) {
            acknowledgementAccepted(at: fixture.acknowledgementURL(for: requestID)) == true
        })

        let provisionalDescriptor = Darwin.open(
            fixture.lockURL.path,
            O_RDWR | O_CLOEXEC | O_NOFOLLOW
        )
        XCTAssertGreaterThanOrEqual(provisionalDescriptor, 0)
        guard provisionalDescriptor >= 0 else { return }
        XCTAssertEqual(flock(provisionalDescriptor, LOCK_EX | LOCK_NB), 0)
        race.installProvisionalDescriptor(provisionalDescriptor)
        let provisionalRecord = SingleInstanceOwnerRecord(
            instanceID: claimantInstanceID,
            pid: claimantProcessIdentity.pid,
            installationIdentity: preferredIdentity,
            processIdentity: claimantProcessIdentity,
            ownershipState: .provisionalHandoff,
            handoffRequestID: requestID
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        try encoder.encode(provisionalRecord).write(to: fixture.ownerURL, options: .atomic)

        XCTAssertTrue(waitUntil(timeout: 1) {
            race.didInterpose
        })
        XCTAssertTrue(waitUntil(timeout: 1) {
            owner.stableOwnerRecordHoldingLock()?.instanceID == ownerID
                && !FileManager.default.fileExists(atPath: fixture.handoffURL.path)
        })
        XCTAssertFalse(recorder.committed)
        XCTAssertEqual(readOwnerRecord(at: fixture.ownerURL)?.installationIdentity, oldIdentity)
    }

    func testClaimantFinalizingAfterCommittingPublicationDoesNotCancelBegin() throws {
        let fixture = makeFixture(
            acknowledgementTimeout: .milliseconds(300),
            handoffCompletionTimeout: .milliseconds(80)
        )
        defer { fixture.remove() }
        let oldIdentity = installationIdentity(
            path: "/Users/test/Downloads/CodexMonitorNative.app",
            digest: "old"
        )
        let preferredIdentity = installationIdentity(
            path: "/Applications/CodexMonitorNative.app",
            digest: "preferred"
        )
        let recorder = SingleInstanceHandoffRecorder()
        let publicationHarness = SingleInstanceCommitPublicationHarness(
            ownerURL: fixture.ownerURL,
            handoffURL: fixture.handoffURL
        )
        let owner = SingleInstanceCoordinator(
            configuration: fixture.configuration,
            handoffVerificationObserver: { event in
                guard event == .didPublishCommitting else { return }
                publicationHarness.waitForClaimantFinalization()
            }
        )
        defer { owner.release() }
        XCTAssertEqual(
            owner.claim(
                using: .immediate(
                    { _ in true },
                    shouldRelinquish: { $0 == preferredIdentity },
                    commitRelinquishment: {
                        recorder.recordCommit()
                        return true
                    },
                    didRelinquish: {
                        recorder.recordRelinquished()
                    }
                ),
                installationIdentity: oldIdentity
            ),
            .owner
        )

        let claimant = SingleInstanceCoordinator(configuration: fixture.configuration)
        defer { claimant.release() }
        XCTAssertEqual(
            claimant.claim(
                using: .immediate { _ in true },
                installationIdentity: preferredIdentity
            ),
            .owner
        )
        XCTAssertTrue(waitUntil(timeout: 1) {
            publicationHarness.observedFinalizedClaimant
        })
        XCTAssertEqual(recorder.waitForRelinquishment(until: .now() + .seconds(1)), .success)
        XCTAssertEqual(recorder.commitCount, 1)
        XCTAssertEqual(recorder.relinquishmentCount, 1)
        XCTAssertEqual(claimant.stableOwnerRecordHoldingLock()?.installationIdentity, preferredIdentity)
        XCTAssertEqual(readOwnerRecord(at: fixture.ownerURL)?.ownershipState, nil)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.handoffURL.path))
    }

    func testRejectedHandoffKeepsOriginalOwnerAndFallsBackToActivation() throws {
        let fixture = makeFixture()
        defer { fixture.remove() }
        let oldIdentity = installationIdentity(
            path: "/Users/test/Downloads/CodexMonitorNative.app",
            digest: "old"
        )
        let untrustedIdentity = installationIdentity(
            path: "/Applications/CodexMonitorNative.app",
            digest: "untrusted"
        )
        let recorder = SingleInstanceActivationRecorder()
        let owner = SingleInstanceCoordinator(configuration: fixture.configuration)
        defer { owner.release() }

        XCTAssertEqual(
            owner.claim(
                using: .immediate(
                    { recorder.record($0) },
                    shouldRelinquish: { _ in false }
                ),
                installationIdentity: oldIdentity
            ),
            .owner
        )
        let originalOwnerID = try XCTUnwrap(readOwnerRecord(at: fixture.ownerURL)?.instanceID)
        let contender = SingleInstanceCoordinator(configuration: fixture.configuration)

        XCTAssertEqual(
            contender.claim(
                using: .immediate { _ in true },
                installationIdentity: untrustedIdentity
            ),
            .secondary(forwardedActivation: true)
        )
        XCTAssertEqual(readOwnerRecord(at: fixture.ownerURL)?.instanceID, originalOwnerID)
        XCTAssertEqual(readOwnerRecord(at: fixture.ownerURL)?.installationIdentity, oldIdentity)
        XCTAssertEqual(recorder.actions, [.showPopover])
    }

    func testLiveHandoffTicketBlocksUnrelatedThirdContender() throws {
        let fixture = makeFixture()
        defer { fixture.remove() }
        try fixture.prepareDirectories()
        let reservedIdentity = installationIdentity(
            path: "/Applications/CodexMonitorNative.app",
            digest: "reserved"
        )
        let unrelatedIdentity = installationIdentity(
            path: "/Users/test/Downloads/CodexMonitorNative.app",
            digest: "unrelated"
        )
        let ticket = SingleInstanceHandoffTicket(
            protocolVersion: SingleInstanceOwnerRecord.currentProtocolVersion,
            handoffCapabilityVersion: SingleInstanceOwnerRecord.currentHandoffCapabilityVersion,
            requestID: UUID(),
            ownerInstanceID: UUID(),
            claimantInstanceID: UUID(),
            claimantInstallationIdentity: reservedIdentity,
            expiresAt: Date().addingTimeInterval(2)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        try encoder.encode(ticket).write(to: fixture.handoffURL, options: .atomic)

        let contender = SingleInstanceCoordinator(configuration: fixture.configuration)
        let result = contender.claim(
            using: .immediate { _ in true },
            installationIdentity: unrelatedIdentity
        )

        guard case .failed(let reason) = result else {
            return XCTFail("Expected reserved ownership failure, got \(result)")
        }
        XCTAssertTrue(reason.contains("reserved for another claimant"))
        XCTAssertNil(readOwnerRecord(at: fixture.ownerURL))
    }

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

    func testLegacyOwnerWithoutHandoffCapabilityRemainsSecondary() throws {
        let fixture = makeFixture()
        defer { fixture.remove() }
        let record = SingleInstanceOwnerRecord(
            instanceID: UUID(),
            installationIdentity: installationIdentity(
                path: "/Applications/LegacyCodexMonitorNative.app",
                digest: "legacy"
            ),
            handoffCapabilityVersion: nil,
            processIdentity: nil
        )
        let descriptor = try installContendedOwnerRecord(record, fixture: fixture)
        defer { Darwin.close(descriptor) }
        let contender = SingleInstanceCoordinator(configuration: fixture.configuration)

        XCTAssertEqual(
            contender.claim(
                using: .immediate { _ in
                    XCTFail("Legacy owner without v2 handoff acknowledged activation")
                    return false
                },
                installationIdentity: installationIdentity(
                    path: "/Applications/CodexMonitorNative.app",
                    digest: "current"
                )
            ),
            .secondary(forwardedActivation: false)
        )
        XCTAssertEqual(readOwnerRecord(at: fixture.ownerURL)?.instanceID, record.instanceID)
    }

    func testOwnerWithoutProcessIdentityCannotAuthorizeV2Handoff() throws {
        let fixture = makeFixture()
        defer { fixture.remove() }
        let record = SingleInstanceOwnerRecord(
            instanceID: UUID(),
            installationIdentity: installationIdentity(
                path: "/Applications/OldCodexMonitorNative.app",
                digest: "old"
            ),
            handoffCapabilityVersion: SingleInstanceOwnerRecord.currentHandoffCapabilityVersion,
            processIdentity: nil
        )
        let descriptor = try installContendedOwnerRecord(record, fixture: fixture)
        defer { Darwin.close(descriptor) }
        let contender = SingleInstanceCoordinator(configuration: fixture.configuration)

        XCTAssertEqual(
            contender.claim(
                using: .immediate { _ in false },
                installationIdentity: installationIdentity(
                    path: "/Applications/CodexMonitorNative.app",
                    digest: "current"
                )
            ),
            .secondary(forwardedActivation: false)
        )
        XCTAssertEqual(readOwnerRecord(at: fixture.ownerURL)?.instanceID, record.instanceID)
    }

    func testLiveV2OwnerWithPublishedProcessIdentityRemovedDoesNotRelinquish() throws {
        let fixture = makeFixture()
        defer { fixture.remove() }
        let oldIdentity = installationIdentity(
            path: "/Applications/OldCodexMonitorNative.app",
            digest: "old"
        )
        let currentIdentity = installationIdentity(
            path: "/Applications/CodexMonitorNative.app",
            digest: "current"
        )
        let handoffRecorder = SingleInstanceHandoffRecorder()
        let owner = SingleInstanceCoordinator(configuration: fixture.configuration)
        defer { owner.release() }
        XCTAssertEqual(
            owner.claim(
                using: .immediate(
                    { $0 == .showPopover },
                    shouldRelinquish: { _ in true },
                    commitRelinquishment: {
                        handoffRecorder.recordCommit()
                        return true
                    },
                    didRelinquish: {
                        handoffRecorder.recordRelinquished()
                    }
                ),
                installationIdentity: oldIdentity
            ),
            .owner
        )
        let published = try XCTUnwrap(readOwnerRecord(at: fixture.ownerURL))
        let missingProcessIdentity = SingleInstanceOwnerRecord(
            instanceID: published.instanceID,
            pid: published.pid,
            startedAt: published.startedAt,
            installationIdentity: published.installationIdentity,
            handoffCapabilityVersion: published.handoffCapabilityVersion,
            activationCount: published.activationCount,
            processIdentity: nil,
            ownershipState: published.ownershipState,
            handoffRequestID: published.handoffRequestID
        )
        try writeOwnerRecord(missingProcessIdentity, to: fixture.ownerURL)
        let claimant = SingleInstanceCoordinator(configuration: fixture.configuration)
        defer { claimant.release() }

        XCTAssertEqual(
            claimant.claim(
                using: .immediate { _ in false },
                installationIdentity: currentIdentity
            ),
            .secondary(forwardedActivation: true)
        )
        XCTAssertFalse(handoffRecorder.committed)
        XCTAssertFalse(handoffRecorder.relinquished)
        XCTAssertEqual(owner.stableOwnerRecordHoldingLock()?.instanceID, published.instanceID)
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
        acknowledgementTimeout: DispatchTimeInterval = .milliseconds(500),
        handoffCompletionTimeout: DispatchTimeInterval = .milliseconds(500)
    ) -> SingleInstanceFixture {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexMonitorNativeTests.singleInstance.\(UUID().uuidString)", isDirectory: true)
        return SingleInstanceFixture(
            rootURL: rootURL,
            configuration: SingleInstanceConfiguration(
                namespaceURL: rootURL,
                ownerReadyTimeout: ownerReadyTimeout,
                acknowledgementTimeout: acknowledgementTimeout,
                handoffCompletionTimeout: handoffCompletionTimeout
            )
        )
    }

    private func installationIdentity(path: String, digest: String) -> AppInstallationIdentity {
        AppInstallationIdentity(
            bundlePath: path,
            bundleIdentifier: "com.ryukeilee.CodexMonitorNativePrototype",
            codeIdentityDigest: digest,
            signingAnchorDigest: "test-signing-anchor",
            version: AppInstallationVersion(marketingVersion: "1.0", buildVersion: "1")
        )
    }

    private func installContendedOwnerRecord(
        _ record: SingleInstanceOwnerRecord,
        fixture: SingleInstanceFixture
    ) throws -> Int32 {
        try fixture.prepareDirectories()
        let descriptor = Darwin.open(
            fixture.lockURL.path,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let error = NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            Darwin.close(descriptor)
            throw error
        }
        do {
            try writeOwnerRecord(record, to: fixture.ownerURL)
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private func writeOwnerRecord(
        _ record: SingleInstanceOwnerRecord,
        to ownerURL: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        try encoder.encode(record).write(to: ownerURL, options: .atomic)
    }

    private func readOwnerRecord(at url: URL) -> SingleInstanceOwnerRecord? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try? decoder.decode(SingleInstanceOwnerRecord.self, from: data)
    }

    private func acknowledgementAccepted(at url: URL) -> Bool? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object["accepted"] as? Bool
    }

    private func writeHandoffRequest(
        requestID: UUID,
        ownerInstanceID: UUID,
        claimantInstanceID: UUID = UUID(),
        installationIdentity: AppInstallationIdentity,
        processIdentity: SingleInstanceProcessIdentity? = nil,
        requestLifetime: TimeInterval = 0.3,
        to url: URL
    ) throws {
        let processIdentity = try XCTUnwrap(
            processIdentity ?? SingleInstanceProcessIdentity.current()
        )
        let request = TestSingleInstanceHandoffRequest(
            protocolVersion: SingleInstanceOwnerRecord.currentProtocolVersion,
            targetInstanceID: ownerInstanceID,
            requestID: requestID,
            action: .requestOwnershipHandoff,
            createdAt: .now,
            expiresAt: Date().addingTimeInterval(requestLifetime),
            claimantInstanceID: claimantInstanceID,
            claimantPID: processIdentity.pid,
            claimantProcessIdentity: processIdentity,
            claimantInstallationIdentity: installationIdentity
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        try encoder.encode(request).write(to: url, options: .atomic)
    }

    private func waitUntil(timeout: TimeInterval, condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        return condition()
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

private final class SingleInstanceHandoffRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let relinquishmentSignal = DispatchSemaphore(value: 0)
    private var didCommit = false
    private var didRelinquish = false
    private var recordedCommitCount = 0
    private var recordedRelinquishmentCount = 0
    private var recordedRequestDeadline: Date?

    var committed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didCommit
    }

    var relinquished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didRelinquish
    }

    var commitCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return recordedCommitCount
    }

    var relinquishmentCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return recordedRelinquishmentCount
    }

    var requestDeadline: Date? {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequestDeadline
    }

    func recordCommit() {
        lock.lock()
        didCommit = true
        recordedCommitCount += 1
        lock.unlock()
    }

    func recordRelinquished() {
        lock.lock()
        didRelinquish = true
        recordedRelinquishmentCount += 1
        lock.unlock()
        relinquishmentSignal.signal()
    }

    func recordRequestDeadline(_ deadline: Date) {
        lock.lock()
        recordedRequestDeadline = deadline
        lock.unlock()
    }

    func waitForRelinquishment(until deadline: DispatchTime) -> DispatchTimeoutResult {
        relinquishmentSignal.wait(timeout: deadline)
    }
}

private final class SingleInstanceVerificationRaceHarness: @unchecked Sendable {
    private let lock = NSLock()
    private let ownerURL: URL
    private let lockURL: URL
    private var provisionalDescriptor: Int32 = -1
    private var thirdContenderDescriptor: Int32 = -1
    private var hasInterposed = false
    private var thirdContenderAcquired = false

    init(ownerURL: URL, lockURL: URL) {
        self.ownerURL = ownerURL
        self.lockURL = lockURL
    }

    deinit {
        releaseDescriptors()
    }

    var didInterpose: Bool {
        lock.lock()
        defer { lock.unlock() }
        return hasInterposed && thirdContenderAcquired
    }

    func installProvisionalDescriptor(_ descriptor: Int32) {
        lock.lock()
        provisionalDescriptor = descriptor
        lock.unlock()
    }

    func interposeAfterCandidateRead() {
        lock.lock()
        guard !hasInterposed, provisionalDescriptor >= 0 else {
            lock.unlock()
            return
        }
        hasInterposed = true
        let descriptor = provisionalDescriptor
        provisionalDescriptor = -1
        lock.unlock()

        // Match the claimant's abandon ordering: remove its proof record before
        // releasing the lock, then let a third contender acquire the same inode.
        try? FileManager.default.removeItem(at: ownerURL)
        Darwin.close(descriptor)
        let thirdDescriptor = Darwin.open(
            lockURL.path,
            O_RDWR | O_CLOEXEC | O_NOFOLLOW
        )
        let acquired = thirdDescriptor >= 0
            && flock(thirdDescriptor, LOCK_EX | LOCK_NB) == 0
        lock.lock()
        if acquired {
            thirdContenderDescriptor = thirdDescriptor
            thirdContenderAcquired = true
        } else if thirdDescriptor >= 0 {
            Darwin.close(thirdDescriptor)
        }
        lock.unlock()

        DispatchQueue.global(qos: .userInitiated).asyncAfter(
            deadline: .now() + .milliseconds(40)
        ) { [weak self] in
            self?.releaseThirdContender()
        }
    }

    private func releaseThirdContender() {
        lock.lock()
        let descriptor = thirdContenderDescriptor
        thirdContenderDescriptor = -1
        lock.unlock()
        if descriptor >= 0 {
            Darwin.close(descriptor)
        }
    }

    private func releaseDescriptors() {
        lock.lock()
        let provisional = provisionalDescriptor
        let third = thirdContenderDescriptor
        provisionalDescriptor = -1
        thirdContenderDescriptor = -1
        lock.unlock()
        if provisional >= 0 {
            Darwin.close(provisional)
        }
        if third >= 0 {
            Darwin.close(third)
        }
    }
}

private final class SingleInstanceCommitPublicationHarness: @unchecked Sendable {
    private let lock = NSLock()
    private let ownerURL: URL
    private let handoffURL: URL
    private var didObserveFinalizedClaimant = false

    init(ownerURL: URL, handoffURL: URL) {
        self.ownerURL = ownerURL
        self.handoffURL = handoffURL
    }

    var observedFinalizedClaimant: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didObserveFinalizedClaimant
    }

    func waitForClaimantFinalization() {
        let deadline = Date().addingTimeInterval(1)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        while Date() < deadline {
            let record = (try? Data(contentsOf: ownerURL)).flatMap {
                try? decoder.decode(SingleInstanceOwnerRecord.self, from: $0)
            }
            if let record,
               record.ownershipState == nil,
               record.handoffRequestID == nil,
               !FileManager.default.fileExists(atPath: handoffURL.path) {
                lock.lock()
                didObserveFinalizedClaimant = true
                lock.unlock()
                return
            }
            usleep(1_000)
        }
    }
}

private final class SingleInstanceRelinquishmentAuthorizationHarness: @unchecked Sendable {
    private let lock = NSLock()
    private let capturedSignal = DispatchSemaphore(value: 0)
    private var capturedCompletion: (@Sendable (Bool) -> Void)?

    func capture(_ completion: @escaping @Sendable (Bool) -> Void) {
        lock.lock()
        capturedCompletion = completion
        lock.unlock()
        capturedSignal.signal()
    }

    func waitUntilCaptured(until deadline: DispatchTime) -> DispatchTimeoutResult {
        capturedSignal.wait(timeout: deadline)
    }

    func complete(accepted: Bool) {
        lock.lock()
        let completion = capturedCompletion
        capturedCompletion = nil
        lock.unlock()
        completion?(accepted)
    }
}

private struct TestSingleInstanceHandoffRequest: Encodable {
    let protocolVersion: Int
    let targetInstanceID: UUID
    let requestID: UUID
    let action: SingleInstanceActivationAction
    let createdAt: Date
    let expiresAt: Date
    let claimantInstanceID: UUID
    let claimantPID: Int32
    let claimantProcessIdentity: SingleInstanceProcessIdentity
    let claimantInstallationIdentity: AppInstallationIdentity
}

private struct SingleInstanceFixture {
    let rootURL: URL
    let configuration: SingleInstanceConfiguration

    var lockURL: URL { rootURL.appendingPathComponent("owner.lock") }
    var ownerURL: URL { rootURL.appendingPathComponent("owner.json") }
    var handoffURL: URL { rootURL.appendingPathComponent("handoff.json") }

    func requestURL(for requestID: UUID) -> URL {
        rootURL
            .appendingPathComponent("requests", isDirectory: true)
            .appendingPathComponent("request-\(requestID.uuidString).json")
    }

    func acknowledgementURL(for requestID: UUID) -> URL {
        rootURL
            .appendingPathComponent("acknowledgements", isDirectory: true)
            .appendingPathComponent("ack-\(requestID.uuidString).json")
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
