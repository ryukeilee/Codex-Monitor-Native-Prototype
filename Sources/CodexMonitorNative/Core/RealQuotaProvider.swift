import Foundation
import CoreFoundation

protocol RealQuotaRefreshing: Sendable {
    func fetchQuota() async throws -> QuotaSnapshot
}

enum RealQuotaError: LocalizedError, Equatable {
    case codexNotFound
    case spawnFailed
    case handshakeFailed
    case requestTimedOut
    case authenticationRequired
    case rpcRejected(code: Int64)
    case responseInvalid
    case noUsableRateLimits
    case processExited(Int32)
    case transportFailed
    case unsupportedServerRequest
    case processCleanupFailed

    var errorDescription: String? {
        switch self {
        case .codexNotFound:
            return "Codex executable not found"
        case .spawnFailed:
            return "Failed to launch Codex"
        case .handshakeFailed:
            return "Codex app-server handshake failed"
        case .requestTimedOut:
            return "Codex app-server request timed out"
        case .authenticationRequired:
            return "Codex authentication is required"
        case .rpcRejected(let code):
            return "Codex RPC request rejected (code \(code))"
        case .responseInvalid:
            return "Codex app-server response is invalid"
        case .noUsableRateLimits:
            return "No usable rate limits in response"
        case .processExited(let code):
            return "Codex process exited (code \(code))"
        case .transportFailed:
            return "Codex app-server transport failed"
        case .unsupportedServerRequest:
            return "Codex app-server sent an unsupported request"
        case .processCleanupFailed:
            return "Failed to clean up Codex process"
        }
    }

    /// Classify this error into a QuotaRefreshStatus for the state machine.
    var refreshStatus: QuotaRefreshStatus {
        switch self {
        case .codexNotFound:
            return .noSnapshot
        case .spawnFailed, .handshakeFailed, .requestTimedOut, .processExited, .transportFailed,
             .unsupportedServerRequest, .processCleanupFailed:
            return .networkFailed
        case .authenticationRequired:
            return .authRequired
        case .rpcRejected:
            return .networkFailed
        case .responseInvalid, .noUsableRateLimits:
            return .parseFailed
        }
    }

    var healthKind: RealQuotaHealthDiagnostic.Kind {
        switch self {
        case .codexNotFound:
            return .executableMissing
        case .spawnFailed, .handshakeFailed, .processExited, .transportFailed,
             .unsupportedServerRequest, .processCleanupFailed:
            return .codexUnavailable
        case .requestTimedOut:
            return .requestTimedOut
        case .authenticationRequired:
            return .loginRequired
        case .rpcRejected:
            return .rpcRejected
        case .responseInvalid, .noUsableRateLimits:
            return .responseInvalid
        }
    }
}

private enum RateLimitResponseSchema {
    static let legacyContainerKeys = ["rateLimits", "rate_limits"]
    static let dynamicContainerKeys = ["rateLimitsByLimitId", "rate_limits_by_limit_id"]
    static let resetCreditsKeys = ["rateLimitResetCredits", "rate_limit_reset_credits"]
    static let containerKeys = legacyContainerKeys + dynamicContainerKeys

    static let usedPercentKeys = ["usedPercent", "used_percent"]
    static let remainingPercentKeys = ["remainingPercent", "remaining_percent"]
    static let durationKeys = [
        "windowDurationMins",
        "window_duration_mins",
        "windowDurationMinutes",
        "window_duration_minutes",
        "durationMinutes",
        "duration_minutes"
    ]
    static let resetAtKeys = [
        "resetAt",
        "reset_at",
        "resetsAt",
        "resets_at",
        "nextResetAt",
        "next_reset_at",
        "windowResetAt",
        "window_reset_at"
    ]
    static let windowSignalKeys = Set(
        usedPercentKeys + remainingPercentKeys + durationKeys + resetAtKeys
    )
    static let knownNonWindowKeys: Set<String> = [
        "credits",
        "individualLimit",
        "individual_limit",
        "limitId",
        "limit_id",
        "limitName",
        "limit_name",
        "planType",
        "plan_type",
        "rateLimitReachedType",
        "rate_limit_reached_type"
    ]
}

private enum ConflictingSchemaValue {
    case marker
}

protocol CodexRPCCancellable: Sendable {
    func cancel()
}

protocol CodexRPCTimeoutScheduling: Sendable {
    func schedule(after seconds: Double, action: @escaping @Sendable () -> Void) -> any CodexRPCCancellable
}

protocol CodexRPCTransport: Sendable {
    func start(
        stdout: @escaping @Sendable (Data) -> Void,
        stdoutEOF: @escaping @Sendable () -> Void,
        stderr: @escaping @Sendable (Data) -> Void,
        termination: @escaping @Sendable (Int32) -> Void
    ) throws
    func write(_ data: Data) throws
    func shutdownAndWait() throws
}

enum ProcessCleanupError: Error, Equatable {
    case forceKillFailed
    case processDidNotExit
}

protocol ProcessRPCProcess: AnyObject, Sendable {
    var isRunning: Bool { get }
    var terminationStatus: Int32 { get }
    var terminationHandler: (@Sendable (any ProcessRPCProcess) -> Void)? { get set }
    func configure(codexPath: String, stdin: Pipe, stdout: Pipe, stderr: Pipe)
    func run() throws
    func terminate()
    func kill() -> Bool
}

private final class FoundationProcessRPCProcess: ProcessRPCProcess, @unchecked Sendable {
    private let process = Process()
    private var handler: (@Sendable (any ProcessRPCProcess) -> Void)?

