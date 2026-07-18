import Darwin
import Dispatch
import Foundation

enum SingleInstanceActivationAction: String, Codable, Sendable {
    case showPopover
    case requestOwnershipHandoff
}

enum SingleInstanceOwnershipState: String, Codable, Sendable {
    case provisionalHandoff
}

enum SingleInstanceHandoffPhase: String, Codable, Sendable {
    case authorized
    case committing
    case committed
    case cancelled
}

enum SingleInstanceHandoffVerificationEvent: Equatable, Sendable {
    case didReadCandidateBeforeLockProbe
    case didPublishCommitting
}

struct SingleInstanceProcessIdentity: Codable, Equatable, Sendable {
    let pid: Int32
    let effectiveUserID: UInt32
    let startSeconds: UInt64
    let startMicroseconds: UInt64

    static func current() -> SingleInstanceProcessIdentity? {
        read(processID: ProcessInfo.processInfo.processIdentifier)
    }

    static func read(processID: Int32) -> SingleInstanceProcessIdentity? {
        guard processID > 0 else { return nil }
        var information = proc_bsdinfo()
        let expectedSize = MemoryLayout<proc_bsdinfo>.size
        let result = withUnsafeMutablePointer(to: &information) { pointer in
            proc_pidinfo(
                processID,
                PROC_PIDTBSDINFO,
                0,
                pointer,
                Int32(expectedSize)
            )
        }
        guard result == Int32(expectedSize),
              information.pbi_pid == UInt32(processID) else {
            return nil
        }
        return SingleInstanceProcessIdentity(
            pid: processID,
            effectiveUserID: UInt32(information.pbi_uid),
            startSeconds: information.pbi_start_tvsec,
            startMicroseconds: information.pbi_start_tvusec
        )
    }

    var isCurrentKernelIdentity: Bool {
        effectiveUserID == UInt32(geteuid()) && Self.read(processID: pid) == self
    }

}

struct SingleInstanceOwnerRecord: Codable, Equatable, Sendable {
    static let currentProtocolVersion = 1
    static let currentHandoffCapabilityVersion = 2

    let protocolVersion: Int
    let instanceID: UUID
    let pid: Int32
    let startedAt: Date
    var installationIdentity: AppInstallationIdentity?
    let handoffCapabilityVersion: Int?
    var activationCount: UInt64
    let processIdentity: SingleInstanceProcessIdentity?
    let ownershipState: SingleInstanceOwnershipState?
    let handoffRequestID: UUID?

    init(
        instanceID: UUID,
        pid: Int32 = ProcessInfo.processInfo.processIdentifier,
        startedAt: Date = .now,
        installationIdentity: AppInstallationIdentity? = nil,
        handoffCapabilityVersion: Int? = Self.currentHandoffCapabilityVersion,
        activationCount: UInt64 = 0,
        processIdentity: SingleInstanceProcessIdentity? = .current(),
        ownershipState: SingleInstanceOwnershipState? = nil,
        handoffRequestID: UUID? = nil
    ) {
        self.protocolVersion = Self.currentProtocolVersion
        self.instanceID = instanceID
        self.pid = pid
        self.startedAt = startedAt
        self.installationIdentity = installationIdentity
        self.handoffCapabilityVersion = handoffCapabilityVersion
        self.activationCount = activationCount
        self.processIdentity = processIdentity
        self.ownershipState = ownershipState
        self.handoffRequestID = handoffRequestID
    }
}

struct SingleInstanceConfiguration: Sendable {
    let namespaceURL: URL
    let ownerReadyTimeout: DispatchTimeInterval
    let acknowledgementTimeout: DispatchTimeInterval
    let handoffCompletionTimeout: DispatchTimeInterval

    static func live(fileManager: FileManager = .default) -> SingleInstanceConfiguration {
        // The main app is deliberately not sandboxed. Using one explicit per-user
        // location keeps installed bundles, dist builds, LLDB launches, and raw
        // SwiftPM development binaries in the same arbitration domain.
        let namespaceURL = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("CodexMonitorNative", isDirectory: true)
            .appendingPathComponent("InstanceArbitration", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
        return SingleInstanceConfiguration(
            namespaceURL: namespaceURL,
            ownerReadyTimeout: .milliseconds(500),
            acknowledgementTimeout: .seconds(2),
            handoffCompletionTimeout: .seconds(2)
        )
    }
}

enum SingleInstanceClaimResult: Equatable, Sendable {
    case owner
    case secondary(forwardedActivation: Bool)
    case failed(reason: String)
}

struct SingleInstanceActivationExecutor: Sendable {
    private let submitAction: @Sendable (
        SingleInstanceActivationAction,
        Date,
        @escaping @Sendable (Bool) -> Void
    ) -> Void
    private let submitRelinquishment: @Sendable (
        AppInstallationIdentity,
        Date,
        @escaping @Sendable (Bool) -> Void
    ) -> Void
    private let commitRelinquishmentAction: @Sendable (
        Date,
        @escaping @Sendable () -> Bool,
        @escaping @Sendable (Bool) -> Void
    ) -> Void
    private let notifyRelinquished: @Sendable () -> Void

    init(
        submitAction: @escaping @Sendable (
            SingleInstanceActivationAction,
            Date,
            @escaping @Sendable (Bool) -> Void
        ) -> Void,
        submitRelinquishment: @escaping @Sendable (
            AppInstallationIdentity,
            Date,
            @escaping @Sendable (Bool) -> Void
        ) -> Void = { _, _, completion in completion(false) },
        commitRelinquishment: @escaping @Sendable (
            Date,
            @escaping @Sendable () -> Bool,
            @escaping @Sendable (Bool) -> Void
        ) -> Void = { _, begin, completion in completion(begin()) },
        notifyRelinquished: @escaping @Sendable () -> Void = {}
    ) {
        self.submitAction = submitAction
        self.submitRelinquishment = submitRelinquishment
        self.commitRelinquishmentAction = commitRelinquishment
        self.notifyRelinquished = notifyRelinquished
    }

    func submit(
        _ action: SingleInstanceActivationAction,
        expiresAt: Date,
        completion: @escaping @Sendable (Bool) -> Void
    ) {
        submitAction(action, expiresAt, completion)
    }

    func submitRelinquishment(
        to installationIdentity: AppInstallationIdentity,
        expiresAt: Date,
        completion: @escaping @Sendable (Bool) -> Void
    ) {
        submitRelinquishment(installationIdentity, expiresAt, completion)
    }

    func relinquishmentDidComplete() {
        notifyRelinquished()
    }

    func commitRelinquishment(
        expiresAt: Date,
        begin: @escaping @Sendable () -> Bool,
        completion: @escaping @Sendable (Bool) -> Void
    ) {
        commitRelinquishmentAction(expiresAt, begin, completion)
    }

    static func mainActor(
        _ handler: @escaping @MainActor @Sendable (SingleInstanceActivationAction) -> Bool,
        shouldRelinquish: @escaping @MainActor @Sendable (AppInstallationIdentity) -> Bool = { _ in false },
        commitRelinquishment: @escaping @MainActor @Sendable () -> Bool = { true },
        didRelinquish: @escaping @MainActor @Sendable () -> Void = {}
    ) -> SingleInstanceActivationExecutor {
        SingleInstanceActivationExecutor(
            submitAction: { action, expiresAt, completion in
                Task { @MainActor in
                    guard expiresAt > .now else {
                        completion(false)
                        return
                    }
                    completion(handler(action))
                }
            },
            submitRelinquishment: { installationIdentity, expiresAt, completion in
                Task { @MainActor in
                    guard expiresAt > .now else {
                        completion(false)
                        return
                    }
                    completion(shouldRelinquish(installationIdentity))
                }
            },
            commitRelinquishment: { expiresAt, begin, completion in
                Task { @MainActor in
                    guard expiresAt > .now, begin() else {
                        completion(false)
                        return
                    }
                    completion(commitRelinquishment())
                }
            },
            notifyRelinquished: {
                Task { @MainActor in
                    didRelinquish()
                }
            }
        )
    }

    static func immediate(
        _ handler: @escaping @Sendable (SingleInstanceActivationAction) -> Bool,
        shouldRelinquish: @escaping @Sendable (AppInstallationIdentity) -> Bool = { _ in false },
        commitRelinquishment: @escaping @Sendable () -> Bool = { true },
        didRelinquish: @escaping @Sendable () -> Void = {}
    ) -> SingleInstanceActivationExecutor {
        SingleInstanceActivationExecutor(
            submitAction: { action, expiresAt, completion in
                completion(expiresAt > .now && handler(action))
            },
            submitRelinquishment: { installationIdentity, expiresAt, completion in
                completion(expiresAt > .now && shouldRelinquish(installationIdentity))
            },
            commitRelinquishment: { expiresAt, begin, completion in
                guard expiresAt > .now, begin() else {
                    completion(false)
                    return
                }
                completion(commitRelinquishment())
            },
            notifyRelinquished: didRelinquish
        )
    }
}

@MainActor
final class SingleInstanceCoordinator {
    private let configuration: SingleInstanceConfiguration
    private let instanceIDProvider: @Sendable () -> UUID
    private let handoffVerificationObserver: @Sendable (
        SingleInstanceHandoffVerificationEvent
    ) -> Void
    private var lease: OwnedSingleInstanceLease?

    init(
        configuration: SingleInstanceConfiguration = .live(),
        instanceIDProvider: @escaping @Sendable () -> UUID = { UUID() },
        handoffVerificationObserver: @escaping @Sendable (
            SingleInstanceHandoffVerificationEvent
        ) -> Void = { _ in }
    ) {
        self.configuration = configuration
        self.instanceIDProvider = instanceIDProvider
        self.handoffVerificationObserver = handoffVerificationObserver
    }

