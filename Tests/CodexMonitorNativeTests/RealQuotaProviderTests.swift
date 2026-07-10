import XCTest
@testable import CodexMonitorNative

final class RealQuotaProviderTests: XCTestCase {
    func testProcessTransportEscalatesAndReclaimsChildAfterKill() throws {
        let process = ControlledProcessHandle(terminateExits: false, killExits: true)
        let transport = ProcessRPCTransport(process: process, shutdownGraceSeconds: 0)

        try transport.start(stdout: { _ in }, stderr: { _ in }, termination: { _ in })
        try transport.shutdownAndWait()

        XCTAssertEqual(process.terminateCount, 1)
        XCTAssertEqual(process.killCount, 1)
        XCTAssertTrue(process.handlersCleared)
    }

    func testProcessTransportThrowsCleanupFailureWhenChildSurvivesKill() throws {
        let process = ControlledProcessHandle(terminateExits: false, killExits: false)
        let transport = ProcessRPCTransport(process: process, shutdownGraceSeconds: 0)
        try transport.start(stdout: { _ in }, stderr: { _ in }, termination: { _ in })

        XCTAssertThrowsError(try transport.shutdownAndWait()) { error in
            XCTAssertEqual(error as? ProcessCleanupError, .processDidNotExit)
        }
        XCTAssertEqual(process.terminateCount, 1)
        XCTAssertEqual(process.killCount, 1)
        XCTAssertTrue(process.handlersCleared)
    }

    func testProcessTransportPropagatesForceKillFailureAndCleansUpOnce() throws {
        let process = ControlledProcessHandle(terminateExits: false, killExits: false, killSucceeds: false)
        let transport = ProcessRPCTransport(process: process, shutdownGraceSeconds: 0)
        try transport.start(stdout: { _ in }, stderr: { _ in }, termination: { _ in })

        XCTAssertThrowsError(try transport.shutdownAndWait()) { error in
            XCTAssertEqual(error as? ProcessCleanupError, .forceKillFailed)
        }
        XCTAssertEqual(process.terminateCount, 1)
        XCTAssertEqual(process.killCount, 1)
        XCTAssertTrue(process.handlersCleared)
    }

    func testRPCClientCompletesOnceWithForceKillFailure() async {
        let transport = ControlledRPCTransport(cleanupError: .forceKillFailed)
        let timeoutScheduler = ControlledTimeoutScheduler()
        let client = CodexRPCClient(transport: transport, timeoutScheduler: timeoutScheduler)
        let task = Task { try await client.fetchQuota(timeoutSeconds: 60) }

        await fulfillment(of: [transport.startedExpectation, transport.initializeRequestExpectation], timeout: 1)
        transport.emitStdout(Data("{\"result\":{\"protocolVersion\":1}}\n".utf8))
        await fulfillment(of: [transport.rateLimitRequestExpectation], timeout: 1)
        transport.emitStdout(Self.rateLimitResponse)

        do {
            _ = try await task.value
            XCTFail("Expected cleanup failure")
        } catch let error as ProcessCleanupError {
            XCTAssertEqual(error, .forceKillFailed)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(transport.shutdownCount, 1)
        XCTAssertTrue(transport.handlersCleared)
    }
    func testRPCClientCancellationCancelsTimeoutAndReclaimsTransportExactlyOnce() async {
        let transport = ControlledRPCTransport()
        let timeoutScheduler = ControlledTimeoutScheduler()
        let client = CodexRPCClient(transport: transport, timeoutScheduler: timeoutScheduler)

        let task = Task {
            try await client.fetchQuota(timeoutSeconds: 60)
        }

        await fulfillment(of: [transport.startedExpectation], timeout: 1)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }

        XCTAssertEqual(transport.shutdownCount, 1)
        XCTAssertEqual(timeoutScheduler.cancelCount, 1)
        XCTAssertTrue(transport.handlersCleared)
    }

    func testRPCClientTimeoutReclaimsTransportAndIgnoresLateResponse() async {
        let transport = ControlledRPCTransport()
        let timeoutScheduler = ControlledTimeoutScheduler()
        let client = CodexRPCClient(transport: transport, timeoutScheduler: timeoutScheduler)

        let task = Task {
            try await client.fetchQuota(timeoutSeconds: 60)
        }

        await fulfillment(of: [transport.startedExpectation], timeout: 1)
        timeoutScheduler.fire()

        do {
            _ = try await task.value
            XCTFail("Expected timeout")
        } catch let error as RealQuotaError {
            guard case .requestTimedOut = error else {
                return XCTFail("Expected request timeout, got \(error)")
            }
        } catch {
            XCTFail("Expected request timeout, got \(error)")
        }

        transport.emitStdout(Self.rateLimitResponse)
        XCTAssertEqual(transport.shutdownCount, 1)
        XCTAssertEqual(timeoutScheduler.cancelCount, 1)
        XCTAssertTrue(transport.handlersCleared)
    }