    var isRunning: Bool { process.isRunning }
    var terminationStatus: Int32 { process.terminationStatus }
    var terminationHandler: (@Sendable (any ProcessRPCProcess) -> Void)? {
        get { handler }
        set {
            handler = newValue
            if newValue == nil {
                process.terminationHandler = nil
            } else {
                process.terminationHandler = { [weak self] _ in
                    guard let self else { return }
                    self.handler?(self)
                }
            }
        }
    }

    func configure(codexPath: String, stdin: Pipe, stdout: Pipe, stderr: Pipe) {
        process.executableURL = URL(fileURLWithPath: codexPath)
        process.arguments = ["app-server", "--stdio"]
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
    }

    func run() throws { try process.run() }
    func terminate() { process.terminate() }
    func kill() -> Bool {
        Darwin.kill(process.processIdentifier, SIGKILL) == 0 || errno == ESRCH
    }
}

private final class DispatchTimeoutScheduler: CodexRPCTimeoutScheduling, @unchecked Sendable {
    func schedule(after seconds: Double, action: @escaping @Sendable () -> Void) -> any CodexRPCCancellable {
        let work = DispatchWorkItem(block: action)
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: work)
        return DispatchTimeoutToken(work: work)
    }
}

private final class DispatchTimeoutToken: CodexRPCCancellable, @unchecked Sendable {
    private let work: DispatchWorkItem

    init(work: DispatchWorkItem) {
        self.work = work
    }

    func cancel() {
        work.cancel()
    }
}

final class CodexRPCEventQueue: @unchecked Sendable {
    private typealias Operation = @Sendable () async -> Void

    private let lock = NSLock()
    private var pendingOperations: [Operation] = []
    private var isDraining = false

    func enqueue(_ operation: @escaping @Sendable () async -> Void) {
        lock.lock()
        pendingOperations.append(operation)
        if !isDraining {
            isDraining = true
            Task {
                await self.drain()
            }
        }
        lock.unlock()
    }

    private func drain() async {
        while let operation = nextOperation() {
            await operation()
        }
    }

    private func nextOperation() -> Operation? {
        lock.lock()
        defer { lock.unlock() }
        guard !pendingOperations.isEmpty else {
            isDraining = false
            return nil
        }
        return pendingOperations.removeFirst()
    }
}

final class ProcessRPCTransport: CodexRPCTransport, @unchecked Sendable {
    private let process: any ProcessRPCProcess
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let streamLock = NSLock()
    private let shutdownLock = NSLock()
    private var hasStarted = false
    private var isShuttingDown = false
    private var hasTerminated = false
    private var shutdownResult: Result<Void, Error>?
    private let shutdownGraceSeconds: TimeInterval

    init(codexPath: String, shutdownGraceSeconds: TimeInterval = 1) {
        self.process = FoundationProcessRPCProcess()
        self.shutdownGraceSeconds = shutdownGraceSeconds
        process.configure(codexPath: codexPath, stdin: stdinPipe, stdout: stdoutPipe, stderr: stderrPipe)
    }

    init(process: any ProcessRPCProcess, shutdownGraceSeconds: TimeInterval = 1) {
        self.process = process
        self.shutdownGraceSeconds = shutdownGraceSeconds
        process.configure(codexPath: "", stdin: stdinPipe, stdout: stdoutPipe, stderr: stderrPipe)
    }

    func start(
        stdout: @escaping @Sendable (Data) -> Void,
        stdoutEOF: @escaping @Sendable () -> Void,
        stderr: @escaping @Sendable (Data) -> Void,
        termination: @escaping @Sendable (Int32) -> Void
    ) throws {
        shutdownLock.lock()
        defer { shutdownLock.unlock() }
        guard shutdownResult == nil else {
            throw RealQuotaError.transportFailed
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            self.streamLock.lock()
            defer { self.streamLock.unlock() }
            guard !self.isShuttingDown, !self.hasTerminated else { return }
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                stdoutEOF()
            } else {
                stdout(chunk)
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            self.streamLock.lock()
            defer { self.streamLock.unlock() }
            guard !self.isShuttingDown, !self.hasTerminated else { return }
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
            } else {
                stderr(chunk)
            }
        }
        process.terminationHandler = { [weak self] proc in
            guard let self else {
                termination(proc.terminationStatus)
                return
            }

            self.streamLock.lock()
            if self.isShuttingDown {
                self.streamLock.unlock()
                termination(proc.terminationStatus)
                return
            }
            guard !self.hasTerminated else {
                self.streamLock.unlock()
                return
            }
            self.hasTerminated = true

            self.stdoutPipe.fileHandleForReading.readabilityHandler = nil
            self.stderrPipe.fileHandleForReading.readabilityHandler = nil
            let stdoutTail = self.stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrTail = self.stderrPipe.fileHandleForReading.readDataToEndOfFile()
            if !stdoutTail.isEmpty { stdout(stdoutTail) }
            if !stderrTail.isEmpty { stderr(stderrTail) }
            termination(proc.terminationStatus)
            self.streamLock.unlock()
        }
        try process.run()
        hasStarted = true
    }

    func write(_ data: Data) throws {
        streamLock.lock()
        defer { streamLock.unlock() }
        guard !isShuttingDown, !hasTerminated else {
            throw RealQuotaError.transportFailed
        }
        try stdinPipe.fileHandleForWriting.write(contentsOf: data)
    }

    func shutdownAndWait() throws {
        shutdownLock.lock()
        defer { shutdownLock.unlock() }
        if let shutdownResult {
            try shutdownResult.get()
            return
        }

        let result: Result<Void, Error> = Result { try performShutdownAndWait() }
        shutdownResult = result
        try result.get()
    }

    private func performShutdownAndWait() throws {
        streamLock.lock()
        isShuttingDown = true
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        stdinPipe.fileHandleForWriting.closeFile()
        stdinPipe.fileHandleForReading.closeFile()
        stdoutPipe.fileHandleForReading.closeFile()
        stdoutPipe.fileHandleForWriting.closeFile()
        stderrPipe.fileHandleForReading.closeFile()
        stderrPipe.fileHandleForWriting.closeFile()
        streamLock.unlock()

        process.terminationHandler = nil
        guard hasStarted else {
            return
        }
        if process.isRunning {
            process.terminate()
            waitForExit()
        }
        if process.isRunning {
            guard process.kill() else {
                throw ProcessCleanupError.forceKillFailed
            }
            waitForExit()
        }
        if process.isRunning {
            throw ProcessCleanupError.processDidNotExit
        }
    }

    private func waitForExit() {
        let deadline = Date().addingTimeInterval(shutdownGraceSeconds)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.001)
        }
    }
}

