import Foundation

protocol RealQuotaRefreshing: Sendable {
    func fetchQuota() async throws -> QuotaSnapshot
}

enum RealQuotaError: LocalizedError {
    case codexNotFound
    case spawnFailed(String)
    case handshakeFailed(String)
    case requestTimedOut
    case rpcError(String)
    case parseFailed(String)
    case noUsableRateLimits
    case processExited(Int32, String)

    var errorDescription: String? {
        switch self {
        case .codexNotFound:
            return "Codex executable not found"
        case .spawnFailed(let reason):
            return "Failed to launch codex: \(reason)"
        case .handshakeFailed(let reason):
            return "Codex app-server handshake failed: \(reason)"
        case .requestTimedOut:
            return "Codex app-server request timed out"
        case .rpcError(let message):
            return "Codex RPC error: \(message)"
        case .parseFailed(let detail):
            return "Failed to parse response: \(detail)"
        case .noUsableRateLimits:
            return "No usable rate limits in response"
        case .processExited(let code, _):
            return "Codex process exited (code \(code))"
        }
    }

    /// Classify this error into a QuotaRefreshStatus for the state machine.
    var refreshStatus: QuotaRefreshStatus {
        switch self {
        case .codexNotFound:
            return .noSnapshot
        case .spawnFailed, .handshakeFailed, .requestTimedOut, .processExited:
            return .networkFailed
        case .rpcError(let message):
            let lower = message.lowercased()
            if lower.contains("auth") || lower.contains("unauthorized") || lower.contains("login") {
                return .authRequired
            }
            return .networkFailed
        case .parseFailed, .noUsableRateLimits:
            return .parseFailed
        }
    }

    var healthKind: RealQuotaHealthDiagnostic.Kind {
        switch self {
        case .codexNotFound:
            return .executableMissing
        case .spawnFailed, .handshakeFailed, .processExited:
            return .codexUnavailable
        case .requestTimedOut:
            return .requestTimedOut
        case .rpcError(let message):
            let lower = message.lowercased()
            if lower.contains("auth") || lower.contains("unauthorized") || lower.contains("login") {
                return .loginRequired
            }
            return .rpcRejected
        case .parseFailed, .noUsableRateLimits:
            return .responseInvalid
        }
    }
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
        stderr: @escaping @Sendable (Data) -> Void,
        termination: @escaping @Sendable (Int32) -> Void
    ) throws
    func write(_ data: Data)
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

final class ProcessRPCTransport: CodexRPCTransport, @unchecked Sendable {
    private let process: any ProcessRPCProcess
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private var hasStarted = false
    private let shutdownGraceSeconds: TimeInterval

    init(codexPath: String, shutdownGraceSeconds: TimeInterval = 1) {
        self.process = FoundationProcessRPCProcess()
        self.shutdownGraceSeconds = shutdownGraceSeconds
        process.configure(codexPath: codexPath, stdin: stdinPipe, stdout: stdoutPipe, stderr: stderrPipe)
    }

    init(process: any ProcessRPCProcess, shutdownGraceSeconds: TimeInterval = 1) {
        self.process = process
        self.shutdownGraceSeconds = shutdownGraceSeconds
    }