    func claim(
        installationIdentity: AppInstallationIdentity? = nil,
        shouldRelinquish: @escaping @MainActor @Sendable (AppInstallationIdentity) -> Bool = { _ in false },
        commitRelinquishment: @escaping @MainActor @Sendable () -> Bool = { true },
        didRelinquish: @escaping @MainActor @Sendable () -> Void = {},
        onActivation: @escaping @MainActor @Sendable (SingleInstanceActivationAction) -> Bool
    ) -> SingleInstanceClaimResult {
        claim(
            using: .mainActor(
                onActivation,
                shouldRelinquish: shouldRelinquish,
                commitRelinquishment: commitRelinquishment,
                didRelinquish: didRelinquish
            ),
            installationIdentity: installationIdentity
        )
    }

    func claim(
        using activationExecutor: SingleInstanceActivationExecutor,
        installationIdentity: AppInstallationIdentity? = nil
    ) -> SingleInstanceClaimResult {
        if let lease {
            if lease.isHoldingOwnership {
                return .owner
            }
            lease.release()
            self.lease = nil
        }

        let claimantInstanceID = instanceIDProvider()
        let namespace = SingleInstanceNamespace(rootURL: configuration.namespaceURL)
        do {
            try namespace.prepare()
            let lockAttempt = try namespace.openAndTryLock()
            switch lockAttempt {
            case .acquired(let descriptor):
                return becomeOwner(
                    descriptor: descriptor,
                    namespace: namespace,
                    claimantInstanceID: claimantInstanceID,
                    installationIdentity: installationIdentity,
                    activationExecutor: activationExecutor
                )

            case .contended(let descriptor):
                return forwardOrTakeOver(
                    descriptor: descriptor,
                    namespace: namespace,
                    claimantInstanceID: claimantInstanceID,
                    installationIdentity: installationIdentity,
                    activationExecutor: activationExecutor
                )
            }
        } catch {
            return .failed(reason: SingleInstanceError.describe(error))
        }
    }

    func release() {
        lease?.release()
        lease = nil
    }

    func prepareForShutdown() {
        lease?.prepareForShutdown()
    }

    @discardableResult
    func updateOwnedInstallationIdentity(_ installationIdentity: AppInstallationIdentity?) -> Bool {
        guard let lease, lease.isHoldingOwnership else { return false }
        return lease.updateInstallationIdentity(installationIdentity)
    }

    func currentOwnerRecord() -> SingleInstanceOwnerRecord? {
        let namespace = SingleInstanceNamespace(rootURL: configuration.namespaceURL)
        guard let record = InstanceFileIO.read(
            SingleInstanceOwnerRecord.self,
            from: namespace.ownerURL
        ), record.protocolVersion == SingleInstanceOwnerRecord.currentProtocolVersion else {
            return nil
        }
        return record
    }

    func stableOwnerRecordHoldingLock() -> SingleInstanceOwnerRecord? {
        let namespace = SingleInstanceNamespace(rootURL: configuration.namespaceURL)
        guard let before = currentOwnerRecord() else { return nil }
        do {
            guard let attempt = try namespace.openExistingAndTryLock() else { return nil }
            switch attempt {
            case .acquired(let descriptor):
                Darwin.close(descriptor)
                return nil
            case .contended(let descriptor):
                Darwin.close(descriptor)
            }
        } catch {
            return nil
        }

        guard let after = currentOwnerRecord(),
              before.protocolVersion == after.protocolVersion,
              before.instanceID == after.instanceID,
              before.pid == after.pid,
              before.startedAt == after.startedAt,
              before.installationIdentity == after.installationIdentity,
              before.handoffCapabilityVersion == after.handoffCapabilityVersion,
              before.processIdentity == after.processIdentity,
              before.ownershipState == after.ownershipState,
              before.handoffRequestID == after.handoffRequestID else {
            return nil
        }
        return after
    }

    private func forwardOrTakeOver(
        descriptor: Int32,
        namespace: SingleInstanceNamespace,
        claimantInstanceID: UUID,
        installationIdentity: AppInstallationIdentity?,
        activationExecutor: SingleInstanceActivationExecutor
    ) -> SingleInstanceClaimResult {
        let client = SingleInstanceActivationClient(
            namespace: namespace,
            ownerReadyTimeout: configuration.ownerReadyTimeout,
            acknowledgementTimeout: configuration.acknowledgementTimeout
        )

        if let installationIdentity,
           let owner = client.waitForOwnerRecord(),
           owner.handoffCapabilityVersion == SingleInstanceOwnerRecord.currentHandoffCapabilityVersion,
           let ownerProcessIdentity = owner.processIdentity,
           ownerProcessIdentity.pid == owner.pid,
           ownerProcessIdentity.isCurrentKernelIdentity,
           owner.installationIdentity != installationIdentity {
            switch client.requestOwnershipHandoff(
                from: owner,
                claimantInstanceID: claimantInstanceID,
                claimantPID: ProcessInfo.processInfo.processIdentifier,
                claimantInstallationIdentity: installationIdentity
            ) {
            case .accepted(let acceptedHandoff):
                return waitForHandoffOwnership(
                    descriptor: descriptor,
                    namespace: namespace,
                    claimantInstanceID: claimantInstanceID,
                    installationIdentity: installationIdentity,
                    acceptedHandoff: acceptedHandoff,
                    activationExecutor: activationExecutor
                )
            case .rejected, .unacknowledged:
                let forwarded = client.forward(.showPopover)
                Darwin.close(descriptor)
                return .secondary(forwardedActivation: forwarded)
            }
        }

        if client.forward(.showPopover) {
            Darwin.close(descriptor)
            return .secondary(forwardedActivation: true)
        }

        switch tryLockAgain(descriptor) {
        case .acquired:
            return becomeOwner(
                descriptor: descriptor,
                namespace: namespace,
                claimantInstanceID: claimantInstanceID,
                installationIdentity: installationIdentity,
                activationExecutor: activationExecutor
            )
        case .contended:
            // One bounded retry covers an owner replacement between metadata
            // discovery and acknowledgement. The action is idempotent.
            let forwarded = client.forward(.showPopover)
            if forwarded {
                Darwin.close(descriptor)
                return .secondary(forwardedActivation: true)
            }
            switch tryLockAgain(descriptor) {
            case .acquired:
                return becomeOwner(
                    descriptor: descriptor,
                    namespace: namespace,
                    claimantInstanceID: claimantInstanceID,
                    installationIdentity: installationIdentity,
                    activationExecutor: activationExecutor
                )
            case .contended:
                Darwin.close(descriptor)
                return .secondary(forwardedActivation: false)
            case .failed(let reason):
                Darwin.close(descriptor)
                return .failed(reason: reason)
            }
        case .failed(let reason):
            Darwin.close(descriptor)
            return .failed(reason: reason)
        }
    }

    private func becomeOwner(
        descriptor: Int32,
        namespace: SingleInstanceNamespace,
        claimantInstanceID: UUID,
        installationIdentity: AppInstallationIdentity?,
        acceptedHandoff: SingleInstanceAcceptedHandoff? = nil,
        activationExecutor: SingleInstanceActivationExecutor
    ) -> SingleInstanceClaimResult {
        var ownedLock: OwnedSingleInstanceLock?
        do {
            let handoffTicket = try authorizedHandoffTicket(
                namespace: namespace,
                claimantInstanceID: claimantInstanceID,
                installationIdentity: installationIdentity,
                acceptedHandoff: acceptedHandoff
            )
            // owner.json is diagnostic/readiness state, never the authority.
            // The permanent owner.lock inode remains untouched.
            try? FileManager.default.removeItem(at: namespace.ownerURL)
            let lock = OwnedSingleInstanceLock(descriptor: descriptor)
            ownedLock = lock
            let mailbox = OwnerActivationMailbox(
                namespace: namespace,
                record: SingleInstanceOwnerRecord(
                    instanceID: claimantInstanceID,
                    installationIdentity: installationIdentity
                ),
                ownedLock: lock,
                activationExecutor: activationExecutor,
                handoffCompletionTimeout: configuration.handoffCompletionTimeout,
                handoffVerificationObserver: handoffVerificationObserver
            )
            try mailbox.start()
            guard lock.isHeld,
                  let publishedRecord = InstanceFileIO.read(
                    SingleInstanceOwnerRecord.self,
                    from: namespace.ownerURL
                  ),
                  publishedRecord.instanceID == claimantInstanceID,
                  publishedRecord.installationIdentity == installationIdentity else {
                throw SingleInstanceError.ownerRecordVerificationFailed
            }
            if handoffTicket != nil {
                try FileManager.default.removeItem(at: namespace.handoffURL)
            }
            lease = OwnedSingleInstanceLease(
                ownedLock: lock,
                namespace: namespace,
                instanceID: claimantInstanceID,
                mailbox: mailbox
            )
            return .owner
        } catch {
            if InstanceFileIO.read(
                SingleInstanceOwnerRecord.self,
                from: namespace.ownerURL
            )?.instanceID == claimantInstanceID {
                try? FileManager.default.removeItem(at: namespace.ownerURL)
            }
            if let ownedLock {
                ownedLock.release()
            } else {
                Darwin.close(descriptor)
            }
            return .failed(reason: SingleInstanceError.describe(error))
        }
    }