actor CodexRPCClient {
    private enum Operation: String, Sendable {
        case initialize
        case rateLimitsRead
    }

    private struct PendingResponse: Sendable {
        let id: CodexAppServerRequestID
        let operation: Operation
    }

    private let transport: any CodexRPCTransport
    private let timeoutScheduler: any CodexRPCTimeoutScheduling
    private let eventQueue = CodexRPCEventQueue()
    private let maxFrameBytes: Int
    private let maxStderrBytes: Int

    private var stdoutBuffer = Data()
    private var stderrData = Data()
    private var nextId: Int64 = 1
    private var hasResumed = false
    private var hasObservedStdoutEOF = false
    private var pendingResponse: PendingResponse?
    private var completion: ((Result<QuotaSnapshot, Error>) -> Void)?
    private var timeoutWork: (any CodexRPCCancellable)?

    init(codexPath: String) {
        transport = ProcessRPCTransport(codexPath: codexPath)
        timeoutScheduler = DispatchTimeoutScheduler()
        maxFrameBytes = 512 * 1_024
        maxStderrBytes = 16 * 1_024
    }

    init(
        transport: any CodexRPCTransport,
        timeoutScheduler: any CodexRPCTimeoutScheduling,
        maxFrameBytes: Int = 512 * 1_024,
        maxStderrBytes: Int = 16 * 1_024
    ) {
        self.transport = transport
        self.timeoutScheduler = timeoutScheduler
        self.maxFrameBytes = max(1, maxFrameBytes)
        self.maxStderrBytes = max(1, maxStderrBytes)
    }

    func fetchQuota(timeoutSeconds: Double) async throws -> QuotaSnapshot {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                completion = { result in
                    switch result {
                    case .success(let snapshot): continuation.resume(returning: snapshot)
                    case .failure(let error): continuation.resume(throwing: error)
                    }
                }
                if Task.isCancelled {
                    complete(.failure(CancellationError()))
                } else {
                    setupAndRun(timeoutSeconds: timeoutSeconds)
                }
            }
        }, onCancel: {
            Task { await self.cancel() }
        })
    }

    private func setupAndRun(timeoutSeconds: Double) {
        do {
            let eventQueue = eventQueue
            try transport.start(
                stdout: { [weak self] chunk in
                    eventQueue.enqueue { [weak self] in await self?.handleStdoutChunk(chunk) }
                },
                stdoutEOF: { [weak self] in
                    eventQueue.enqueue { [weak self] in await self?.handleStdoutEOF() }
                },
                stderr: { [weak self] chunk in
                    eventQueue.enqueue { [weak self] in await self?.handleStderrChunk(chunk) }
                },
                termination: { [weak self] status in
                    eventQueue.enqueue { [weak self] in await self?.handleTermination(status: status) }
                }
            )
        } catch {
            AppLogger.codexRPC.error("Failed to start Codex app-server: \(String(describing: error), privacy: .private)")
            complete(.failure(RealQuotaError.spawnFailed))
            return
        }

        // Set up timeout
        let eventQueue = eventQueue
        timeoutWork = timeoutScheduler.schedule(after: timeoutSeconds) { [weak self] in
            eventQueue.enqueue { [weak self] in await self?.handleTimeout() }
        }

        sendRequest(
            operation: .initialize,
            method: "initialize",
            params: .object([
                "clientInfo": .object([
                    "name": .string("codex-monitor-native"),
                    "title": .string("Codex Monitor Native"),
                    "version": .string("0.2.0")
                ])
            ])
        )
    }

    private func handleInitializeResponse(_ result: CodexAppServerJSONValue) {
        guard case .object(let object) = result,
              case .string = object["codexHome"],
              case .string = object["platformFamily"],
              case .string = object["platformOs"],
              case .string = object["userAgent"] else {
            complete(.failure(RealQuotaError.handshakeFailed))
            return
        }

        do {
            try writeFrame(CodexAppServerCodec.encodeNotification(method: "initialized"))
        } catch {
            AppLogger.codexRPC.error("Failed to acknowledge Codex initialization: \(String(describing: error), privacy: .private)")
            complete(.failure(RealQuotaError.transportFailed))
            return
        }

        sendRequest(operation: .rateLimitsRead, method: "account/rateLimits/read")
    }

    private func handleRateLimitsResponse(_ result: CodexAppServerJSONValue) {
        guard case .object(let object) = result,
              let response = result.foundationObject() else {
            complete(.failure(RealQuotaError.responseInvalid))
            return
        }

        let hasSupportedContainer = RateLimitResponseSchema.containerKeys.contains { key in
            guard let value = object[key], case .object = value else { return false }
            return true
        }
        guard hasSupportedContainer else {
            complete(.failure(RealQuotaError.responseInvalid))
            return
        }

        guard let snapshot = RealQuotaProvider.parseRateLimits(response: response),
              snapshot.quotaWindows.contains(where: {
                  $0.state.isCurrent && $0.kind != .unknown
              }) else {
            complete(.failure(RealQuotaError.noUsableRateLimits))
            return
        }

        complete(.success(snapshot))
    }

    private func handleStdoutChunk(_ chunk: Data) {
        guard !hasResumed else { return }
        stdoutBuffer.append(chunk)

        while let newlineRange = stdoutBuffer.range(of: Data("\n".utf8)) {
            if newlineRange.lowerBound > maxFrameBytes {
                complete(.failure(RealQuotaError.responseInvalid))
                return
            }
            let lineData = stdoutBuffer.subdata(in: 0..<newlineRange.lowerBound)
            stdoutBuffer.removeSubrange(0...newlineRange.lowerBound)
            handleLine(lineData)
            if hasResumed { return }
        }

        if stdoutBuffer.count > maxFrameBytes {
            complete(.failure(RealQuotaError.responseInvalid))
        }
    }

    private func handleStdoutEOF() {
        guard !hasResumed, !hasObservedStdoutEOF else { return }
        hasObservedStdoutEOF = true
        guard !stdoutBuffer.isEmpty else { return }

        let trailingLine = stdoutBuffer
        stdoutBuffer.removeAll(keepingCapacity: false)
        guard trailingLine.count <= maxFrameBytes else {
            complete(.failure(RealQuotaError.responseInvalid))
            return
        }
        handleLine(trailingLine)
    }

    private func handleStderrChunk(_ chunk: Data) {
        guard !hasResumed else { return }
        if chunk.count >= maxStderrBytes {
            stderrData = Data(chunk.suffix(maxStderrBytes))
            return
        }

        stderrData.append(chunk)
        if stderrData.count > maxStderrBytes {
            stderrData.removeSubrange(0..<(stderrData.count - maxStderrBytes))
        }
    }

    private func handleTermination(status: Int32) {
        guard !hasResumed else { return }
        if !hasObservedStdoutEOF, !stdoutBuffer.isEmpty {
            handleStdoutEOF()
            if hasResumed { return }
        }
        if let stderr = String(data: stderrData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !stderr.isEmpty {
            AppLogger.codexRPC.error("Codex app-server exited code=\(status, privacy: .public) stderr=\(stderr, privacy: .private)")
        }
        complete(.failure(RealQuotaError.processExited(status)))
    }

    private func handleTimeout() {
        guard !hasResumed else { return }
        complete(.failure(RealQuotaError.requestTimedOut))
    }

    private func handleLine(_ lineData: Data) {
        guard !hasResumed else { return }
        if lineData.allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }) {
            return
        }

        let message: CodexAppServerMessage
        do {
            message = try CodexAppServerCodec.decodeLine(lineData)
        } catch {
            AppLogger.codexRPC.error("Codex app-server emitted an invalid protocol frame")
            complete(.failure(RealQuotaError.responseInvalid))
            return
        }

        switch message {
        case .response(let id, let result):
            guard let pendingResponse, pendingResponse.id == id else {
                AppLogger.codexRPC.error("Codex app-server response id did not match the pending request")
                complete(.failure(RealQuotaError.responseInvalid))
                return
            }
            self.pendingResponse = nil
            switch pendingResponse.operation {
            case .initialize:
                handleInitializeResponse(result)
            case .rateLimitsRead:
                handleRateLimitsResponse(result)
            }
        case .error(let id, let remoteError):
            guard let pendingResponse, pendingResponse.id == id else {
                AppLogger.codexRPC.error("Codex app-server error id did not match the pending request")
                complete(.failure(RealQuotaError.responseInvalid))
                return
            }
            self.pendingResponse = nil
            AppLogger.codexRPC.error("Codex RPC \(pendingResponse.operation.rawValue, privacy: .public) rejected code=\(remoteError.code, privacy: .public) message=\(remoteError.message, privacy: .private)")
            complete(.failure(RealQuotaError.rpcRejected(code: remoteError.code)))
        case .notification:
            break
        case .request(let id, let method, _):
            AppLogger.codexRPC.error("Codex app-server sent unsupported server request: \(method, privacy: .private)")
            let response = try? CodexAppServerCodec.encodeErrorResponse(
                id: id,
                error: CodexAppServerRemoteError(code: -32_601, message: "Method not found")
            )
            if let response {
                try? writeFrame(response)
            }
            complete(.failure(RealQuotaError.unsupportedServerRequest))
        }
    }

    private func sendRequest(
        operation: Operation,
        method: String,
        params: CodexAppServerJSONValue? = nil
    ) {
        guard pendingResponse == nil else {
            complete(.failure(RealQuotaError.responseInvalid))
            return
        }

        let id = CodexAppServerRequestID.integer(nextId)
        nextId += 1
        pendingResponse = PendingResponse(id: id, operation: operation)

        do {
            let data = try CodexAppServerCodec.encodeRequest(id: id, method: method, params: params)
            try writeFrame(data)
        } catch {
            pendingResponse = nil
            AppLogger.codexRPC.error("Failed to write Codex RPC request: \(String(describing: error), privacy: .private)")
            complete(.failure(RealQuotaError.transportFailed))
        }
    }

    private func writeFrame(_ data: Data) throws {
        var framedData = data
        framedData.append(0x0A)
        try transport.write(framedData)
    }

    private func cancel() {
        complete(.failure(CancellationError()))
    }

    private func complete(_ result: Result<QuotaSnapshot, Error>) {
        guard !hasResumed else { return }
        hasResumed = true
        pendingResponse = nil
        timeoutWork?.cancel()
        timeoutWork = nil
        var finalResult = result
        do {
            try transport.shutdownAndWait()
        } catch {
            AppLogger.codexRPC.error("Failed to clean up Codex app-server: \(String(describing: error), privacy: .private)")
            if case .success = result {
                finalResult = .failure(RealQuotaError.processCleanupFailed)
            }
        }
        let completion = completion
        self.completion = nil
        completion?(finalResult)
    }

}