    func testRPCClientRPCErrorReclaimsTransportExactlyOnce() async {
        let transport = ControlledRPCTransport()
        let timeoutScheduler = ControlledTimeoutScheduler()
        let client = CodexRPCClient(transport: transport, timeoutScheduler: timeoutScheduler)
        let task = Task { try await client.fetchQuota(timeoutSeconds: 60) }

        await fulfillment(of: [transport.startedExpectation], timeout: 1)
        transport.emitStdout(Data("{\"error\":{\"message\":\"rejected\"}}\n".utf8))

        do {
            _ = try await task.value
            XCTFail("Expected RPC error")
        } catch let error as RealQuotaError {
            guard case .rpcError("rejected") = error else { return XCTFail("Unexpected error: \(error)") }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(transport.shutdownCount, 1)
        XCTAssertEqual(timeoutScheduler.cancelCount, 1)
    }

    func testRPCClientProcessExitReclaimsTransportExactlyOnce() async {
        let transport = ControlledRPCTransport()
        let timeoutScheduler = ControlledTimeoutScheduler()
        let client = CodexRPCClient(transport: transport, timeoutScheduler: timeoutScheduler)
        let task = Task { try await client.fetchQuota(timeoutSeconds: 60) }

        await fulfillment(of: [transport.startedExpectation], timeout: 1)
        transport.emitTermination(status: 9)

        do {
            _ = try await task.value
            XCTFail("Expected process exit error")
        } catch let error as RealQuotaError {
            guard case .processExited(9, _) = error else { return XCTFail("Unexpected error: \(error)") }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(transport.shutdownCount, 1)
        XCTAssertEqual(timeoutScheduler.cancelCount, 1)
    }

    func testRPCClientSuccessfulResponseReclaimsTransportExactlyOnce() async throws {
        let transport = ControlledRPCTransport()
        let timeoutScheduler = ControlledTimeoutScheduler()
        let client = CodexRPCClient(transport: transport, timeoutScheduler: timeoutScheduler)
        let task = Task { try await client.fetchQuota(timeoutSeconds: 60) }

        await fulfillment(of: [transport.startedExpectation], timeout: 1)
        await fulfillment(of: [transport.initializeRequestExpectation], timeout: 1)
        transport.emitStdout(Data("{\"result\":{\"protocolVersion\":1}}\n".utf8))
        await fulfillment(of: [transport.rateLimitRequestExpectation], timeout: 1)
        transport.emitStdout(Self.rateLimitResponse)

        let snapshot = try await task.value
        XCTAssertEqual(snapshot.fiveHourQuotaPercent, 50)
        XCTAssertEqual(transport.shutdownCount, 1)
        XCTAssertEqual(timeoutScheduler.cancelCount, 1)
    }

    func testRPCClientUnusableResponseReclaimsTransportExactlyOnce() async {
        let transport = ControlledRPCTransport()
        let timeoutScheduler = ControlledTimeoutScheduler()
        let client = CodexRPCClient(transport: transport, timeoutScheduler: timeoutScheduler)
        let task = Task { try await client.fetchQuota(timeoutSeconds: 60) }

        await fulfillment(of: [transport.startedExpectation, transport.initializeRequestExpectation], timeout: 1)
        transport.emitStdout(Data("{\"result\":{\"protocolVersion\":1}}\n".utf8))
        await fulfillment(of: [transport.rateLimitRequestExpectation], timeout: 1)
        transport.emitStdout(Data("{\"result\":{}}\n".utf8))

        do {
            _ = try await task.value
            XCTFail("Expected unusable rate limits error")
        } catch let error as RealQuotaError {
            guard case .noUsableRateLimits = error else { return XCTFail("Unexpected error: \(error)") }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(transport.shutdownCount, 1)
        XCTAssertEqual(timeoutScheduler.cancelCount, 1)
    }

    private static let rateLimitResponse = Data("{\"result\":{\"rateLimitsByLimitId\":{\"codex\":{\"primary\":{\"usedPercent\":50}}}}}\n".utf8)
    func testParseRateLimitsPrefersCanonicalWeeklyBankAndKeepsFastestEntries() {
        let response: [String: Any] = [
            "rateLimitResetCredits": [
                "availableCount": 5
            ],
            "rateLimitsByLimitId": [
                "codex": [
                    "primary": [
                        "usedPercent": 57.0,
                        "resetAt": "2026-06-19T14:10:00Z"
                    ],
                    "secondary": [
                        "usedPercent": 48.0,
                        "nextResetAt": "2026-06-20T10:00:00Z"
                    ]
                ],
                "codex_other": [
                    "primary": [
                        "usedPercent": 25.0,
                        "windowResetAt": "2026-06-19T13:00:00Z"
                    ]
                ],
                "bonus": [
                    "primary": [
                        "usedPercent": 10.0,
                        "resetsAt": "2026-06-21T10:00:00Z"
                    ]
                ]
            ]
        ]

        let snapshot = RealQuotaProvider.parseRateLimits(response: response)

        XCTAssertEqual(snapshot?.fiveHourQuotaPercent, 43)
        XCTAssertEqual(snapshot?.weeklyQuotaPercent, 52)
        XCTAssertEqual(snapshot?.resetAvailableCount, 5)
        XCTAssertEqual(snapshot?.resetCreditDetailsState, .appServerCountOnly)
        XCTAssertTrue(snapshot?.resetCreditDetails.isEmpty ?? false)
        XCTAssertTrue(snapshot?.resetCreditStatusSummary.isEmpty ?? false)
        XCTAssertTrue(snapshot?.resetCreditTimeEntries.isEmpty ?? false)
        XCTAssertEqual(snapshot?.resetBanks.map(\.id), [
            "codex.primary",
            "codex.secondary",
            "bonus.primary"
        ])
    }

    func testParseRateLimitsDoesNotPromoteNormalBankResetTimeIntoResetCredits() {
        let response: [String: Any] = [
            "rateLimitResetCredits": [
                "availableCount": 5
            ],
            "rateLimitsByLimitId": [
                "codex": [
                    "primary": [
                        "usedPercent": 57.0,
                        "resetAt": "2026-06-19T14:10:00Z"
                    ]
                ]
            ]
        ]

        let snapshot = RealQuotaProvider.parseRateLimits(response: response)

        XCTAssertEqual(snapshot?.resetAvailableCount, 5)
        XCTAssertEqual(snapshot?.resetCreditDetailsState, .appServerCountOnly)
        XCTAssertTrue(snapshot?.resetCreditDetails.isEmpty ?? false)
        XCTAssertTrue(snapshot?.resetCreditTimeEntries.isEmpty ?? false)
        XCTAssertEqual(snapshot?.resetBanks.first?.resolvedResetFieldName, "resetAt")
    }

    func testParseRateLimitsDoesNotUseAppServerResetCreditDates() {
        let response: [String: Any] = [
            "rateLimitResetCredits": [
                "availableCount": 5,
                "restoresAt": [
                    1_718_000_600,
                    1_718_004_200
                ],
                "expiresAt": [
                    1_718_007_800
                ],
                "windowStartAt": 1_717_900_000
            ],
            "rateLimitsByLimitId": [
                "codex": [
                    "primary": [
                        "usedPercent": 57.0,
                        "resetAt": "2026-06-19T14:10:00Z"
                    ]
                ]
            ]
        ]

        let snapshot = RealQuotaProvider.parseRateLimits(response: response)

        XCTAssertEqual(snapshot?.resetAvailableCount, 5)
        XCTAssertEqual(snapshot?.resetCreditDetailsState, .appServerCountOnly)
        XCTAssertTrue(snapshot?.resetCreditDetails.isEmpty ?? false)
        XCTAssertTrue(snapshot?.resetCreditStatusSummary.isEmpty ?? false)
        XCTAssertTrue(snapshot?.resetCreditTimeEntries.isEmpty ?? false)
        XCTAssertTrue(snapshot?.resetCreditRawFields.isEmpty ?? false)
    }

    func testParseRateLimitsUsesFallbackWeeklyBankWhenSecondaryMissing() {
        let response: [String: Any] = [
            "rateLimitsByLimitId": [
                "codex": [
                    "primary": [
                        "usedPercent": 57.0,
                        "resetAt": "2026-06-19T14:10:00Z"
                    ]
                ],
                "codex_other": [
                    "primary": [
                        "usedPercent": 25.0,
                        "windowResetAt": "2026-06-19T13:00:00Z"
                    ]
                ]
            ]
        ]

        let snapshot = RealQuotaProvider.parseRateLimits(response: response)

        XCTAssertEqual(snapshot?.weeklyQuotaPercent, 75)
        XCTAssertEqual(snapshot?.resetBanks.map(\.id), [
            "codex_other.primary",
            "codex.primary"
        ])
    }

    func testParseRateLimitsKeepsUnknownResetBankRawFields() {
        let response: [String: Any] = [
            "rateLimitsByLimitId": [
                "codex": [
                    "primary": [
                        "usedPercent": 61.0
                    ],
                    "secondary": [
                        "usedPercent": 35.0,
                        "nextResetAt": NSNull()
                    ]
                ]
            ]
        ]

        let snapshot = RealQuotaProvider.parseRateLimits(response: response)

        XCTAssertEqual(snapshot?.resetBanks.count, 2)
        XCTAssertNil(snapshot?.resetBanks.first?.resetAt)
        XCTAssertEqual(snapshot?.resetBanks.first?.rawResetFields, [])
        XCTAssertEqual(
            snapshot?.resetBanks.last?.rawResetFields,
            [ResetBankRawField(name: "nextResetAt", value: "<null>")]
        )
    }
}

private final class ControlledProcessHandle: ProcessRPCProcess, @unchecked Sendable {
    var isRunning = true
    var terminationStatus: Int32 = 0
    var terminationHandler: (@Sendable (any ProcessRPCProcess) -> Void)?
    let terminateExits: Bool
    let killExits: Bool
    private(set) var terminateCount = 0
    private(set) var killCount = 0
    var handlersCleared: Bool { terminationHandler == nil }

    let killSucceeds: Bool

    init(terminateExits: Bool, killExits: Bool, killSucceeds: Bool = true) {
        self.terminateExits = terminateExits
        self.killExits = killExits
        self.killSucceeds = killSucceeds
    }

    func configure(codexPath _: String, stdin _: Pipe, stdout _: Pipe, stderr _: Pipe) {}
    func run() throws {}

    func terminate() {
        terminateCount += 1
        if terminateExits { exit() }
    }

    func kill() -> Bool {
        killCount += 1
        if killExits { exit() }
        return killSucceeds
    }

    private func exit() {
        isRunning = false
        terminationHandler?(self)
    }
}

private final class ControlledRPCTransport: CodexRPCTransport, @unchecked Sendable {
    let startedExpectation = XCTestExpectation(description: "transport started")
    let initializeRequestExpectation = XCTestExpectation(description: "initialize request written")
    let rateLimitRequestExpectation = XCTestExpectation(description: "rate limits request written")
    private(set) var shutdownCount = 0
    private(set) var handlersCleared = false
    private var stdout: (@Sendable (Data) -> Void)?
    private var stderr: (@Sendable (Data) -> Void)?
    private var termination: (@Sendable (Int32) -> Void)?
    private let cleanupError: ProcessCleanupError?

    init(cleanupError: ProcessCleanupError? = nil) {
        self.cleanupError = cleanupError
    }

    func start(
        stdout: @escaping @Sendable (Data) -> Void,
        stderr: @escaping @Sendable (Data) -> Void,
        termination: @escaping @Sendable (Int32) -> Void
    ) throws {
        self.stdout = stdout
        self.stderr = stderr
        self.termination = termination
        startedExpectation.fulfill()
    }

    func write(_ data: Data) {
        guard let line = String(data: data, encoding: .utf8) else { return }
        if line.contains("\"method\":\"initialize\"") {
            initializeRequestExpectation.fulfill()
        }
        if line.contains("rateLimits") {
            rateLimitRequestExpectation.fulfill()
        }
    }

    func shutdownAndWait() throws {
        shutdownCount += 1
        stdout = nil
        stderr = nil
        termination = nil
        handlersCleared = true
        if let cleanupError { throw cleanupError }
    }

    func emitStdout(_ data: Data) {
        stdout?(data)
    }

    func emitTermination(status: Int32) {
        termination?(status)
    }
}

private final class ControlledTimeoutScheduler: CodexRPCTimeoutScheduling, @unchecked Sendable {
    private var action: (@Sendable () -> Void)?
    private(set) var cancelCount = 0

    func schedule(after _: Double, action: @escaping @Sendable () -> Void) -> any CodexRPCCancellable {
        self.action = action
        return Token { [weak self] in
            self?.cancelCount += 1
            self?.action = nil
        }
    }

    func fire() {
        action?()
    }

    private final class Token: CodexRPCCancellable, @unchecked Sendable {
        private let onCancel: @Sendable () -> Void

        init(onCancel: @escaping @Sendable () -> Void) {
            self.onCancel = onCancel
        }

        func cancel() {
            onCancel()
        }
    }
}