    private func waitForHandoffOwnership(
        descriptor: Int32,
        namespace: SingleInstanceNamespace,
        claimantInstanceID: UUID,
        installationIdentity: AppInstallationIdentity,
        acceptedHandoff: SingleInstanceAcceptedHandoff,
        activationExecutor: SingleInstanceActivationExecutor
    ) -> SingleInstanceClaimResult {
        let remainingNanoseconds = boundedHandoffNanoseconds(
            until: acceptedHandoff.expiresAt
        )
        let deadline = DispatchTime.now() + .nanoseconds(remainingNanoseconds)
        let fallbackRetryNanoseconds: UInt64 = 100_000_000
        let waiter = try? DirectoryChangeWaiter(directoryURL: namespace.rootURL)

        while true {
            switch tryLockAgain(descriptor) {
            case .acquired:
                return completeProvisionalHandoff(
                    descriptor: descriptor,
                    namespace: namespace,
                    claimantInstanceID: claimantInstanceID,
                    installationIdentity: installationIdentity,
                    acceptedHandoff: acceptedHandoff,
                    activationExecutor: activationExecutor
                )
            case .contended:
                let now = DispatchTime.now()
                guard now < deadline else {
                    Darwin.close(descriptor)
                    return .secondary(forwardedActivation: false)
                }
                let retryAddition = now.uptimeNanoseconds.addingReportingOverflow(
                    fallbackRetryNanoseconds
                )
                let retryUptime = min(
                    deadline.uptimeNanoseconds,
                    retryAddition.overflow ? UInt64.max : retryAddition.partialValue
                )
                let retryDeadline = DispatchTime(uptimeNanoseconds: retryUptime)
                guard let waiter,
                      waiter.wait(until: retryDeadline) != .timedOut
                        || DispatchTime.now() < deadline else {
                    switch tryLockAgain(descriptor) {
                    case .acquired:
                        return completeProvisionalHandoff(
                            descriptor: descriptor,
                            namespace: namespace,
                            claimantInstanceID: claimantInstanceID,
                            installationIdentity: installationIdentity,
                            acceptedHandoff: acceptedHandoff,
                            activationExecutor: activationExecutor
                        )
                    case .contended:
                        Darwin.close(descriptor)
                        return .secondary(forwardedActivation: false)
                    case .failed(let reason):
                        Darwin.close(descriptor)
                        return .failed(reason: reason)
                    }
                }
                // Directory vnode notifications can be coalesced. Rechecking
                // the authoritative flock every 100 ms keeps handoff bounded
                // without treating owner.json events as proof of ownership.
            case .failed(let reason):
                Darwin.close(descriptor)
                return .failed(reason: reason)
            }
        }
    }

    private func completeProvisionalHandoff(
        descriptor: Int32,
        namespace: SingleInstanceNamespace,
        claimantInstanceID: UUID,
        installationIdentity: AppInstallationIdentity,
        acceptedHandoff: SingleInstanceAcceptedHandoff,
        activationExecutor: SingleInstanceActivationExecutor
    ) -> SingleInstanceClaimResult {
        let claimantPID = ProcessInfo.processInfo.processIdentifier
        let ownedLock = OwnedSingleInstanceLock(descriptor: descriptor)
        do {
            let ticket = try authorizedHandoffTicket(
                namespace: namespace,
                claimantInstanceID: claimantInstanceID,
                installationIdentity: installationIdentity,
                acceptedHandoff: acceptedHandoff
            )
            guard let ticket,
                  ticket.claimantPID == claimantPID,
                  ticket.effectivePhase == .authorized else {
                throw SingleInstanceError.ownershipReservedForAnotherClaimant
            }

            let provisionalRecord = SingleInstanceOwnerRecord(
                instanceID: claimantInstanceID,
                pid: claimantPID,
                installationIdentity: installationIdentity,
                processIdentity: ticket.claimantProcessIdentity,
                ownershipState: .provisionalHandoff,
                handoffRequestID: ticket.requestID
            )
            try InstanceFileIO.write(provisionalRecord, to: namespace.ownerURL)
            guard ownedLock.isHeld,
                  let publishedRecord = InstanceFileIO.read(
                    SingleInstanceOwnerRecord.self,
                    from: namespace.ownerURL
                  ),
                  publishedRecord.instanceID == provisionalRecord.instanceID,
                  publishedRecord.pid == provisionalRecord.pid,
                  publishedRecord.processIdentity == ticket.claimantProcessIdentity,
                  publishedRecord.installationIdentity == provisionalRecord.installationIdentity,
                  publishedRecord.ownershipState == .provisionalHandoff,
                  publishedRecord.handoffRequestID == ticket.requestID else {
                throw SingleInstanceError.ownerRecordVerificationFailed
            }

            let waiter = try? DirectoryChangeWaiter(directoryURL: namespace.rootURL)
            let deadline = DispatchTime.now() + .nanoseconds(
                boundedHandoffNanoseconds(until: ticket.expiresAt)
            )
            while true {
                let currentTicket = InstanceFileIO.read(
                    SingleInstanceHandoffTicket.self,
                    from: namespace.handoffURL
                )
                let phase = currentTicket.flatMap { current -> SingleInstanceHandoffPhase? in
                    guard current.requestID == ticket.requestID,
                          current.ownerInstanceID == ticket.ownerInstanceID,
                          current.claimantInstanceID == claimantInstanceID,
                          current.claimantPID == claimantPID,
                          current.claimantProcessIdentity == ticket.claimantProcessIdentity,
                          current.claimantInstallationIdentity == installationIdentity else {
                        return nil
                    }
                    return current.effectivePhase
                }

                if phase == .committed {
                    return finalizeProvisionalOwnership(
                        ownedLock: ownedLock,
                        namespace: namespace,
                        provisionalRecord: provisionalRecord,
                        ticket: ticket,
                        activationExecutor: activationExecutor
                    )
                }
                if phase == .cancelled || phase == nil {
                    abandonProvisionalOwnership(
                        ownedLock: ownedLock,
                        namespace: namespace,
                        instanceID: claimantInstanceID
                    )
                    return .secondary(forwardedActivation: false)
                }

                let now = DispatchTime.now()
                guard now < deadline else {
                    if phase == .committing {
                        // begin() marks the irreversible boundary. A late commit
                        // callback must not make this claimant report failure and
                        // then terminate the old owner behind it.
                        return finalizeProvisionalOwnership(
                            ownedLock: ownedLock,
                            namespace: namespace,
                            provisionalRecord: provisionalRecord,
                            ticket: ticket,
                            activationExecutor: activationExecutor
                        )
                    }
                    abandonProvisionalOwnership(
                        ownedLock: ownedLock,
                        namespace: namespace,
                        instanceID: claimantInstanceID
                    )
                    return .secondary(forwardedActivation: false)
                }
                let retryDeadline = DispatchTime(
                    uptimeNanoseconds: min(
                        deadline.uptimeNanoseconds,
                        now.uptimeNanoseconds.addingReportingOverflow(10_000_000).partialValue
                    )
                )
                _ = waiter?.wait(until: retryDeadline)
            }
        } catch {
            abandonProvisionalOwnership(
                ownedLock: ownedLock,
                namespace: namespace,
                instanceID: claimantInstanceID
            )
            return .failed(reason: SingleInstanceError.describe(error))
        }
    }

    private func finalizeProvisionalOwnership(
        ownedLock: OwnedSingleInstanceLock,
        namespace: SingleInstanceNamespace,
        provisionalRecord: SingleInstanceOwnerRecord,
        ticket: SingleInstanceHandoffTicket,
        activationExecutor: SingleInstanceActivationExecutor
    ) -> SingleInstanceClaimResult {
        do {
            let finalRecord = SingleInstanceOwnerRecord(
                instanceID: provisionalRecord.instanceID,
                pid: provisionalRecord.pid,
                startedAt: provisionalRecord.startedAt,
                installationIdentity: provisionalRecord.installationIdentity,
                processIdentity: provisionalRecord.processIdentity
            )
            let mailbox = OwnerActivationMailbox(
                namespace: namespace,
                record: finalRecord,
                ownedLock: ownedLock,
                activationExecutor: activationExecutor,
                handoffCompletionTimeout: configuration.handoffCompletionTimeout,
                handoffVerificationObserver: handoffVerificationObserver
            )
            try mailbox.start()
            guard ownedLock.isHeld,
                  let publishedRecord = InstanceFileIO.read(
                    SingleInstanceOwnerRecord.self,
                    from: namespace.ownerURL
                  ),
                  publishedRecord.instanceID == finalRecord.instanceID,
                  publishedRecord.pid == finalRecord.pid,
                  publishedRecord.processIdentity == finalRecord.processIdentity,
                  publishedRecord.installationIdentity == finalRecord.installationIdentity,
                  publishedRecord.ownershipState == nil,
                  publishedRecord.handoffRequestID == nil else {
                throw SingleInstanceError.ownerRecordVerificationFailed
            }
            if InstanceFileIO.read(
                SingleInstanceHandoffTicket.self,
                from: namespace.handoffURL
            )?.requestID == ticket.requestID {
                try? FileManager.default.removeItem(at: namespace.handoffURL)
            }
            lease = OwnedSingleInstanceLease(
                ownedLock: ownedLock,
                namespace: namespace,
                instanceID: provisionalRecord.instanceID,
                mailbox: mailbox
            )
            return .owner
        } catch {
            abandonProvisionalOwnership(
                ownedLock: ownedLock,
                namespace: namespace,
                instanceID: provisionalRecord.instanceID
            )
            return .failed(reason: SingleInstanceError.describe(error))
        }
    }