struct RealQuotaProvider: RealQuotaRefreshing {
    private struct ParsedResetMetadata {
        let resetAt: Date?
        let status: ResetBankResetTimeStatus
    }

    private struct ParsedResetCredits {
        let availableCount: Int?
    }

    private struct ParsedQuotaField {
        let remaining: Int
        let state: QuotaFieldState
    }

    private enum ParsedWindowDuration {
        case missing
        case valid(Int)
        case invalid

        var value: Int? {
            guard case .valid(let value) = self else { return nil }
            return value
        }

        var isMissing: Bool {
            if case .missing = self { return true }
            return false
        }
    }

    private struct ParsedQuotaWindow {
        let limitId: String
        let windowId: String
        let kind: QuotaWindowKind
        let durationMinutes: Int?
        let field: ParsedQuotaField
        let resetMetadata: ParsedResetMetadata
    }

    private let codexPath: String?
    private let timeoutSeconds: Double

    init(codexPath: String? = nil, timeoutSeconds: Double = 10) {
        self.codexPath = codexPath ?? RealQuotaProvider.resolveCodexPath()
        self.timeoutSeconds = timeoutSeconds
    }

    func fetchQuota() async throws -> QuotaSnapshot {
        guard let codexPath else {
            throw RealQuotaError.codexNotFound
        }
        let client = CodexRPCClient(codexPath: codexPath)
        return try await client.fetchQuota(timeoutSeconds: timeoutSeconds)
    }