    func start(
        stdout: @escaping @Sendable (Data) -> Void,
        stderr: @escaping @Sendable (Data) -> Void,
        termination: @escaping @Sendable (Int32) -> Void
    ) throws {
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if !chunk.isEmpty { stdout(chunk) }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if !chunk.isEmpty { stderr(chunk) }
        }
        process.terminationHandler = { proc in termination(proc.terminationStatus) }
        try process.run()
        hasStarted = true
    }

    func write(_ data: Data) {
        stdinPipe.fileHandleForWriting.write(data)
    }

    func shutdownAndWait() throws {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        stdinPipe.fileHandleForWriting.closeFile()
        stdoutPipe.fileHandleForReading.closeFile()
        stderrPipe.fileHandleForReading.closeFile()

        guard hasStarted else { return }
        if process.isRunning {
            process.terminate()
            waitForExit()
        }
        if process.isRunning {
            guard process.kill() else {
                process.terminationHandler = nil
                throw ProcessCleanupError.forceKillFailed
            }
            waitForExit()
        }
        process.terminationHandler = nil
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
    private enum PendingResponse {
        case initialize
        case rateLimits
    }

    private let transport: any CodexRPCTransport
    private let timeoutScheduler: any CodexRPCTimeoutScheduling

    private var stdoutBuffer = Data()
    private var stderrData = Data()
    private var nextId = 1
    private var hasResumed = false
    private var pendingResponse: PendingResponse?
    private var completion: ((Result<QuotaSnapshot, Error>) -> Void)?
    private var timeoutWork: (any CodexRPCCancellable)?

    init(codexPath: String) throws {
        transport = ProcessRPCTransport(codexPath: codexPath)
        timeoutScheduler = DispatchTimeoutScheduler()
    }

    init(transport: any CodexRPCTransport, timeoutScheduler: any CodexRPCTimeoutScheduling) {
        self.transport = transport
        self.timeoutScheduler = timeoutScheduler
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
            try transport.start(
                stdout: { [weak self] chunk in Task { await self?.handleStdoutChunk(chunk) } },
                stderr: { [weak self] chunk in Task { await self?.handleStderrChunk(chunk) } },
                termination: { [weak self] status in Task { await self?.handleTermination(status: status) } }
            )
        } catch {
            complete(.failure(RealQuotaError.spawnFailed(error.localizedDescription)))
            return
        }

        // Set up timeout
        timeoutWork = timeoutScheduler.schedule(after: timeoutSeconds) { [weak self] in
            Task { await self?.handleTimeout() }
        }

        // Step 1: Install the response handler before sending initialize so a
        // fast app-server response cannot arrive in the gap.
        pendingResponse = .initialize
        sendRequest(method: "initialize", params: [
            "clientInfo": [
                "name": "codex-monitor-native",
                "title": "Codex Monitor Native",
                "version": "0.2.0"
            ]
        ])
    }

    private func handleInitialized() {
        let notif: [String: Any] = ["method": "initialized"]
        if let notifData = try? JSONSerialization.data(withJSONObject: notif, options: []),
           let notifLine = String(data: notifData, encoding: .utf8) {
            writeLine(notifLine)
        }

        pendingResponse = .rateLimits
        sendRequest(method: "account/rateLimits/read")
    }

    private func handleRateLimitsResponse(_ responseData: Data) {
        guard let message = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let result = message["result"] as? [String: Any] else {
            complete(.failure(RealQuotaError.parseFailed("Invalid JSON response")))
            return
        }

        guard let snapshot = RealQuotaProvider.parseRateLimits(response: result) else {
            complete(.failure(RealQuotaError.noUsableRateLimits))
            return
        }

        complete(.success(snapshot))
    }

    private func handleStdoutChunk(_ chunk: Data) {
        stdoutBuffer.append(chunk)

        while let newlineRange = stdoutBuffer.range(of: Data("\n".utf8)) {
            let lineData = stdoutBuffer.subdata(in: 0..<newlineRange.lowerBound)
            stdoutBuffer.removeSubrange(0...newlineRange.lowerBound)
            handleLine(lineData)
        }
    }

    private func handleStderrChunk(_ chunk: Data) {
        stderrData.append(chunk)
    }

    private func handleTermination(status: Int32) {
        guard !hasResumed else { return }
        if status != 0 {
            complete(.failure(RealQuotaError.processExited(status, "")))
        } else {
            complete(.failure(RealQuotaError.spawnFailed("Codex process exited unexpectedly")))
        }
    }

    private func handleTimeout() {
        guard !hasResumed else { return }
        complete(.failure(RealQuotaError.requestTimedOut))
    }

    private func handleLine(_ lineData: Data) {
        guard let line = String(data: lineData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !line.isEmpty,
              let messageData = line.data(using: .utf8) else {
            return
        }

        let message: [String: Any]
        do {
            guard let json = try JSONSerialization.jsonObject(with: messageData) as? [String: Any] else {
                return
            }
            message = json
        } catch {
            return
        }

        if let error = message["error"] as? [String: Any] {
            let errorMsg = error["message"] as? String ?? "unknown RPC error"
            complete(.failure(RealQuotaError.rpcError(errorMsg)))
            return
        }

        if message["result"] != nil {
            let response = pendingResponse
            pendingResponse = nil
            switch response {
            case .initialize:
                handleInitialized()
            case .rateLimits:
                handleRateLimitsResponse(messageData)
            case nil:
                break
            }
        }
    }

    private func sendRequest(method: String, params: [String: Any]? = nil) {
        var dict: [String: Any] = [
            "id": nextId,
            "method": method
        ]
        if let params {
            dict["params"] = params
        }
        nextId += 1

        guard let jsonData = try? JSONSerialization.data(withJSONObject: dict, options: []),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            complete(.failure(RealQuotaError.spawnFailed("Failed to encode JSON-RPC request")))
            return
        }

        writeLine(jsonString)
    }

    private func writeLine(_ line: String) {
        guard let lineData = (line + "\n").data(using: .utf8) else { return }
        transport.write(lineData)
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
        let finalResult: Result<QuotaSnapshot, Error>
        do {
            try transport.shutdownAndWait()
            finalResult = result
        } catch {
            finalResult = .failure(error)
        }
        let completion = completion
        self.completion = nil
        completion?(finalResult)
    }
}