    private func abandonProvisionalOwnership(
        ownedLock: OwnedSingleInstanceLock,
        namespace: SingleInstanceNamespace,
        instanceID: UUID
    ) {
        if InstanceFileIO.read(
            SingleInstanceOwnerRecord.self,
            from: namespace.ownerURL
        )?.instanceID == instanceID {
            try? FileManager.default.removeItem(at: namespace.ownerURL)
        }
        ownedLock.release()
    }

    private func boundedHandoffNanoseconds(until date: Date) -> Int {
        let maximum = max(0, configuration.handoffCompletionTimeout.timeInterval)
        let remaining = min(maximum, max(0, date.timeIntervalSinceNow))
        return Int(min(remaining * 1_000_000_000, Double(Int.max)))
    }

    private func authorizedHandoffTicket(
        namespace: SingleInstanceNamespace,
        claimantInstanceID: UUID,
        installationIdentity: AppInstallationIdentity?,
        acceptedHandoff: SingleInstanceAcceptedHandoff?
    ) throws -> SingleInstanceHandoffTicket? {
        guard FileManager.default.fileExists(atPath: namespace.handoffURL.path) else {
            if acceptedHandoff != nil {
                throw SingleInstanceError.missingOwnershipHandoffTicket
            }
            return nil
        }
        guard let ticket = InstanceFileIO.read(
            SingleInstanceHandoffTicket.self,
            from: namespace.handoffURL
        ) else {
            throw SingleInstanceError.invalidFilesystemObject(namespace.handoffURL.path)
        }
        guard ticket.expiresAt > .now else {
            try FileManager.default.removeItem(at: namespace.handoffURL)
            if acceptedHandoff != nil {
                throw SingleInstanceError.expiredOwnershipHandoffTicket
            }
            return nil
        }
        guard let acceptedHandoff,
              ticket.protocolVersion == SingleInstanceOwnerRecord.currentProtocolVersion,
              ticket.handoffCapabilityVersion == SingleInstanceOwnerRecord.currentHandoffCapabilityVersion,
              ticket.requestID == acceptedHandoff.requestID,
              ticket.ownerInstanceID == acceptedHandoff.ownerInstanceID,
              ticket.claimantInstanceID == claimantInstanceID,
              ticket.claimantPID == ProcessInfo.processInfo.processIdentifier,
              ticket.claimantProcessIdentity == SingleInstanceProcessIdentity.current(),
              ticket.effectivePhase == .authorized,
              ticket.claimantInstallationIdentity == installationIdentity else {
            throw SingleInstanceError.ownershipReservedForAnotherClaimant
        }
        return ticket
    }

    private func tryLockAgain(_ descriptor: Int32) -> LockRetryResult {
        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
            return .acquired
        }

        let code = errno
        if code == EWOULDBLOCK || code == EAGAIN {
            return .contended
        }
        return .failed(reason: SingleInstanceError.posixDescription(
            operation: "retry flock",
            code: code
        ))
    }
}

private enum LockRetryResult {
    case acquired
    case contended
    case failed(reason: String)
}

private enum SingleInstanceLockAttempt {
    case acquired(Int32)
    case contended(Int32)
}

private struct SingleInstanceNamespace: Sendable {
    let rootURL: URL

    var lockURL: URL { rootURL.appendingPathComponent("owner.lock") }
    var ownerURL: URL { rootURL.appendingPathComponent("owner.json") }
    var handoffURL: URL { rootURL.appendingPathComponent("handoff.json") }
    var requestsURL: URL { rootURL.appendingPathComponent("requests", isDirectory: true) }
    var acknowledgementsURL: URL { rootURL.appendingPathComponent("acknowledgements", isDirectory: true) }

    func prepare(fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.createDirectory(
            at: requestsURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.createDirectory(
            at: acknowledgementsURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        try validatePrivateDirectory(rootURL)
        try validatePrivateDirectory(requestsURL)
        try validatePrivateDirectory(acknowledgementsURL)
    }

    func openAndTryLock() throws -> SingleInstanceLockAttempt {
        let descriptor = Darwin.open(
            lockURL.path,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard descriptor >= 0 else {
            throw SingleInstanceError.posix(operation: "open owner.lock", code: errno)
        }

        do {
            try validatePrivateLockFile(descriptor)
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
                return .acquired(descriptor)
            }

            let code = errno
            if code == EWOULDBLOCK || code == EAGAIN {
                return .contended(descriptor)
            }
            throw SingleInstanceError.posix(operation: "flock owner.lock", code: code)
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    func openExistingAndTryLock() throws -> SingleInstanceLockAttempt? {
        let descriptor = Darwin.open(
            lockURL.path,
            O_RDWR | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw SingleInstanceError.posix(operation: "open existing owner.lock", code: errno)
        }

        do {
            try validatePrivateLockFile(descriptor)
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
                return .acquired(descriptor)
            }
            let code = errno
            if code == EWOULDBLOCK || code == EAGAIN {
                return .contended(descriptor)
            }
            throw SingleInstanceError.posix(operation: "probe owner.lock", code: code)
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private func validatePrivateDirectory(_ url: URL) throws {
        var metadata = stat()
        guard Darwin.lstat(url.path, &metadata) == 0 else {
            throw SingleInstanceError.posix(operation: "lstat \(url.lastPathComponent)", code: errno)
        }
        guard metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_uid == geteuid() else {
            throw SingleInstanceError.invalidFilesystemObject(url.path)
        }
        if metadata.st_mode & 0o077 != 0,
           Darwin.chmod(url.path, mode_t(0o700)) != 0 {
            throw SingleInstanceError.posix(operation: "chmod \(url.lastPathComponent)", code: errno)
        }
    }

    private func validatePrivateLockFile(_ descriptor: Int32) throws {
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0 else {
            throw SingleInstanceError.posix(operation: "fstat owner.lock", code: errno)
        }
        guard metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == geteuid(),
              metadata.st_nlink == 1 else {
            throw SingleInstanceError.invalidFilesystemObject(lockURL.path)
        }
        if Darwin.fchmod(descriptor, mode_t(S_IRUSR | S_IWUSR)) != 0 {
            throw SingleInstanceError.posix(operation: "fchmod owner.lock", code: errno)
        }
    }
}

private final class OwnedSingleInstanceLock: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32

    init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    var isHeld: Bool {
        lock.lock()
        defer { lock.unlock() }
        return descriptor >= 0
    }

    func release() {
        lock.lock()
        let descriptor = self.descriptor
        self.descriptor = -1
        lock.unlock()

        if descriptor >= 0 {
            Darwin.close(descriptor)
        }
    }

    func adopt(_ descriptor: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard self.descriptor < 0, descriptor >= 0 else { return false }
        self.descriptor = descriptor
        return true
    }

    deinit {
        release()
    }
}

private final class OwnedSingleInstanceLease: @unchecked Sendable {
    private let lock = NSLock()
    private let ownedLock: OwnedSingleInstanceLock
    private let namespace: SingleInstanceNamespace
    private let instanceID: UUID
    private let mailbox: OwnerActivationMailbox
    private var didRelease = false

    init(
        ownedLock: OwnedSingleInstanceLock,
        namespace: SingleInstanceNamespace,
        instanceID: UUID,
        mailbox: OwnerActivationMailbox
    ) {
        self.ownedLock = ownedLock
        self.namespace = namespace
        self.instanceID = instanceID
        self.mailbox = mailbox
    }

    deinit {
        release()
    }

    var isHoldingOwnership: Bool {
        lock.lock()
        let didRelease = self.didRelease
        lock.unlock()
        return !didRelease && ownedLock.isHeld
    }

    func release() {
        lock.lock()
        guard !didRelease else {
            lock.unlock()
            return
        }
        didRelease = true
        lock.unlock()

        mailbox.stop()
        if InstanceFileIO.read(SingleInstanceOwnerRecord.self, from: namespace.ownerURL)?.instanceID == instanceID {
            try? FileManager.default.removeItem(at: namespace.ownerURL)
        }
        ownedLock.release()
    }

    func prepareForShutdown() {
        mailbox.prepareForShutdown()
    }

    func updateInstallationIdentity(_ installationIdentity: AppInstallationIdentity?) -> Bool {
        mailbox.updateInstallationIdentity(installationIdentity)
    }
}

private struct SingleInstanceActivationRequest: Codable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case protocolVersion
        case targetInstanceID
        case requestID
        case action
        case createdAt
        case expiresAt
        case claimantInstanceID
        case claimantPID
        case claimantProcessIdentity
        case claimantInstallationIdentity
    }

    let protocolVersion: Int
    let targetInstanceID: UUID
    let requestID: UUID
    let action: SingleInstanceActivationAction
    let createdAt: Date
    let expiresAt: Date
    let claimantInstanceID: UUID?
    let claimantPID: Int32?
    let claimantProcessIdentity: SingleInstanceProcessIdentity?
    let claimantInstallationIdentity: AppInstallationIdentity?

    init(
        protocolVersion: Int,
        targetInstanceID: UUID,
        requestID: UUID,
        action: SingleInstanceActivationAction,
        createdAt: Date,
        expiresAt: Date,
        claimantInstanceID: UUID? = nil,
        claimantPID: Int32? = nil,
        claimantProcessIdentity: SingleInstanceProcessIdentity? = nil,
        claimantInstallationIdentity: AppInstallationIdentity? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.targetInstanceID = targetInstanceID
        self.requestID = requestID
        self.action = action
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.claimantInstanceID = claimantInstanceID
        self.claimantPID = claimantPID
        self.claimantProcessIdentity = claimantProcessIdentity
        self.claimantInstallationIdentity = claimantInstallationIdentity
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.init(
            protocolVersion: try container.decode(Int.self, forKey: .protocolVersion),
            targetInstanceID: try container.decode(UUID.self, forKey: .targetInstanceID),
            requestID: try container.decode(UUID.self, forKey: .requestID),
            action: try container.decode(SingleInstanceActivationAction.self, forKey: .action),
            createdAt: createdAt,
            // v1 was introduced with this field, but accepting the earliest
            // development payload shape makes rolling local upgrades safe.
            expiresAt: try container.decodeIfPresent(Date.self, forKey: .expiresAt)
                ?? createdAt.addingTimeInterval(2),
            claimantInstanceID: try container.decodeIfPresent(UUID.self, forKey: .claimantInstanceID),
            claimantPID: try container.decodeIfPresent(Int32.self, forKey: .claimantPID),
            claimantProcessIdentity: try container.decodeIfPresent(
                SingleInstanceProcessIdentity.self,
                forKey: .claimantProcessIdentity
            ),
            claimantInstallationIdentity: try container.decodeIfPresent(
                AppInstallationIdentity.self,
                forKey: .claimantInstallationIdentity
            )
        )
    }
}

private struct SingleInstanceActivationAcknowledgement: Codable, Sendable {
    let protocolVersion: Int
    let requestID: UUID
    let targetInstanceID: UUID
    let responderInstanceID: UUID
    let accepted: Bool
    let action: SingleInstanceActivationAction?
    let claimantInstanceID: UUID?
    let claimantPID: Int32?
    let claimantProcessIdentity: SingleInstanceProcessIdentity?
    let claimantInstallationIdentity: AppInstallationIdentity?
    let handoffExpiresAt: Date?
}

struct SingleInstanceHandoffTicket: Codable, Equatable, Sendable {
    let protocolVersion: Int
    let handoffCapabilityVersion: Int
    let requestID: UUID
    let ownerInstanceID: UUID
    let claimantInstanceID: UUID
    let claimantPID: Int32?
    let claimantProcessIdentity: SingleInstanceProcessIdentity?
    let claimantInstallationIdentity: AppInstallationIdentity
    let expiresAt: Date
    let phase: SingleInstanceHandoffPhase?

    init(
        protocolVersion: Int,
        handoffCapabilityVersion: Int,
        requestID: UUID,
        ownerInstanceID: UUID,
        claimantInstanceID: UUID,
        claimantPID: Int32? = ProcessInfo.processInfo.processIdentifier,
        claimantProcessIdentity: SingleInstanceProcessIdentity? = .current(),
        claimantInstallationIdentity: AppInstallationIdentity,
        expiresAt: Date,
        phase: SingleInstanceHandoffPhase? = .authorized
    ) {
        self.protocolVersion = protocolVersion
        self.handoffCapabilityVersion = handoffCapabilityVersion
        self.requestID = requestID
        self.ownerInstanceID = ownerInstanceID
        self.claimantInstanceID = claimantInstanceID
        self.claimantPID = claimantPID
        self.claimantProcessIdentity = claimantProcessIdentity
        self.claimantInstallationIdentity = claimantInstallationIdentity
        self.expiresAt = expiresAt
        self.phase = phase
    }

    var effectivePhase: SingleInstanceHandoffPhase {
        phase ?? .authorized
    }

    func updatingPhase(_ phase: SingleInstanceHandoffPhase) -> SingleInstanceHandoffTicket {
        SingleInstanceHandoffTicket(
            protocolVersion: protocolVersion,
            handoffCapabilityVersion: handoffCapabilityVersion,
            requestID: requestID,
            ownerInstanceID: ownerInstanceID,
            claimantInstanceID: claimantInstanceID,
            claimantPID: claimantPID,
            claimantProcessIdentity: claimantProcessIdentity,
            claimantInstallationIdentity: claimantInstallationIdentity,
            expiresAt: expiresAt,
            phase: phase
        )
    }
}

private final class SingleInstanceHandoffCommitSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var hasBegun = false
    private var wasCancelled = false

    var didBegin: Bool {
        lock.lock()
        defer { lock.unlock() }
        return hasBegun
    }

    func begin(_ prepare: () -> Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !hasBegun, !wasCancelled, prepare() else { return false }
        hasBegun = true
        return true
    }

    func cancelIfPending() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !hasBegun, !wasCancelled else { return false }
        wasCancelled = true
        return true
    }
}