    // MARK: - Response Parsing (with field-level validation)

    static func parseRateLimits(response: [String: Any]) -> QuotaSnapshot? {
        var rateLimitsByLimitId = mergedObjectValues(
            in: response,
            keys: RateLimitResponseSchema.dynamicContainerKeys
        ) ?? [:]
        if let legacyRateLimits = mergedObjectValues(
            in: response,
            keys: RateLimitResponseSchema.legacyContainerKeys
        ) {
            if let dynamicCanonicalValue = rateLimitsByLimitId["codex"] {
                if let dynamicCanonicalBucket = dynamicCanonicalValue as? [String: Any] {
                    var canonicalBucket = legacyRateLimits
                    // The multi-bucket view is the canonical source when both
                    // schemas coexist; the legacy object is fallback-only.
                    for (key, value) in dynamicCanonicalBucket {
                        canonicalBucket[key] = value
                    }
                    rateLimitsByLimitId["codex"] = canonicalBucket
                }
            } else {
                rateLimitsByLimitId["codex"] = legacyRateLimits
            }
        }

        let codexBucket = rateLimitsByLimitId["codex"] as? [String: Any] ?? [:]
        let primary = codexBucket["primary"] as? [String: Any]
        let canonicalSecondary = codexBucket["secondary"] as? [String: Any]
        let codexOtherBucket = rateLimitsByLimitId["codex_other"] as? [String: Any]
        let fallbackSecondary = codexOtherBucket?["primary"] as? [String: Any]

        let primaryOmitsDuration = primary.map { parseWindowDuration($0).isMissing } ?? false
        let canonicalSecondaryOmitsDuration = canonicalSecondary.map {
            parseWindowDuration($0).isMissing
        } ?? false
        let fallbackSecondaryOmitsDuration = fallbackSecondary.map {
            parseWindowDuration($0).isMissing
        } ?? false
        let retainsLegacyDualMapping = primaryOmitsDuration
            && ((canonicalSecondary != nil && canonicalSecondaryOmitsDuration)
                || (canonicalSecondary == nil && fallbackSecondary != nil && fallbackSecondaryOmitsDuration))

        let parsedWindows = rateLimitsByLimitId.keys.sorted().flatMap { limitId -> [ParsedQuotaWindow] in
            guard let bucket = rateLimitsByLimitId[limitId] as? [String: Any] else { return [] }
            return bucket.keys.sorted().compactMap { windowId in
                guard let window = bucket[windowId] as? [String: Any],
                      isQuotaWindowCandidate(windowId: windowId, window: window) else {
                    return nil
                }
                let parsedDuration = parseWindowDuration(window)
                let durationMinutes = parsedDuration.value
                let kind = classifyWindow(
                    limitId: limitId,
                    windowId: windowId,
                    durationMinutes: durationMinutes,
                    retainsLegacyDualMapping: retainsLegacyDualMapping && parsedDuration.isMissing
                )
                return ParsedQuotaWindow(
                    limitId: limitId,
                    windowId: windowId,
                    kind: kind,
                    durationMinutes: durationMinutes,
                    field: parseQuotaField(window, label: "\(limitId).\(windowId)"),
                    resetMetadata: parseResetMetadata(from: window)
                )
            }
        }

        guard !parsedWindows.isEmpty else {
            AppLogger.codexRPC.error("No quota windows in rate limits response")
            return nil
        }

        let fiveHourWindow = preferredWindow(
            kind: .fiveHour,
            preferredIdentities: [("codex", "primary")],
            in: parsedWindows
        )
        let weeklyWindow = preferredWindow(
            kind: .weekly,
            preferredIdentities: [("codex", "secondary"), ("codex_other", "primary")],
            in: parsedWindows
        )
        let fiveHour = fiveHourWindow?.field ?? ParsedQuotaField(remaining: 0, state: .unavailable)
        let weekly = weeklyWindow?.field ?? ParsedQuotaField(remaining: 0, state: .unavailable)
        let usesFallbackWeeklySource = weeklyWindow?.limitId == "codex_other"
            && weeklyWindow?.windowId == "primary"

        let fiveHourResetAt = fiveHourWindow?.resetMetadata.resetAt
        let resetCredits = parseResetCredits(from: mergedObjectValues(
            in: response,
            keys: RateLimitResponseSchema.resetCreditsKeys
        ))

        if fiveHour.state == .live || weekly.state == .live {
            AppLogger.codexRPC.info("Parsed real quota: weekly=\(weekly.remaining)% [\(weekly.state.rawValue, privacy: .public)] fiveHour=\(fiveHour.remaining)% [\(fiveHour.state.rawValue, privacy: .public)]")
        } else {
            AppLogger.codexRPC.warning("No trusted quota fields in rate limits response")
        }

        return QuotaSnapshot(
            weeklyQuotaPercent: weekly.remaining,
            fiveHourQuotaPercent: fiveHour.remaining,
            weeklyQuotaState: weekly.state,
            fiveHourQuotaState: fiveHour.state,
            resetAvailableCount: resetCredits.availableCount,
            resetCreditDetailsState: .appServerCountOnly,
            resetCreditDiagnostic: nil,
            resetCreditDetails: [],
            resetCreditStatusSummary: [],
            resetCreditTimeEntries: [],
            resetCreditRawFields: [],
            fiveHourResetAt: fiveHourResetAt,
            resetBanks: parseResetBanks(
                from: parsedWindows,
                usesFallbackWeeklySource: usesFallbackWeeklySource
            ),
            refreshedAt: .now,
            dataSource: .real,
            errorMessage: nil,
            quotaWindows: parsedWindows.map {
                QuotaWindow(
                    limitId: $0.limitId,
                    windowId: $0.windowId,
                    kind: $0.kind,
                    durationMinutes: $0.durationMinutes,
                    remainingPercent: $0.field.remaining,
                    state: $0.field.state,
                    resetAt: $0.resetMetadata.resetAt
                )
            }
        )
    }