struct RealQuotaProvider: RealQuotaRefreshing {
    private struct ParsedResetMetadata {
        let resetAt: Date?
        let resolvedFieldName: String?
        let status: ResetBankResetTimeStatus
        let rawFields: [ResetBankRawField]
    }

    private struct ParsedResetCredits {
        let availableCount: Int?
    }

    private struct ParsedQuotaField {
        let remaining: Int
        let state: QuotaFieldState
    }

    private struct ParsedQuotaWindow {
        let limitId: String
        let windowId: String
        let kind: QuotaWindowKind
        let durationMinutes: Int?
        let field: ParsedQuotaField
        let resetAt: Date?
    }

    private let codexPath: String
    private let timeoutSeconds: Double

    init(codexPath: String? = nil, timeoutSeconds: Double = 10) {
        self.codexPath = codexPath ?? RealQuotaProvider.resolveCodexPath()
        self.timeoutSeconds = timeoutSeconds
    }

    func fetchQuota() async throws -> QuotaSnapshot {
        let client = try CodexRPCClient(codexPath: codexPath)
        return try await client.fetchQuota(timeoutSeconds: timeoutSeconds)
    }

    // MARK: - Response Parsing (with field-level validation)

    static func parseRateLimits(response: [String: Any]) -> QuotaSnapshot? {
        let rateLimitsByLimitId = response["rateLimitsByLimitId"] as? [String: Any] ?? [:]

        let codexBucket = rateLimitsByLimitId["codex"] as? [String: Any] ?? [:]
        let primary = codexBucket["primary"] as? [String: Any]
        let canonicalSecondary = codexBucket["secondary"] as? [String: Any]
        let codexOtherBucket = rateLimitsByLimitId["codex_other"] as? [String: Any]
        let fallbackSecondary = codexOtherBucket?["primary"] as? [String: Any]

        guard primary != nil || canonicalSecondary != nil || fallbackSecondary != nil else {
            AppLogger.codexRPC.error("No usable quota windows in rate limits response")
            return nil
        }

        let primaryOmitsDuration = primary.map { parseWindowDuration($0) == nil } ?? false
        let canonicalSecondaryOmitsDuration = canonicalSecondary.map { parseWindowDuration($0) == nil } ?? false
        let fallbackSecondaryOmitsDuration = fallbackSecondary.map { parseWindowDuration($0) == nil } ?? false
        let retainsLegacyDualMapping = primaryOmitsDuration
            && ((canonicalSecondary != nil && canonicalSecondaryOmitsDuration)
                || (canonicalSecondary == nil && fallbackSecondary != nil && fallbackSecondaryOmitsDuration))

        let parsedWindows = rateLimitsByLimitId.keys.sorted().flatMap { limitId -> [ParsedQuotaWindow] in
            guard let bucket = rateLimitsByLimitId[limitId] as? [String: Any] else { return [] }
            return bucket.keys.sorted().compactMap { windowId in
                guard let window = bucket[windowId] as? [String: Any] else { return nil }
                let durationMinutes = parseWindowDuration(window)
                let kind = classifyWindow(
                    limitId: limitId,
                    windowId: windowId,
                    durationMinutes: durationMinutes,
                    retainsLegacyDualMapping: retainsLegacyDualMapping
                )
                return ParsedQuotaWindow(
                    limitId: limitId,
                    windowId: windowId,
                    kind: kind,
                    durationMinutes: durationMinutes,
                    field: parseQuotaField(window, label: "\(limitId).\(windowId)"),
                    resetAt: parseResetMetadata(from: window).resetAt
                )
            }
        }

        let fiveHourWindow = preferredWindow(
            kind: .fiveHour,
            limitId: "codex",
            windowId: "primary",
            in: parsedWindows
        )
        let canonicalWeeklyWindow = parsedWindows.first { $0.limitId == "codex" && $0.windowId == "secondary" && $0.kind == .weekly }
        let fallbackWeeklyWindow = parsedWindows.first { $0.limitId == "codex_other" && $0.windowId == "primary" && $0.kind == .weekly }
        let fiveHour = fiveHourWindow?.field ?? ParsedQuotaField(remaining: 0, state: .unavailable)
        let canonicalWeekly = canonicalWeeklyWindow?.field ?? ParsedQuotaField(remaining: 0, state: .unavailable)
        let fallbackWeekly = fallbackWeeklyWindow?.field ?? ParsedQuotaField(remaining: 0, state: .unavailable)
        let weekly: ParsedQuotaField
        let usesFallbackWeeklySource: Bool
        if canonicalWeekly.state == .live || fallbackWeekly.state != .live {
            weekly = canonicalWeekly
            usesFallbackWeeklySource = false
        } else {
            weekly = fallbackWeekly
            usesFallbackWeeklySource = true
        }

        let fiveHourResetAt = fiveHourWindow?.resetAt
        let resetCredits = parseResetCredits(from: response["rateLimitResetCredits"])

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
                from: rateLimitsByLimitId,
                usesFallbackWeeklySource: usesFallbackWeeklySource,
                retainsLegacyDualMapping: retainsLegacyDualMapping
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
                    resetAt: $0.resetAt
                )
            }
        )
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
        limitId: String,
        windowId: String,
        in windows: [ParsedQuotaWindow]
    ) -> ParsedQuotaWindow? {
        if let exact = windows.first(where: { $0.kind == kind && $0.limitId == limitId && $0.windowId == windowId }) {
            return exact
        }
        return windows.first(where: { $0.kind == kind })
    }

    private static func parseWindowDuration(_ window: [String: Any]) -> Int? {
        let rawValue = window["windowDurationMins"] ?? window["windowDurationMinutes"] ?? window["durationMinutes"]
        if let value = rawValue as? NSNumber {
            return value.intValue
        }
        if let value = rawValue as? Int {
            return value
        }
        if let value = rawValue as? String {
            return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    private static func parseQuotaField(
        _ window: [String: Any]?,
        label: String
    ) -> ParsedQuotaField {
        guard let window else {
            AppLogger.codexRPC.warning("\(label) quota window is unexposed")
            return ParsedQuotaField(remaining: 0, state: .unavailable)
        }

        guard let rawUsedPercent = window["usedPercent"],
              let usedPercent = parsePercentage(rawUsedPercent),
              usedPercent.isFinite else {
            AppLogger.codexRPC.error("\(label) usedPercent is missing, non-numeric, or non-finite")
            return ParsedQuotaField(remaining: 0, state: .invalid)
        }

        guard (0...100).contains(usedPercent) else {
            AppLogger.codexRPC.error("\(label) usedPercent out of range: \(usedPercent, privacy: .public)")
            return ParsedQuotaField(remaining: 0, state: .invalid)
        }

        let remaining = Int((100.0 - usedPercent).rounded())
        guard (0...100).contains(remaining) else {
            AppLogger.codexRPC.error("Computed \(label) remaining value out of range: \(remaining)")
            return ParsedQuotaField(remaining: 0, state: .invalid)
        }

        return ParsedQuotaField(remaining: remaining, state: .live)
    }

    private static func parsePercentage(_ rawValue: Any) -> Double? {
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

    private static func parseResetBanks(
        from rateLimitsByLimitId: [String: Any],
        usesFallbackWeeklySource: Bool,
        retainsLegacyDualMapping: Bool
    ) -> [ResetBankSnapshot] {
        var banks: [ResetBankSnapshot] = []

        for limitId in rateLimitsByLimitId.keys.sorted() {
            guard let bucket = rateLimitsByLimitId[limitId] as? [String: Any] else {
                continue
            }

            for windowId in bucket.keys.sorted() {
                if shouldSkipResetBank(
                    limitId: limitId,
                    windowId: windowId,
                    usesFallbackWeeklySource: usesFallbackWeeklySource
                ) {
                    continue
                }

                guard let window = bucket[windowId] as? [String: Any],
                      let usedPercent = window["usedPercent"].flatMap(parsePercentage),
                      usedPercent.isFinite,
                      usedPercent >= 0,
                      usedPercent <= 100 else {
                    AppLogger.codexRPC.debug("Skipping reset bank \(limitId, privacy: .public).\(windowId, privacy: .public): missing or invalid usedPercent")
                    continue
                }

                let remainingPercent = Int((100.0 - usedPercent).rounded())
                let reset = parseResetMetadata(from: window)
                let durationMinutes = parseWindowDuration(window)
                let kind = classifyWindow(
                    limitId: limitId,
                    windowId: windowId,
                    durationMinutes: durationMinutes,
                    retainsLegacyDualMapping: retainsLegacyDualMapping
                )
                banks.append(
                    ResetBankSnapshot(
                        limitId: limitId,
                        windowId: windowId,
                        displayName: resetBankDisplayName(limitId: limitId, windowId: windowId, kind: kind),
                        remainingPercent: remainingPercent,
                        resetAt: reset.resetAt,
                        resolvedResetFieldName: reset.resolvedFieldName,
                        resetTimeStatus: reset.status,
                        rawResetFields: reset.rawFields,
                        windowKind: kind,
                        durationMinutes: durationMinutes
                    )
                )
            }
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
        var rawFields: [ResetBankRawField] = []
        var parsedDate: Date?
        var resolvedFieldName: String?

        for key in ["resetAt", "resetsAt", "nextResetAt", "windowResetAt"] {
            guard let rawValue = window[key] else {
                continue
            }

            rawFields.append(ResetBankRawField(name: key, value: stringify(rawValue)))
            if parsedDate == nil {
                parsedDate = parseDate(rawValue)
                if parsedDate != nil {
                    resolvedFieldName = key
                }
            }
        }

        let status: ResetBankResetTimeStatus
        if parsedDate != nil {
            status = .actual
        } else if rawFields.isEmpty {
            status = .unexposed
        } else {
            status = .parseFailed
        }

        return ParsedResetMetadata(
            resetAt: parsedDate,
            resolvedFieldName: resolvedFieldName,
            status: status,
            rawFields: rawFields
        )
    }

    private static func parseResetCredits(from rawValue: Any?) -> ParsedResetCredits {
        guard let container = rawValue as? [String: Any] else {
            return ParsedResetCredits(availableCount: nil)
        }

        var availableCount: Int?

        let rawAvailableCount = container["availableCount"] ?? container["available_count"]
        if let count = rawAvailableCount as? Int {
            availableCount = count
        } else if let number = rawAvailableCount as? NSNumber {
            availableCount = number.intValue
        } else if let string = rawAvailableCount as? String, let count = Int(string) {
            availableCount = count
        }

        return ParsedResetCredits(availableCount: availableCount)
    }

    private static func stringify(_ rawValue: Any) -> String {
        if let string = rawValue as? String {
            return string
        }

        if let number = rawValue as? NSNumber {
            return number.stringValue
        }

        if JSONSerialization.isValidJSONObject(rawValue),
           let data = try? JSONSerialization.data(withJSONObject: rawValue, options: [.sortedKeys]),
           let string = String(data: data, encoding: .utf8) {
            return string
        }

        return String(describing: rawValue)
    }

    private static func parseDate(_ rawValue: Any) -> Date? {
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

    private static func dateFromTimestamp(_ rawValue: Double) -> Date? {
        guard rawValue.isFinite, rawValue > 0 else {
            return nil
        }

        let seconds = rawValue > 10_000_000_000 ? rawValue / 1_000 : rawValue
        return Date(timeIntervalSince1970: seconds)
    }

    // MARK: - Codex Path Resolution

    static func resolveCodexPath() -> String {
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
        return "codex"
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
