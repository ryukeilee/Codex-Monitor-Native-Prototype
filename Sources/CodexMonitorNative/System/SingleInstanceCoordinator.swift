import Darwin
import Dispatch
import Foundation

enum SingleInstanceActivationAction: String, Codable, Sendable {
    case showPopover
}

struct SingleInstanceOwnerRecord: Codable, Equatable, Sendable {
    static let currentProtocolVersion = 1

    let protocolVersion: Int
    let instanceID: UUID
    let pid: Int32
    let startedAt: Date
    var activationCount: UInt64

    init(
        instanceID: UUID,
        pid: Int32 = ProcessInfo.processInfo.processIdentifier,
        startedAt: Date = .now,
        activationCount: UInt64 = 0
    ) {
        self.protocolVersion = Self.currentProtocolVersion
        self.instanceID = instanceID
        self.pid = pid
        self.startedAt = startedAt
        self.activationCount = activationCount
    }
}

struct SingleInstanceConfiguration: Sendable {
    let namespaceURL: URL
    let ownerReadyTimeout: DispatchTimeInterval
    let acknowledgementTimeout: DispatchTimeInterval

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
            acknowledgementTimeout: .seconds(2)
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

    init(
        submitAction: @escaping @Sendable (
            SingleInstanceActivationAction,
            Date,
            @escaping @Sendable (Bool) -> Void
        ) -> Void
    ) {
        self.submitAction = submitAction
    }

    func submit(
        _ action: SingleInstanceActivationAction,
        expiresAt: Date,
        completion: @escaping @Sendable (Bool) -> Void
    ) {
        submitAction(action, expiresAt, completion)
    }

    static func mainActor(
        _ handler: @escaping @MainActor @Sendable (SingleInstanceActivationAction) -> Bool
    ) -> SingleInstanceActivationExecutor {
        SingleInstanceActivationExecutor { action, expiresAt, completion in
            Task { @MainActor in
                guard expiresAt > .now else {
                    completion(false)
                    return
                }
                completion(handler(action))
            }
        }
    }

    static func immediate(
        _ handler: @escaping @Sendable (SingleInstanceActivationAction) -> Bool
    ) -> SingleInstanceActivationExecutor {
        SingleInstanceActivationExecutor { action, expiresAt, completion in
            completion(expiresAt > .now && handler(action))
        }
    }
}

@MainActor
final class SingleInstanceCoordinator {
    private let configuration: SingleInstanceConfiguration
    private var lease: OwnedSingleInstanceLease?

    init(configuration: SingleInstanceConfiguration = .live()) {
        self.configuration = configuration
    }

    func claim(
        onActivation: @escaping @MainActor @Sendable (SingleInstanceActivationAction) -> Bool
    ) -> SingleInstanceClaimResult {
        claim(using: .mainActor(onActivation))
    }