    private static func mergedObjectValues(
        in object: [String: Any],
        keys: [String]
    ) -> [String: Any]? {
        var merged: [String: Any] = [:]
        var foundObject = false

        for key in keys {
            guard let value = object[key] as? [String: Any] else { continue }
            if foundObject {
                merged = mergeAliasedObjects(merged, value)
            } else {
                merged = value
                foundObject = true
            }
        }

        return foundObject ? merged : nil
    }

    private static func mergeAliasedObjects(
        _ lhs: [String: Any],
        _ rhs: [String: Any]
    ) -> [String: Any] {
        var merged = lhs
        for (key, rhsValue) in rhs {
            guard let lhsValue = merged[key] else {
                merged[key] = rhsValue
                continue
            }
            merged[key] = mergeAliasedValues(lhsValue, rhsValue)
        }
        return merged
    }

    private static func mergeAliasedValues(_ lhs: Any, _ rhs: Any) -> Any {
        if lhs is ConflictingSchemaValue || rhs is ConflictingSchemaValue {
            return ConflictingSchemaValue.marker
        }
        if lhs is NSNull { return rhs }
        if rhs is NSNull { return lhs }
        if let lhsObject = lhs as? [String: Any],
           let rhsObject = rhs as? [String: Any] {
            return mergeAliasedObjects(lhsObject, rhsObject)
        }
        if isBooleanJSONValue(lhs) != isBooleanJSONValue(rhs) {
            return ConflictingSchemaValue.marker
        }
        if let lhsObject = lhs as? NSObject,
           let rhsObject = rhs as? NSObject,
           lhsObject.isEqual(rhsObject) {
            return lhs
        }
        return ConflictingSchemaValue.marker
    }

    private static func isQuotaWindowCandidate(
        windowId: String,
        window: [String: Any]
    ) -> Bool {
        guard !RateLimitResponseSchema.knownNonWindowKeys.contains(windowId) else {
            return false
        }
        if windowId == "primary" || windowId == "secondary" {
            return true
        }
        return !RateLimitResponseSchema.windowSignalKeys.isDisjoint(with: window.keys)
    }

    private static func classifyWindow(
        limitId: String,
        windowId: String,
        durationMinutes: Int?,
        retainsLegacyDualMapping: Bool
    ) -> QuotaWindowKind {
        if let durationMinutes {
            return QuotaWindowKind.from(durationMinutes: durationMinutes)
        }

        guard retainsLegacyDualMapping else {
            return .unknown
        }

        switch (limitId, windowId) {
        case ("codex", "primary"):
            return .fiveHour
        case ("codex", "secondary"), ("codex_other", "primary"):
            return .weekly
        default:
            return .unknown
        }
    }