private final class OwnerActivationMailbox: @unchecked Sendable {
    private let namespace: SingleInstanceNamespace
    private let ownedLock: OwnedSingleInstanceLock
    private let activationExecutor: SingleInstanceActivationExecutor
    private let handoffCompletionTimeout: DispatchTimeInterval
    private let handoffVerificationObserver: @Sendable (
        SingleInstanceHandoffVerificationEvent
    ) -> Void
    private let queue = DispatchQueue(label: "com.ryukeilee.CodexMonitorNative.instance-owner-mailbox")
    private let cancellationSemaphore = DispatchSemaphore(value: 0)
    private var record: SingleInstanceOwnerRecord
    private var source: DispatchSourceFileSystemObject?
    private var sourceWasCancelled = false
    private var isStarted = false
    private var isAcceptingActivations = true
    private var isShutdownPrepared = false
    private var inFlightRequestIDs = Set<UUID>()
    private var committingHandoffRequestID: UUID?
    private var submittedHandoffCommitRequestID: UUID?

    init(
        namespace: SingleInstanceNamespace,
        record: SingleInstanceOwnerRecord,
        ownedLock: OwnedSingleInstanceLock,
        activationExecutor: SingleInstanceActivationExecutor,
        handoffCompletionTimeout: DispatchTimeInterval,
        handoffVerificationObserver: @escaping @Sendable (
            SingleInstanceHandoffVerificationEvent
        ) -> Void
    ) {
        self.namespace = namespace
        self.record = record
        self.ownedLock = ownedLock
        self.activationExecutor = activationExecutor
        self.handoffCompletionTimeout = handoffCompletionTimeout
        self.handoffVerificationObserver = handoffVerificationObserver
    }

    deinit {
        stop()
    }