    func claim(using activationExecutor: SingleInstanceActivationExecutor) -> SingleInstanceClaimResult {
        if lease != nil {
            return .owner
        }

        let namespace = SingleInstanceNamespace(rootURL: configuration.namespaceURL)
        do {
            try namespace.prepare()
            let lockAttempt = try namespace.openAndTryLock()
            switch lockAttempt {
            case .acquired(let descriptor):
                return becomeOwner(
                    descriptor: descriptor,
                    namespace: namespace,
                    activationExecutor: activationExecutor
                )

            case .contended(let descriptor):
                return forwardOrTakeOver(
                    descriptor: descriptor,
                    namespace: namespace,
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

    private func forwardOrTakeOver(
        descriptor: Int32,
        namespace: SingleInstanceNamespace,
        activationExecutor: SingleInstanceActivationExecutor
    ) -> SingleInstanceClaimResult {
        let client = SingleInstanceActivationClient(
            namespace: namespace,
            ownerReadyTimeout: configuration.ownerReadyTimeout,
            acknowledgementTimeout: configuration.acknowledgementTimeout
        )

        if client.forward(.showPopover) {
            Darwin.close(descriptor)
            return .secondary(forwardedActivation: true)
        }

        switch tryLockAgain(descriptor) {
        case .acquired:
            return becomeOwner(
                descriptor: descriptor,
                namespace: namespace,
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
        activationExecutor: SingleInstanceActivationExecutor
    ) -> SingleInstanceClaimResult {
        let instanceID = UUID()
        do {
            // owner.json is diagnostic/readiness state, never the authority.
            // The permanent owner.lock inode remains untouched.
            try? FileManager.default.removeItem(at: namespace.ownerURL)
            let mailbox = OwnerActivationMailbox(
                namespace: namespace,
                record: SingleInstanceOwnerRecord(instanceID: instanceID),
                activationExecutor: activationExecutor
            )
            try mailbox.start()
            lease = OwnedSingleInstanceLease(
                descriptor: descriptor,
                namespace: namespace,
                instanceID: instanceID,
                mailbox: mailbox
            )
            return .owner
        } catch {
            Darwin.close(descriptor)
            return .failed(reason: SingleInstanceError.describe(error))
        }
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

private final class OwnedSingleInstanceLease: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32
    private let namespace: SingleInstanceNamespace
    private let instanceID: UUID
    private let mailbox: OwnerActivationMailbox
    private var didRelease = false

    init(
        descriptor: Int32,
        namespace: SingleInstanceNamespace,
        instanceID: UUID,
        mailbox: OwnerActivationMailbox
    ) {
        self.descriptor = descriptor
        self.namespace = namespace
        self.instanceID = instanceID
        self.mailbox = mailbox
    }

    deinit {
        release()
    }

    func release() {
        lock.lock()
        guard !didRelease else {
            lock.unlock()
            return
        }
        didRelease = true
        let descriptor = self.descriptor
        self.descriptor = -1
        lock.unlock()

        mailbox.stop()
        if InstanceFileIO.read(SingleInstanceOwnerRecord.self, from: namespace.ownerURL)?.instanceID == instanceID {
            try? FileManager.default.removeItem(at: namespace.ownerURL)
        }
        if descriptor >= 0 {
            Darwin.close(descriptor)
        }
    }

    func prepareForShutdown() {
        mailbox.prepareForShutdown()
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
    }

    let protocolVersion: Int
    let targetInstanceID: UUID
    let requestID: UUID
    let action: SingleInstanceActivationAction
    let createdAt: Date
    let expiresAt: Date

    init(
        protocolVersion: Int,
        targetInstanceID: UUID,
        requestID: UUID,
        action: SingleInstanceActivationAction,
        createdAt: Date,
        expiresAt: Date
    ) {
        self.protocolVersion = protocolVersion
        self.targetInstanceID = targetInstanceID
        self.requestID = requestID
        self.action = action
        self.createdAt = createdAt
        self.expiresAt = expiresAt
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
                ?? createdAt.addingTimeInterval(2)
        )
    }
}

private struct SingleInstanceActivationAcknowledgement: Codable, Sendable {
    let protocolVersion: Int
    let requestID: UUID
    let targetInstanceID: UUID
    let responderInstanceID: UUID
    let accepted: Bool
}

private final class OwnerActivationMailbox: @unchecked Sendable {
    private let namespace: SingleInstanceNamespace
    private let activationExecutor: SingleInstanceActivationExecutor
    private let queue = DispatchQueue(label: "com.ryukeilee.CodexMonitorNative.instance-owner-mailbox")
    private let cancellationSemaphore = DispatchSemaphore(value: 0)
    private var record: SingleInstanceOwnerRecord
    private var source: DispatchSourceFileSystemObject?
    private var sourceWasCancelled = false
    private var isStarted = false
    private var isAcceptingActivations = true
    private var inFlightRequestIDs = Set<UUID>()

    init(
        namespace: SingleInstanceNamespace,
        record: SingleInstanceOwnerRecord,
        activationExecutor: SingleInstanceActivationExecutor
    ) {
        self.namespace = namespace
        self.record = record
        self.activationExecutor = activationExecutor
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
            isAcceptingActivations = false
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
            && request.action == .showPopover
        guard isValid, request.expiresAt > .now else {
            completeRequest(request, accepted: false)
            return
        }
        guard inFlightRequestIDs.insert(request.requestID).inserted else { return }

        activationExecutor.submit(request.action, expiresAt: request.expiresAt) { [weak self] accepted in
            self?.queue.async { [weak self] in
                self?.completeRequest(request, accepted: accepted)
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

        let acknowledgement = SingleInstanceActivationAcknowledgement(
            protocolVersion: SingleInstanceOwnerRecord.currentProtocolVersion,
            requestID: request.requestID,
            targetInstanceID: request.targetInstanceID,
            responderInstanceID: record.instanceID,
            accepted: accepted
        )
        do {
            try InstanceFileIO.write(
                acknowledgement,
                to: acknowledgementURL(for: request.requestID)
            )
        } catch {
            AppLogger.lifecycle.error("Failed to acknowledge single-instance activation: \(error.localizedDescription, privacy: .public)")
        }
        try? FileManager.default.removeItem(at: requestURL(for: request.requestID))
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

    private func waitForOwnerRecord() -> SingleInstanceOwnerRecord? {
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

    var errorDescription: String? {
        switch self {
        case .posix(let operation, let code):
            return Self.posixDescription(operation: operation, code: code)
        case .invalidFilesystemObject(let path):
            return "Unsafe single-instance filesystem object: \(path)"
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