    private static func preferredWindow(
        kind: QuotaWindowKind,
        preferredIdentities: [(limitId: String, windowId: String)],
        in windows: [ParsedQuotaWindow]
    ) -> ParsedQuotaWindow? {
        let candidates = windows.filter { $0.kind == kind }
        for identity in preferredIdentities {
            if let exactLive = candidates.first(where: {
                $0.limitId == identity.limitId
                    && $0.windowId == identity.windowId
                    && $0.field.state.isCurrent
            }) {
                return exactLive
            }
        }
        if let live = candidates.first(where: { $0.field.state.isCurrent }) {
            return live
        }
        for identity in preferredIdentities {
            if let exact = candidates.first(where: {
                $0.limitId == identity.limitId && $0.windowId == identity.windowId
            }) {
                return exact
            }
        }
        return candidates.first
    }

    private static func parseWindowDuration(_ window: [String: Any]) -> ParsedWindowDuration {
        var values: [Int] = []
        var hasInvalidValue = false
        var hasNonNullField = false

        for key in RateLimitResponseSchema.durationKeys {
            guard let rawValue = window[key] else { continue }
            guard !(rawValue is NSNull) else { continue }
            hasNonNullField = true
            guard let value = parseInteger(rawValue), value > 0 else {
                hasInvalidValue = true
                continue
            }
            values.append(value)
        }

        guard hasNonNullField else { return .missing }
        guard !hasInvalidValue,
              let duration = values.first,
              values.allSatisfy({ $0 == duration }) else {
            return .invalid
        }
        return .valid(duration)
    }

    private static func parseQuotaField(
        _ window: [String: Any]?,
        label: String
    ) -> ParsedQuotaField {
        guard let window else {
            AppLogger.codexRPC.warning("\(label) quota window is unexposed")
            return ParsedQuotaField(remaining: 0, state: .unavailable)
        }

        var remainingCandidates: [Double] = []
        var hasRecognizedField = false
        var hasInvalidValue = false

        for key in RateLimitResponseSchema.usedPercentKeys {
            guard let rawValue = window[key] else { continue }
            hasRecognizedField = true
            guard !(rawValue is NSNull),
                  let usedPercent = parsePercentage(rawValue),
                  usedPercent.isFinite,
                  (0...100).contains(usedPercent) else {
                if !(rawValue is NSNull) {
                    hasInvalidValue = true
                }
                continue
            }
            remainingCandidates.append(100.0 - usedPercent)
        }

        for key in RateLimitResponseSchema.remainingPercentKeys {
            guard let rawValue = window[key] else { continue }
            hasRecognizedField = true
            guard !(rawValue is NSNull),
                  let remainingPercent = parsePercentage(rawValue),
                  remainingPercent.isFinite,
                  (0...100).contains(remainingPercent) else {
                if !(rawValue is NSNull) {
                    hasInvalidValue = true
                }
                continue
            }
            remainingCandidates.append(remainingPercent)
        }

        guard hasRecognizedField,
              !hasInvalidValue,
              let rawRemaining = remainingCandidates.first,
              remainingCandidates.allSatisfy({ abs($0 - rawRemaining) < 0.000_001 }) else {
            AppLogger.codexRPC.error("\(label) quota percentage is missing, invalid, or conflicting")
            return ParsedQuotaField(remaining: 0, state: .invalid)
        }

        let remaining = Int(rawRemaining.rounded())
        guard (0...100).contains(remaining) else {
            AppLogger.codexRPC.error("\(label) computed remaining percentage is invalid")
            return ParsedQuotaField(remaining: 0, state: .invalid)
        }

        return ParsedQuotaField(remaining: remaining, state: .live)
    }