    func start() throws {
        try queue.sync {
            guard !isStarted else { return }
            try removeStaleMessages()

            let directoryDescriptor = Darwin.open(
                namespace.requestsURL.path,
                O_EVTONLY | O_CLOEXEC | O_NOFOLLOW
            )
            guard directoryDescriptor >= 0 else {
                throw SingleInstanceError.posix(operation: "watch requests directory", code: errno)
            }

            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: directoryDescriptor,
                eventMask: [.write, .extend, .attrib, .rename, .delete],
                queue: queue
            )
            source.setEventHandler { [weak self] in
                self?.processPendingRequests()
            }
            source.setCancelHandler { [cancellationSemaphore] in
                Darwin.close(directoryDescriptor)
                cancellationSemaphore.signal()
            }
            self.source = source
            isStarted = true
            source.resume()

            try InstanceFileIO.write(record, to: namespace.ownerURL)
            queue.async { [weak self] in
                self?.processPendingRequests()
            }
        }
    }

    func stop() {
        let shouldWait = queue.sync { () -> Bool in
            guard let source, !sourceWasCancelled else {
                isStarted = false
                return false
            }
            isStarted = false
            sourceWasCancelled = true
            source.cancel()
            self.source = nil
            return true
        }
        if shouldWait {
            cancellationSemaphore.wait()
        }
    }

    func prepareForShutdown() {
        queue.sync {
            isShutdownPrepared = true
            isAcceptingActivations = false
        }
    }

    func updateInstallationIdentity(_ installationIdentity: AppInstallationIdentity?) -> Bool {
        queue.sync {
            guard isStarted, ownedLock.isHeld else { return false }
            let previousRecord = record
            var updatedRecord = record
            updatedRecord.installationIdentity = installationIdentity
            do {
                try InstanceFileIO.write(updatedRecord, to: namespace.ownerURL)
                guard ownedLock.isHeld,
                      let publishedRecord = InstanceFileIO.read(
                        SingleInstanceOwnerRecord.self,
                        from: namespace.ownerURL
                      ),
                      publishedRecord.instanceID == updatedRecord.instanceID,
                      publishedRecord.installationIdentity == installationIdentity else {
                    try? InstanceFileIO.write(previousRecord, to: namespace.ownerURL)
                    return false
                }
                record = updatedRecord
                return true
            } catch {
                try? InstanceFileIO.write(previousRecord, to: namespace.ownerURL)
                return false
            }
        }
    }

    private func processPendingRequests() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard isStarted, isAcceptingActivations else { return }

        let urls = (try? FileManager.default.contentsOfDirectory(
            at: namespace.requestsURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where url.lastPathComponent.hasPrefix("request-") && url.pathExtension == "json" {
            processRequest(at: url)
        }
    }

    private func processRequest(at url: URL) {
        guard let request = InstanceFileIO.read(SingleInstanceActivationRequest.self, from: url) else {
            try? FileManager.default.removeItem(at: url)
            AppLogger.lifecycle.error("Discarded malformed single-instance activation request")
            return
        }

        let isValid = request.protocolVersion == SingleInstanceOwnerRecord.currentProtocolVersion
            && request.targetInstanceID == record.instanceID
        guard isValid, request.expiresAt > .now else {
            completeRequest(request, accepted: false)
            return
        }
        guard inFlightRequestIDs.insert(request.requestID).inserted else { return }

        switch request.action {
        case .showPopover:
            activationExecutor.submit(request.action, expiresAt: request.expiresAt) { [weak self] accepted in
                self?.queue.async { [weak self] in
                    self?.completeRequest(request, accepted: accepted)
                }
            }

        case .requestOwnershipHandoff:
            guard hasCurrentPublishedProcessIdentity,
                  let claimantInstallationIdentity = request.claimantInstallationIdentity,
                  request.claimantInstanceID != nil,
                  let claimantPID = request.claimantPID,
                  let claimantProcessIdentity = request.claimantProcessIdentity,
                  claimantPID > 0,
                  claimantProcessIdentity.pid == claimantPID,
                  claimantProcessIdentity.isCurrentKernelIdentity else {
                completeRequest(request, accepted: false)
                return
            }
            activationExecutor.submitRelinquishment(
                to: claimantInstallationIdentity,
                expiresAt: request.expiresAt
            ) { [weak self] accepted in
                self?.queue.async { [weak self] in
                    self?.completeHandoffRequest(request, accepted: accepted)
                }
            }
        }
    }

    private func completeRequest(
        _ request: SingleInstanceActivationRequest,
        accepted: Bool
    ) {
        dispatchPrecondition(condition: .onQueue(queue))
        inFlightRequestIDs.remove(request.requestID)

        guard isStarted,
              isAcceptingActivations,
              request.expiresAt > .now else {
            try? FileManager.default.removeItem(at: requestURL(for: request.requestID))
            return
        }

        if accepted {
            record.activationCount = record.activationCount == UInt64.max
                ? UInt64.max
                : record.activationCount + 1
            do {
                try InstanceFileIO.write(record, to: namespace.ownerURL)
            } catch {
                AppLogger.lifecycle.error("Failed to update single-instance activation diagnostics: \(error.localizedDescription, privacy: .public)")
            }
        }

        do {
            try writeAcknowledgement(for: request, accepted: accepted)
        } catch {
            AppLogger.lifecycle.error("Failed to acknowledge single-instance activation: \(error.localizedDescription, privacy: .public)")
        }
        try? FileManager.default.removeItem(at: requestURL(for: request.requestID))
    }

    private func completeHandoffRequest(
        _ request: SingleInstanceActivationRequest,
        accepted: Bool
    ) {
        dispatchPrecondition(condition: .onQueue(queue))
        inFlightRequestIDs.remove(request.requestID)

        guard isStarted,
              isAcceptingActivations,
              hasCurrentPublishedProcessIdentity,
              accepted,
              request.expiresAt > .now,
              let claimantInstanceID = request.claimantInstanceID,
              let claimantPID = request.claimantPID,
              let claimantProcessIdentity = request.claimantProcessIdentity,
              claimantPID > 0,
              claimantProcessIdentity.pid == claimantPID,
              claimantProcessIdentity.isCurrentKernelIdentity,
              let claimantInstallationIdentity = request.claimantInstallationIdentity else {
            do {
                try writeAcknowledgement(for: request, accepted: false)
            } catch {
                AppLogger.lifecycle.error("Failed to reject single-instance ownership handoff: \(error.localizedDescription, privacy: .public)")
            }
            try? FileManager.default.removeItem(at: requestURL(for: request.requestID))
            return
        }

        let handoffExpiresAt = Date().addingTimeInterval(
            handoffCompletionTimeout.timeInterval
        )
        let ticket = SingleInstanceHandoffTicket(
            protocolVersion: SingleInstanceOwnerRecord.currentProtocolVersion,
            handoffCapabilityVersion: SingleInstanceOwnerRecord.currentHandoffCapabilityVersion,
            requestID: request.requestID,
            ownerInstanceID: record.instanceID,
            claimantInstanceID: claimantInstanceID,
            claimantPID: claimantPID,
            claimantProcessIdentity: claimantProcessIdentity,
            claimantInstallationIdentity: claimantInstallationIdentity,
            expiresAt: handoffExpiresAt
        )
        do {
            try InstanceFileIO.write(ticket, to: namespace.handoffURL)
            do {
                try writeAcknowledgement(
                    for: request,
                    accepted: true,
                    handoffExpiresAt: handoffExpiresAt
                )
            } catch {
                try? FileManager.default.removeItem(at: namespace.handoffURL)
                throw error
            }
        } catch {
            AppLogger.lifecycle.error("Failed to commit single-instance ownership handoff: \(error.localizedDescription, privacy: .public)")
            try? FileManager.default.removeItem(at: requestURL(for: request.requestID))
            return
        }

        isAcceptingActivations = false
        committingHandoffRequestID = request.requestID
        try? FileManager.default.removeItem(at: requestURL(for: request.requestID))
        let commitSignal = SingleInstanceHandoffCommitSignal()
        let timeoutNanoseconds = boundedNanoseconds(until: handoffExpiresAt)
        queue.asyncAfter(deadline: .now() + .nanoseconds(timeoutNanoseconds)) { [weak self] in
            guard commitSignal.cancelIfPending() else { return }
            self?.cancelUncommittedHandoff(expectedTicket: ticket)
        }
        // The installation identity in the request is authorization input, not
        // proof of the requesting process. The old owner stays operational until
        // the claimant holds the permanent lock and publishes the matching
        // provisional owner record.
        ownedLock.release()
        waitForProvisionalClaimant(expectedTicket: ticket, commitSignal: commitSignal)
    }

    private var hasCurrentPublishedProcessIdentity: Bool {
        guard ownedLock.isHeld,
              let processIdentity = record.processIdentity,
              processIdentity.pid == record.pid,
              processIdentity.isCurrentKernelIdentity,
              let publishedRecord = InstanceFileIO.read(
                SingleInstanceOwnerRecord.self,
                from: namespace.ownerURL
              ),
              publishedRecord.protocolVersion == record.protocolVersion,
              publishedRecord.instanceID == record.instanceID,
              publishedRecord.pid == record.pid,
              publishedRecord.installationIdentity == record.installationIdentity,
              publishedRecord.handoffCapabilityVersion == record.handoffCapabilityVersion,
              publishedRecord.activationCount == record.activationCount,
              publishedRecord.processIdentity == processIdentity,
              publishedRecord.ownershipState == record.ownershipState,
              publishedRecord.handoffRequestID == record.handoffRequestID else {
            return false
        }
        return true
    }

    private func waitForProvisionalClaimant(
        expectedTicket: SingleInstanceHandoffTicket,
        commitSignal: SingleInstanceHandoffCommitSignal
    ) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard isStarted,
              committingHandoffRequestID == expectedTicket.requestID,
              submittedHandoffCommitRequestID == nil else {
            return
        }
        guard Date() < expectedTicket.expiresAt else {
            if commitSignal.cancelIfPending() {
                cancelUncommittedHandoff(expectedTicket: expectedTicket)
            }
            return
        }
        guard provisionalClaimantHoldsLock(expectedTicket) else {
            queue.asyncAfter(deadline: .now() + .milliseconds(10)) { [weak self] in
                self?.waitForProvisionalClaimant(
                    expectedTicket: expectedTicket,
                    commitSignal: commitSignal
                )
            }
            return
        }

        submittedHandoffCommitRequestID = expectedTicket.requestID
        activationExecutor.commitRelinquishment(
            expiresAt: expectedTicket.expiresAt,
            begin: { [weak self] in
                commitSignal.begin {
                    guard let self,
                          self.provisionalClaimantHoldsLock(expectedTicket) else {
                        return false
                    }
                    guard self.publishTicketPhase(
                        .committing,
                        expectedTicket: expectedTicket
                    ) else {
                        return false
                    }
                    // A visible .committing phase is the irreversible boundary:
                    // the claimant may finalize immediately after observing it.
                    // Nothing after publication may cancel or make begin fail.
                    self.handoffVerificationObserver(.didPublishCommitting)
                    if !self.provisionalClaimantHoldsLock(
                        expectedTicket,
                        allowsFinalOwnerRecord: true
                    ) {
                        AppLogger.lifecycle.error("Ownership claimant changed after irreversible commit publication")
                    }
                    return true
                }
            }
        ) { [weak self] succeeded in
            self?.queue.async { [weak self] in
                self?.finishHandoffCommit(
                    expectedTicket: expectedTicket,
                    commitSignal: commitSignal,
                    succeeded: succeeded
                )
            }
        }
    }

    private func cancelUncommittedHandoff(
        expectedTicket: SingleInstanceHandoffTicket
    ) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard committingHandoffRequestID == expectedTicket.requestID else { return }
        _ = publishTicketPhase(.cancelled, expectedTicket: expectedTicket)
        submittedHandoffCommitRequestID = nil
        AppLogger.lifecycle.error("Single-instance ownership handoff timed out before irreversible commit; reclaiming ownership")
        reclaimOwnershipAfterCancelledHandoff(expectedTicket: expectedTicket)
    }

    private func reclaimOwnershipAfterCancelledHandoff(
        expectedTicket: SingleInstanceHandoffTicket,
        retryDelay: DispatchTimeInterval = .milliseconds(10)
    ) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard isStarted,
              committingHandoffRequestID == expectedTicket.requestID else { return }
        if ownedLock.isHeld {
            do {
                try restoreOriginalOwnerAfterCancelledHandoff(expectedTicket: expectedTicket)
            } catch {
                queue.asyncAfter(deadline: .now() + retryDelay) { [weak self] in
                    self?.reclaimOwnershipAfterCancelledHandoff(
                        expectedTicket: expectedTicket,
                        retryDelay: retryDelay
                    )
                }
            }
            return
        }
        do {
            switch try namespace.openAndTryLock() {
            case .acquired(let descriptor):
                guard ownedLock.adopt(descriptor) else {
                    Darwin.close(descriptor)
                    return
                }
                try restoreOriginalOwnerAfterCancelledHandoff(expectedTicket: expectedTicket)

            case .contended(let descriptor):
                Darwin.close(descriptor)
                queue.asyncAfter(deadline: .now() + retryDelay) { [weak self] in
                    self?.reclaimOwnershipAfterCancelledHandoff(
                        expectedTicket: expectedTicket,
                        retryDelay: retryDelay
                    )
                }
            }
        } catch {
            queue.asyncAfter(deadline: .now() + retryDelay) { [weak self] in
                self?.reclaimOwnershipAfterCancelledHandoff(
                    expectedTicket: expectedTicket,
                    retryDelay: retryDelay
                )
            }
        }
    }

    private func restoreOriginalOwnerAfterCancelledHandoff(
        expectedTicket: SingleInstanceHandoffTicket
    ) throws {
        dispatchPrecondition(condition: .onQueue(queue))
        try InstanceFileIO.write(record, to: namespace.ownerURL)
        if InstanceFileIO.read(
            SingleInstanceHandoffTicket.self,
            from: namespace.handoffURL
        )?.requestID == expectedTicket.requestID {
            try? FileManager.default.removeItem(at: namespace.handoffURL)
        }
        committingHandoffRequestID = nil
        submittedHandoffCommitRequestID = nil
        isAcceptingActivations = !isShutdownPrepared
        AppLogger.lifecycle.info("Cancelled ownership handoff restored the original owner")
        if isAcceptingActivations {
            processPendingRequests()
        }
    }

    private func finishHandoffCommit(
        expectedTicket: SingleInstanceHandoffTicket,
        commitSignal: SingleInstanceHandoffCommitSignal,
        succeeded: Bool
    ) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard isStarted,
              committingHandoffRequestID == expectedTicket.requestID else { return }

        guard commitSignal.didBegin else {
            _ = publishTicketPhase(.cancelled, expectedTicket: expectedTicket)
            AppLogger.lifecycle.error("Single-instance ownership handoff commit was rejected; reclaiming ownership")
            reclaimOwnershipAfterCancelledHandoff(expectedTicket: expectedTicket)
            return
        }

        let claimantStillOwns = provisionalClaimantHoldsLock(
            expectedTicket,
            allowsFinalOwnerRecord: true
        )
        if claimantStillOwns {
            _ = publishTicketPhase(.committed, expectedTicket: expectedTicket)
        } else {
            AppLogger.lifecycle.error("Committed ownership handoff claimant disappeared after proving ownership")
        }
        if !succeeded {
            AppLogger.lifecycle.error("Ownership handoff callback rejected after the irreversible boundary; keeping claimant authoritative")
        }
        committingHandoffRequestID = nil
        submittedHandoffCommitRequestID = nil
        activationExecutor.relinquishmentDidComplete()
    }

    private func provisionalClaimantHoldsLock(
        _ ticket: SingleInstanceHandoffTicket,
        allowsFinalOwnerRecord: Bool = false
    ) -> Bool {
        guard let claimantPID = ticket.claimantPID,
              claimantPID > 0,
              let claimantProcessIdentity = ticket.claimantProcessIdentity,
              claimantProcessIdentity.pid == claimantPID,
              claimantProcessIdentity.isCurrentKernelIdentity,
              let before = InstanceFileIO.read(
                SingleInstanceOwnerRecord.self,
                from: namespace.ownerURL
              ),
              claimantRecordMatches(
                before,
                ticket: ticket,
                claimantPID: claimantPID,
                claimantProcessIdentity: claimantProcessIdentity,
                allowsFinalOwnerRecord: allowsFinalOwnerRecord
              ) else {
            return false
        }
        handoffVerificationObserver(.didReadCandidateBeforeLockProbe)
        do {
            guard let lockAttempt = try namespace.openExistingAndTryLock() else { return false }
            switch lockAttempt {
            case .acquired(let descriptor):
                Darwin.close(descriptor)
                return false
            case .contended(let descriptor):
                Darwin.close(descriptor)
            }
        } catch {
            return false
        }
        guard claimantProcessIdentity.isCurrentKernelIdentity,
              let after = InstanceFileIO.read(
                SingleInstanceOwnerRecord.self,
                from: namespace.ownerURL
              ),
              after == before,
              claimantRecordMatches(
                after,
                ticket: ticket,
                claimantPID: claimantPID,
                claimantProcessIdentity: claimantProcessIdentity,
                allowsFinalOwnerRecord: allowsFinalOwnerRecord
              ) else {
            return false
        }
        return true
    }

    private func claimantRecordMatches(
        _ claimantRecord: SingleInstanceOwnerRecord,
        ticket: SingleInstanceHandoffTicket,
        claimantPID: Int32,
        claimantProcessIdentity: SingleInstanceProcessIdentity,
        allowsFinalOwnerRecord: Bool
    ) -> Bool {
        claimantRecord.instanceID == ticket.claimantInstanceID
            && claimantRecord.pid == claimantPID
            && claimantRecord.processIdentity == claimantProcessIdentity
            && claimantRecord.installationIdentity == ticket.claimantInstallationIdentity
            && (claimantRecord.ownershipState == .provisionalHandoff
                && claimantRecord.handoffRequestID == ticket.requestID
                || allowsFinalOwnerRecord
                    && claimantRecord.ownershipState == nil
                    && claimantRecord.handoffRequestID == nil)
    }

    private func publishTicketPhase(
        _ phase: SingleInstanceHandoffPhase,
        expectedTicket: SingleInstanceHandoffTicket
    ) -> Bool {
        guard let current = InstanceFileIO.read(
            SingleInstanceHandoffTicket.self,
            from: namespace.handoffURL
        ), current.requestID == expectedTicket.requestID,
           current.ownerInstanceID == expectedTicket.ownerInstanceID,
           current.claimantInstanceID == expectedTicket.claimantInstanceID,
           current.claimantPID == expectedTicket.claimantPID,
           current.claimantProcessIdentity == expectedTicket.claimantProcessIdentity,
           current.claimantInstallationIdentity == expectedTicket.claimantInstallationIdentity else {
            return false
        }
        do {
            try InstanceFileIO.write(current.updatingPhase(phase), to: namespace.handoffURL)
            return true
        } catch {
            return false
        }
    }

    private func boundedNanoseconds(until date: Date) -> Int {
        let maximum = max(0, handoffCompletionTimeout.timeInterval)
        let remaining = min(maximum, max(0, date.timeIntervalSinceNow))
        return Int(min(remaining * 1_000_000_000, Double(Int.max)))
    }

    private func writeAcknowledgement(
        for request: SingleInstanceActivationRequest,
        accepted: Bool,
        handoffExpiresAt: Date? = nil
    ) throws {
        let acknowledgement = SingleInstanceActivationAcknowledgement(
            protocolVersion: SingleInstanceOwnerRecord.currentProtocolVersion,
            requestID: request.requestID,
            targetInstanceID: request.targetInstanceID,
            responderInstanceID: record.instanceID,
            accepted: accepted,
            action: request.action,
            claimantInstanceID: request.claimantInstanceID,
            claimantPID: request.claimantPID,
            claimantProcessIdentity: request.claimantProcessIdentity,
            claimantInstallationIdentity: request.claimantInstallationIdentity,
            handoffExpiresAt: handoffExpiresAt
        )
        try InstanceFileIO.write(
            acknowledgement,
            to: acknowledgementURL(for: request.requestID)
        )
    }

    private func removeStaleMessages() throws {
        for directory in [namespace.requestsURL, namespace.acknowledgementsURL] {
            let urls = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: []
            )
            for url in urls where url.pathExtension == "json"
                || url.lastPathComponent.hasPrefix(".tmp-") {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private func acknowledgementURL(for requestID: UUID) -> URL {
        namespace.acknowledgementsURL
            .appendingPathComponent("ack-\(requestID.uuidString).json")
    }

    private func requestURL(for requestID: UUID) -> URL {
        namespace.requestsURL
            .appendingPathComponent("request-\(requestID.uuidString).json")
    }
}

private struct SingleInstanceAcceptedHandoff {
    let requestID: UUID
    let ownerInstanceID: UUID
    let expiresAt: Date
}

private enum SingleInstanceHandoffAttempt {
    case accepted(SingleInstanceAcceptedHandoff)
    case rejected
    case unacknowledged
}

private struct SingleInstanceActivationClient {
    let namespace: SingleInstanceNamespace
    let ownerReadyTimeout: DispatchTimeInterval
    let acknowledgementTimeout: DispatchTimeInterval

    func forward(_ action: SingleInstanceActivationAction) -> Bool {
        guard let owner = waitForOwnerRecord() else {
            return false
        }

        let requestID = UUID()
        let acknowledgementURL = namespace.acknowledgementsURL
            .appendingPathComponent("ack-\(requestID.uuidString).json")
        guard let waiter = try? DirectoryChangeWaiter(directoryURL: namespace.acknowledgementsURL) else {
            return false
        }

        let request = SingleInstanceActivationRequest(
            protocolVersion: SingleInstanceOwnerRecord.currentProtocolVersion,
            targetInstanceID: owner.instanceID,
            requestID: requestID,
            action: action,
            createdAt: .now,
            expiresAt: Date().addingTimeInterval(acknowledgementTimeout.timeInterval)
        )
        let requestURL = namespace.requestsURL
            .appendingPathComponent("request-\(requestID.uuidString).json")
        do {
            try InstanceFileIO.write(request, to: requestURL)
        } catch {
            return false
        }

        guard let acknowledgement: SingleInstanceActivationAcknowledgement = waitForValue(
            at: acknowledgementURL,
            waiter: waiter,
            timeout: acknowledgementTimeout
        ) else {
            try? FileManager.default.removeItem(at: requestURL)
            return false
        }
        try? FileManager.default.removeItem(at: acknowledgementURL)
        return acknowledgement.protocolVersion == SingleInstanceOwnerRecord.currentProtocolVersion
            && acknowledgement.requestID == requestID
            && acknowledgement.targetInstanceID == owner.instanceID
            && acknowledgement.responderInstanceID == owner.instanceID
            && acknowledgement.accepted
    }

    func requestOwnershipHandoff(
        from owner: SingleInstanceOwnerRecord,
        claimantInstanceID: UUID,
        claimantPID: Int32,
        claimantInstallationIdentity: AppInstallationIdentity
    ) -> SingleInstanceHandoffAttempt {
        guard let claimantProcessIdentity = SingleInstanceProcessIdentity.current(),
              claimantProcessIdentity.pid == claimantPID else {
            return .unacknowledged
        }
        let requestID = UUID()
        let acknowledgementURL = namespace.acknowledgementsURL
            .appendingPathComponent("ack-\(requestID.uuidString).json")
        guard let waiter = try? DirectoryChangeWaiter(directoryURL: namespace.acknowledgementsURL) else {
            return .unacknowledged
        }

        let expiresAt = Date().addingTimeInterval(acknowledgementTimeout.timeInterval)
        let request = SingleInstanceActivationRequest(
            protocolVersion: SingleInstanceOwnerRecord.currentProtocolVersion,
            targetInstanceID: owner.instanceID,
            requestID: requestID,
            action: .requestOwnershipHandoff,
            createdAt: .now,
            expiresAt: expiresAt,
            claimantInstanceID: claimantInstanceID,
            claimantPID: claimantPID,
            claimantProcessIdentity: claimantProcessIdentity,
            claimantInstallationIdentity: claimantInstallationIdentity
        )
        let requestURL = namespace.requestsURL
            .appendingPathComponent("request-\(requestID.uuidString).json")
        do {
            try InstanceFileIO.write(request, to: requestURL)
        } catch {
            return .unacknowledged
        }

        guard let acknowledgement: SingleInstanceActivationAcknowledgement = waitForValue(
            at: acknowledgementURL,
            waiter: waiter,
            timeout: acknowledgementTimeout
        ) else {
            try? FileManager.default.removeItem(at: requestURL)
            return .unacknowledged
        }
        try? FileManager.default.removeItem(at: acknowledgementURL)

        let isBoundToRequest = acknowledgement.protocolVersion == SingleInstanceOwnerRecord.currentProtocolVersion
            && acknowledgement.requestID == requestID
            && acknowledgement.targetInstanceID == owner.instanceID
            && acknowledgement.responderInstanceID == owner.instanceID
            && acknowledgement.action == .requestOwnershipHandoff
            && acknowledgement.claimantInstanceID == claimantInstanceID
            && acknowledgement.claimantPID == claimantPID
            && acknowledgement.claimantProcessIdentity == claimantProcessIdentity
            && acknowledgement.claimantInstallationIdentity == claimantInstallationIdentity
        guard isBoundToRequest else {
            return .unacknowledged
        }
        let handoffExpiresAt = acknowledgement.handoffExpiresAt ?? expiresAt
        guard handoffExpiresAt > .now else {
            return .unacknowledged
        }
        return acknowledgement.accepted
            ? .accepted(SingleInstanceAcceptedHandoff(
                requestID: requestID,
                ownerInstanceID: owner.instanceID,
                expiresAt: handoffExpiresAt
            ))
            : .rejected
    }

    func waitForOwnerRecord() -> SingleInstanceOwnerRecord? {
        guard let waiter = try? DirectoryChangeWaiter(directoryURL: namespace.rootURL) else {
            return nil
        }
        let record: SingleInstanceOwnerRecord? = waitForValue(
            at: namespace.ownerURL,
            waiter: waiter,
            timeout: ownerReadyTimeout
        )
        guard record?.protocolVersion == SingleInstanceOwnerRecord.currentProtocolVersion else {
            return nil
        }
        return record
    }

    private func waitForValue<Value: Decodable>(
        at url: URL,
        waiter: DirectoryChangeWaiter,
        timeout: DispatchTimeInterval
    ) -> Value? {
        let deadline = DispatchTime.now() + timeout
        while true {
            if let value = InstanceFileIO.read(Value.self, from: url) {
                return value
            }
            if waiter.wait(until: deadline) == .timedOut {
                return InstanceFileIO.read(Value.self, from: url)
            }
        }
    }
}

private extension DispatchTimeInterval {
    var timeInterval: TimeInterval {
        switch self {
        case .seconds(let value):
            return TimeInterval(value)
        case .milliseconds(let value):
            return TimeInterval(value) / 1_000
        case .microseconds(let value):
            return TimeInterval(value) / 1_000_000
        case .nanoseconds(let value):
            return TimeInterval(value) / 1_000_000_000
        case .never:
            return 60
        @unknown default:
            return 2
        }
    }
}

private final class DirectoryChangeWaiter {
    private let source: DispatchSourceFileSystemObject
    private let eventSemaphore = DispatchSemaphore(value: 0)
    private let cancellationSemaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var didCancel = false

    init(directoryURL: URL) throws {
        let descriptor = Darwin.open(
            directoryURL.path,
            O_EVTONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            throw SingleInstanceError.posix(operation: "watch \(directoryURL.lastPathComponent)", code: errno)
        }

        let queue = DispatchQueue(label: "com.ryukeilee.CodexMonitorNative.instance-waiter.\(UUID().uuidString)")
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .rename, .delete],
            queue: queue
        )
        let eventSemaphore = self.eventSemaphore
        source.setEventHandler {
            eventSemaphore.signal()
        }
        let cancellationSemaphore = self.cancellationSemaphore
        source.setCancelHandler {
            Darwin.close(descriptor)
            cancellationSemaphore.signal()
        }
        source.resume()
    }

    deinit {
        cancel()
    }

    func wait(until deadline: DispatchTime) -> DispatchTimeoutResult {
        eventSemaphore.wait(timeout: deadline)
    }

    private func cancel() {
        lock.lock()
        guard !didCancel else {
            lock.unlock()
            return
        }
        didCancel = true
        lock.unlock()

        source.cancel()
        cancellationSemaphore.wait()
    }
}

