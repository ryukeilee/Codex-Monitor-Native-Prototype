import Foundation

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

actor CodexRPCClient {
    private let process: Process
    private let stdinPipe: Pipe
    private let stdoutPipe: Pipe
    private let stderrPipe: Pipe

    private var stdoutBuffer = Data()
    private var stderrData = Data()
    private var nextId = 1
    private var hasResumed = false
    private var pendingResolve: ((Data) -> Void)?
    private var completion: ((Result<QuotaSnapshot, Error>) -> Void)?
    private var timeoutWork: DispatchWorkItem?

    init(codexPath: String) throws {
        process = Process()
        stdinPipe = Pipe()
        stdoutPipe = Pipe()
        stderrPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: codexPath)
        process.arguments = ["app-server", "--stdio"]
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
    }

    func fetchQuota(timeoutSeconds: Double) async throws -> QuotaSnapshot {
        try await withCheckedThrowingContinuation { continuation in
            self.completion = { result in
                switch result {
                case .success(let snapshot):
                    continuation.resume(returning: snapshot)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }

            Task { setupAndRun(timeoutSeconds: timeoutSeconds) }
        }
    }

    private func setupAndRun(timeoutSeconds: Double) {
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            Task { await self.handleStdoutChunk(chunk) }
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let chunk = handle.availableData
            if !chunk.isEmpty {
                Task { await self.handleStderrChunk(chunk) }
            }
        }

        process.terminationHandler = { [weak self] proc in
            guard let self else { return }
            Task { await self.handleTermination(status: proc.terminationStatus) }
        }

        do {
            try process.run()
        } catch {
            complete(.failure(RealQuotaError.spawnFailed(error.localizedDescription)))
            return
        }

        // Set up timeout
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Task { await self.handleTimeout() }
        }
        timeoutWork = work
        DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds, execute: work)

        // Step 1: Send initialize
        sendRequest(method: "initialize", params: [
            "clientInfo": [
                "name": "codex-monitor-native",
                "title": "Codex Monitor Native",
                "version": "0.2.0"
            ]
        ])

        // Step 2: Wait for initialize response, then send initialized + rate limits request
        pendingResolve = { [weak self] _ in
            guard let self else { return }
            Task { await self.handleInitialized() }
        }
    }

    private func handleInitialized() {
        let notif: [String: Any] = ["method": "initialized"]
        if let notifData = try? JSONSerialization.data(withJSONObject: notif, options: []),
           let notifLine = String(data: notifData, encoding: .utf8) {
            writeLine(notifLine)
        }

        sendRequest(method: "account/rateLimits/read")

        pendingResolve = { [weak self] responseData in
            guard let self else { return }
            Task { await self.handleRateLimitsResponse(responseData) }
        }
    }

    private func handleRateLimitsResponse(_ responseData: Data) {
        timeoutWork?.cancel()

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
            pendingResolve?(messageData)
            pendingResolve = nil
        }
    }

    private func sendRequest(method: String, params: [String: Any]? = nil) {
        let dict: [String: Any] = [
            "id": nextId,
            "method": method,
            "params": params as Any
        ]
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
        stdinPipe.fileHandleForWriting.write(lineData)
    }

    private func complete(_ result: Result<QuotaSnapshot, Error>) {
        guard !hasResumed else { return }
        hasResumed = true

        if process.isRunning {
            process.terminate()
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil

        completion?(result)
    }
}

struct RealQuotaProvider {
    private struct ParsedResetMetadata {
        let resetAt: Date?
        let resolvedFieldName: String?
        let status: ResetBankResetTimeStatus
        let rawFields: [ResetBankRawField]
    }

    private struct ParsedResetCredits {
        let availableCount: Int?
        let timeEntries: [ResetCreditTimeSnapshot]
        let rawFields: [ResetCreditRawField]
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

    // MARK: - Response Parsing (with strict validation)