    private static func parsePercentage(_ rawValue: Any) -> Double? {
        guard !isBooleanJSONValue(rawValue) else { return nil }
        if let number = rawValue as? NSNumber {
            return number.doubleValue
        }
        if let value = rawValue as? Double {
            return value
        }
        if let value = rawValue as? Int {
            return Double(value)
        }
        if let value = rawValue as? String {
            return Double(value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    private static func parseInteger(_ rawValue: Any) -> Int? {
        guard !isBooleanJSONValue(rawValue) else { return nil }
        if let number = rawValue as? NSNumber {
            switch String(cString: number.objCType) {
            case "c", "s", "i", "l", "q":
                return Int(exactly: number.int64Value)
            case "C", "S", "I", "L", "Q":
                return Int(exactly: number.uint64Value)
            default:
                break
            }

            let value = number.doubleValue
            guard value.isFinite,
                  value.rounded() == value,
                  let integer = Int(exactly: value) else {
                return nil
            }
            return integer
        }
        if let value = rawValue as? String {
            return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    private static func parseResetBanks(
        from windows: [ParsedQuotaWindow],
        usesFallbackWeeklySource: Bool
    ) -> [ResetBankSnapshot] {
        let banks = windows.compactMap { window -> ResetBankSnapshot? in
            guard window.field.state.isCurrent,
                  !shouldSkipResetBank(
                    limitId: window.limitId,
                    windowId: window.windowId,
                    usesFallbackWeeklySource: usesFallbackWeeklySource
                  ) else {
                return nil
            }

            return ResetBankSnapshot(
                limitId: window.limitId,
                windowId: window.windowId,
                displayName: resetBankDisplayName(
                    limitId: window.limitId,
                    windowId: window.windowId,
                    kind: window.kind
                ),
                remainingPercent: window.field.remaining,
                resetAt: window.resetMetadata.resetAt,
                resetTimeStatus: window.resetMetadata.status,
                windowKind: window.kind,
                durationMinutes: window.durationMinutes
            )
        }

        return banks
            .sorted(by: compareResetBanks)
            .prefix(3)
            .map { $0 }
    }

    private static func compareResetBanks(_ lhs: ResetBankSnapshot, _ rhs: ResetBankSnapshot) -> Bool {
        switch (lhs.resetAt, rhs.resetAt) {
        case let (left?, right?):
            if left != right {
                return left < right
            }
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case (nil, nil):
            break
        }

        if lhs.displayName != rhs.displayName {
            return lhs.displayName < rhs.displayName
        }

        return lhs.id < rhs.id
    }

    private static func resetBankDisplayName(limitId: String, windowId: String, kind: QuotaWindowKind? = nil) -> String {
        if let kind {
            return kind.displayName
        }
        switch (limitId, windowId) {
        case ("codex", "primary"):
            return "5小时额度"
        case ("codex", "secondary"), ("codex_other", "primary"):
            return "周额度"
        default:
            return "\(limitId).\(windowId)"
        }
    }

    private static func shouldSkipResetBank(
        limitId: String,
        windowId: String,
        usesFallbackWeeklySource: Bool
    ) -> Bool {
        if limitId == "codex_other", windowId == "primary" {
            return !usesFallbackWeeklySource
        }

        return false
    }

    private static func parseResetMetadata(from window: [String: Any]) -> ParsedResetMetadata {
        var hasCandidateField = false
        var hasInvalidValue = false
        var parsedDates: [Date] = []

        for key in RateLimitResponseSchema.resetAtKeys {
            guard let rawValue = window[key] else {
                continue
            }

            hasCandidateField = true
            guard !(rawValue is NSNull) else { continue }
            if let parsedDate = parseDate(rawValue) {
                parsedDates.append(parsedDate)
            } else {
                hasInvalidValue = true
            }
        }

        if !hasInvalidValue,
           let resetAt = parsedDates.first,
           parsedDates.allSatisfy({ $0 == resetAt }) {
            return ParsedResetMetadata(resetAt: resetAt, status: .actual)
        }
        return ParsedResetMetadata(
            resetAt: nil,
            status: hasCandidateField ? .parseFailed : .unexposed
        )
    }

    private static func parseResetCredits(from rawValue: Any?) -> ParsedResetCredits {
        guard let container = rawValue as? [String: Any] else {
            return ParsedResetCredits(availableCount: nil)
        }

        var counts: [Int] = []
        var hasInvalidValue = false
        for key in ["availableCount", "available_count"] {
            guard let rawValue = container[key], !(rawValue is NSNull) else { continue }
            guard let count = parseInteger(rawValue), count >= 0 else {
                hasInvalidValue = true
                continue
            }
            counts.append(count)
        }

        guard !hasInvalidValue,
              let count = counts.first,
              counts.allSatisfy({ $0 == count }) else {
            return ParsedResetCredits(availableCount: nil)
        }
        return ParsedResetCredits(availableCount: count)
    }

    private static func parseDate(_ rawValue: Any) -> Date? {
        guard !isBooleanJSONValue(rawValue) else { return nil }
        if let date = rawValue as? Date {
            return date
        }

        if let seconds = rawValue as? Double {
            return dateFromTimestamp(seconds)
        }

        if let seconds = rawValue as? Int {
            return dateFromTimestamp(Double(seconds))
        }

        if let string = rawValue as? String {
            if let numeric = Double(string) {
                return dateFromTimestamp(numeric)
            }

            let iso8601 = ISO8601DateFormatter()
            iso8601.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = iso8601.date(from: string) {
                return date
            }

            iso8601.formatOptions = [.withInternetDateTime]
            return iso8601.date(from: string)
        }

        return nil
    }

    private static func isBooleanJSONValue(_ rawValue: Any?) -> Bool {
        guard let number = rawValue as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    private static func dateFromTimestamp(_ rawValue: Double) -> Date? {
        guard rawValue.isFinite, rawValue > 0 else {
            return nil
        }

        let seconds = rawValue > 10_000_000_000 ? rawValue / 1_000 : rawValue
        return Date(timeIntervalSince1970: seconds)
    }

    // MARK: - Codex Path Resolution

    static func resolveCodexPath() -> String? {
        if let envPath = ProcessInfo.processInfo.environment["CODEX_BIN"]
            ?? ProcessInfo.processInfo.environment["CODEX_EXECUTABLE"],
           isExecutable(envPath) {
            AppLogger.codexRPC.info("Using codex from CODEX_BIN: \(envPath, privacy: .public)")
            return envPath
        }

        let searchDirs = searchPaths()

        for dir in searchDirs {
            let candidate = dir.hasSuffix("codex") ? dir : (dir as NSString).appendingPathComponent("codex")
            if isExecutable(candidate) {
                AppLogger.codexRPC.info("Found codex at: \(candidate, privacy: .public)")
                return candidate
            }
        }

        AppLogger.codexRPC.error("Codex executable not found in any search path")
        return nil
    }

    private static func searchPaths() -> [String] {
        let envPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let pathDirs = envPath.components(separatedBy: ":")

        let defaultPaths = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/Applications/Codex.app/Contents/Resources",
            "/Applications/Codex.app/Contents/MacOS"
        ]

        return pathDirs + defaultPaths
    }

    private static func isExecutable(_ path: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: path)
    }
}