private enum InstanceFileIO {
    static func read<Value: Decodable>(_ type: Value.Type, from url: URL) -> Value? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try? decoder.decode(type, from: data)
    }

    static func write<Value: Encodable>(_ value: Value, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)

        let temporaryURL = url.deletingLastPathComponent()
            .appendingPathComponent(".tmp-\(UUID().uuidString)")
        var descriptor = Darwin.open(
            temporaryURL.path,
            O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard descriptor >= 0 else {
            throw SingleInstanceError.posix(operation: "create \(url.lastPathComponent)", code: errno)
        }
        defer {
            if descriptor >= 0 {
                Darwin.close(descriptor)
            }
            try? FileManager.default.removeItem(at: temporaryURL)
        }

        if Darwin.fchmod(descriptor, mode_t(S_IRUSR | S_IWUSR)) != 0 {
            throw SingleInstanceError.posix(operation: "fchmod \(url.lastPathComponent)", code: errno)
        }

        try data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            var written = 0
            while written < buffer.count {
                let result = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: written),
                    buffer.count - written
                )
                if result < 0 {
                    let code = errno
                    if code == EINTR { continue }
                    throw SingleInstanceError.posix(operation: "write \(url.lastPathComponent)", code: code)
                }
                guard result > 0 else {
                    throw SingleInstanceError.posix(operation: "write \(url.lastPathComponent)", code: EIO)
                }
                written += result
            }
        }
        if Darwin.fsync(descriptor) != 0 {
            throw SingleInstanceError.posix(operation: "fsync \(url.lastPathComponent)", code: errno)
        }
        if Darwin.close(descriptor) != 0 {
            descriptor = -1
            throw SingleInstanceError.posix(operation: "close \(url.lastPathComponent)", code: errno)
        }
        descriptor = -1
        if Darwin.rename(temporaryURL.path, url.path) != 0 {
            throw SingleInstanceError.posix(operation: "publish \(url.lastPathComponent)", code: errno)
        }
    }
}

private enum SingleInstanceError: Error, LocalizedError {
    case posix(operation: String, code: Int32)
    case invalidFilesystemObject(String)
    case ownershipReservedForAnotherClaimant
    case missingOwnershipHandoffTicket
    case expiredOwnershipHandoffTicket
    case ownerRecordVerificationFailed

    var errorDescription: String? {
        switch self {
        case .posix(let operation, let code):
            return Self.posixDescription(operation: operation, code: code)
        case .invalidFilesystemObject(let path):
            return "Unsafe single-instance filesystem object: \(path)"
        case .ownershipReservedForAnotherClaimant:
            return "Single-instance ownership is reserved for another claimant"
        case .missingOwnershipHandoffTicket:
            return "Single-instance ownership handoff ticket is missing"
        case .expiredOwnershipHandoffTicket:
            return "Single-instance ownership handoff ticket expired"
        case .ownerRecordVerificationFailed:
            return "Single-instance owner record verification failed"
        }
    }

    static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    static func posixDescription(operation: String, code: Int32) -> String {
        let message = String(cString: strerror(code))
        return "Single-instance \(operation) failed (\(code)): \(message)"
    }
}