    static func parseRateLimits(response: [String: Any]) -> QuotaSnapshot? {
        let rateLimitsByLimitId = response["rateLimitsByLimitId"] as? [String: Any] ?? [:]

        guard let codexBucket = rateLimitsByLimitId["codex"] as? [String: Any] else {
            AppLogger.codexRPC.error("No codex bucket in rate limits response")
            return nil
        }

        // Primary (5-hour) window
        guard let primary = codexBucket["primary"] as? [String: Any] else {
            AppLogger.codexRPC.error("No primary window in codex bucket")
            return nil
        }

        guard let primaryUsedPercent = primary["usedPercent"] as? Double,
              primaryUsedPercent.isFinite else {
            AppLogger.codexRPC.error("Primary usedPercent is missing, non-numeric, or non-finite")
            return nil
        }

        guard primaryUsedPercent >= 0 && primaryUsedPercent <= 100 else {
            AppLogger.codexRPC.error("Primary usedPercent out of range: \(primaryUsedPercent, privacy: .public)")
            return nil
        }

        let fiveHourRemaining = Int((100.0 - primaryUsedPercent).rounded())
        let fiveHourResetAt = parseResetMetadata(from: primary).resetAt
        let resetCredits = parseResetCredits(from: response["rateLimitResetCredits"])

        // Secondary (weekly) window
        let secondary: [String: Any]? = codexBucket["secondary"] as? [String: Any]
        let codexOtherBucket = rateLimitsByLimitId["codex_other"] as? [String: Any]
        let fallbackSecondary = codexOtherBucket?["primary"] as? [String: Any]

        let effectiveSecondary = secondary ?? fallbackSecondary

        let weeklyUsedPercent: Double
        if let sec = effectiveSecondary {
            guard let used = sec["usedPercent"] as? Double, used.isFinite else {
                AppLogger.codexRPC.error("Secondary usedPercent is missing, non-numeric, or non-finite")
                return nil
            }

            guard used >= 0 && used <= 100 else {
                AppLogger.codexRPC.error("Secondary usedPercent out of range: \(used, privacy: .public)")
                return nil
            }
            weeklyUsedPercent = used
        } else {
            AppLogger.codexRPC.warning("No secondary window; defaulting to 0 used")
            weeklyUsedPercent = 0
        }

        let weeklyRemaining = Int((100.0 - weeklyUsedPercent).rounded())

        // Final range clamp (defense in depth)
        guard (0...100).contains(fiveHourRemaining), (0...100).contains(weeklyRemaining) else {
            AppLogger.codexRPC.error("Computed values out of range: weekly=\(weeklyRemaining) fiveHour=\(fiveHourRemaining)")
            return nil
        }

        AppLogger.codexRPC.info("Parsed real quota: weekly=\(weeklyRemaining)% fiveHour=\(fiveHourRemaining)%")

        let usesFallbackWeeklySource = secondary == nil && fallbackSecondary != nil

        return QuotaSnapshot(
            weeklyQuotaPercent: weeklyRemaining,
            fiveHourQuotaPercent: fiveHourRemaining,
            resetAvailableCount: resetCredits.availableCount,
            resetCreditTimeEntries: resetCredits.timeEntries,
            resetCreditRawFields: resetCredits.rawFields,
            fiveHourResetAt: fiveHourResetAt,
            resetBanks: parseResetBanks(
                from: rateLimitsByLimitId,
                usesFallbackWeeklySource: usesFallbackWeeklySource
            ),
            refreshedAt: .now,
            dataSource: .real,
            errorMessage: nil
        )
    }

    private static func parseResetBanks(
        from rateLimitsByLimitId: [String: Any],
        usesFallbackWeeklySource: Bool
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
                      let usedPercent = window["usedPercent"] as? Double,
                      usedPercent.isFinite,
                      usedPercent >= 0,
                      usedPercent <= 100 else {
                    AppLogger.codexRPC.debug("Skipping reset bank \(limitId, privacy: .public).\(windowId, privacy: .public): missing or invalid usedPercent")
                    continue
                }

                let remainingPercent = Int((100.0 - usedPercent).rounded())
                let reset = parseResetMetadata(from: window)
                banks.append(
                    ResetBankSnapshot(
                        limitId: limitId,
                        windowId: windowId,
                        displayName: resetBankDisplayName(limitId: limitId, windowId: windowId),
                        remainingPercent: remainingPercent,
                        resetAt: reset.resetAt,
                        resolvedResetFieldName: reset.resolvedFieldName,
                        resetTimeStatus: reset.status,
                        rawResetFields: reset.rawFields
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

    private static func resetBankDisplayName(limitId: String, windowId: String) -> String {
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
            return ParsedResetCredits(availableCount: nil, timeEntries: [], rawFields: [])
        }

        var rawFields: [ResetCreditRawField] = []
        var availableCount: Int?
        var timeEntries: [ResetCreditTimeSnapshot] = []

        func walk(_ value: Any, path: String) {
            if let nested = value as? [String: Any] {
                for key in nested.keys.sorted() {
                    guard let child = nested[key] else { continue }
                    walk(child, path: "\(path).\(key)")
                }
                return
            }

            if let nested = value as? [Any] {
                for (index, child) in nested.enumerated() {
                    walk(child, path: "\(path)[\(index)]")
                }
                return
            }

            let valueText = stringify(value)
            rawFields.append(ResetCreditRawField(path: path, value: valueText))

            if path == "rateLimitResetCredits.availableCount" {
                if let count = value as? Int {
                    availableCount = count
                } else if let number = value as? NSNumber {
                    availableCount = number.intValue
                } else if let string = value as? String, let count = Int(string) {
                    availableCount = count
                }
            }

            guard let label = resetCreditTimeLabel(for: path), let date = parseDate(value) else {
                return
            }

            timeEntries.append(
                ResetCreditTimeSnapshot(
                    label: label,
                    date: date,
                    sourcePath: path
                )
            )
        }

        walk(container, path: "rateLimitResetCredits")

        let sortedEntries = timeEntries
            .sorted { lhs, rhs in
                if lhs.date != rhs.date {
                    return lhs.date < rhs.date
                }
                if lhs.label != rhs.label {
                    return lhs.label < rhs.label
                }
                return lhs.sourcePath < rhs.sourcePath
            }
            .prefix(3)

        return ParsedResetCredits(
            availableCount: availableCount,
            timeEntries: Array(sortedEntries),
            rawFields: rawFields
        )
    }

    private static func resetCreditTimeLabel(for path: String) -> String? {
        let terminal = path
            .split(separator: ".")
            .last
            .map(String.init)?
            .replacingOccurrences(of: #"\[\d+\]"#, with: "", options: .regularExpression)

        switch terminal {
        case "expiresAt", "expireAt":
            return "到期时间"
        case "restoresAt", "restoreAt", "resetAt", "resetsAt", "nextResetAt":
            return "恢复时间"
        default:
            return nil
        }
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
