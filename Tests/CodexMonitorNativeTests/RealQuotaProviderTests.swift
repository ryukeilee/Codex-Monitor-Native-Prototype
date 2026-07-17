import Darwin
import XCTest
@testable import CodexMonitorNative

final class RealQuotaProviderTests: XCTestCase {
    func testRPCEventQueueReleasesProcessedOperationWhileDrainRemainsActive() async {
        let queue = CodexRPCEventQueue()
        let firstProcessed = XCTestExpectation(description: "first operation processed")
        let firstReleased = XCTestExpectation(description: "first operation released")
        let secondStarted = XCTestExpectation(description: "second operation started")
        let gate = AsyncTestGate()

        do {
            let probe = LifetimeProbe { firstReleased.fulfill() }
            queue.enqueue {
                probe.touch()
                firstProcessed.fulfill()
            }
        }
        queue.enqueue {
            secondStarted.fulfill()
            await gate.wait()
        }

        await fulfillment(of: [firstProcessed, secondStarted, firstReleased], timeout: 1)
        await gate.open()
    }

    func testProcessTransportClearsHandlersAfterLaunchFailure() throws {
        let process = ControlledProcessHandle(
            terminateExits: false,
            killExits: false,
            runError: .startFailed
        )
        let transport = ProcessRPCTransport(process: process, shutdownGraceSeconds: 0)

        XCTAssertEqual(process.configuredArguments, ["app-server"])

        XCTAssertThrowsError(
            try transport.start(stdout: { _ in }, stdoutEOF: {}, stderr: { _ in }, termination: { _ in })
        ) { error in
            XCTAssertEqual(error as? ControlledRPCTransportError, .startFailed)
        }
        XCTAssertNoThrow(try transport.shutdownAndWait())
        XCTAssertTrue(process.handlersCleared)
    }

    func testProcessTransportEscalatesAndReclaimsChildAfterKill() throws {
        let process = ControlledProcessHandle(terminateExits: false, killExits: true)
        let transport = ProcessRPCTransport(process: process, shutdownGraceSeconds: 0)

        try transport.start(stdout: { _ in }, stdoutEOF: {}, stderr: { _ in }, termination: { _ in })
        try transport.shutdownAndWait()

        XCTAssertEqual(process.terminateCount, 1)
        XCTAssertEqual(process.killCount, 1)
        XCTAssertTrue(process.handlersCleared)
    }

    func testProcessTransportConcurrentShutdownIsIdempotentAndClosesEveryPipeEndpoint() async throws {
        let process = ControlledProcessHandle(terminateExits: false, killExits: true)
        let transport = ProcessRPCTransport(process: process, shutdownGraceSeconds: 0)
        try transport.start(stdout: { _ in }, stdoutEOF: {}, stderr: { _ in }, termination: { _ in })

        let results = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for _ in 0..<8 {
                group.addTask {
                    do {
                        try transport.shutdownAndWait()
                        return true
                    } catch {
                        return false
                    }
                }
            }
            var results: [Bool] = []
            for await result in group {
                results.append(result)
            }
            return results
        }

        XCTAssertEqual(results, Array(repeating: true, count: 8))
        XCTAssertEqual(process.terminateCount, 1)
        XCTAssertEqual(process.killCount, 1)
        XCTAssertTrue(process.handlersCleared)
    }

    func testProcessTransportRepeatedCyclesCloseFileDescriptorsWhileTransportsRemainRetained() throws {
        for _ in 0..<5 {
            try autoreleasepool {
                try runCompletedTransportCycle()
            }
        }
        let baselineCount = openFileDescriptorCount()
        var retainedTransports: [ProcessRPCTransport] = []

        for _ in 0..<100 {
            let process = ControlledProcessHandle(terminateExits: true, killExits: true)
            let transport = ProcessRPCTransport(process: process, shutdownGraceSeconds: 0)
            try transport.start(stdout: { _ in }, stdoutEOF: {}, stderr: { _ in }, termination: { _ in })
            try transport.shutdownAndWait()
            XCTAssertTrue(process.handlersCleared)
            retainedTransports.append(transport)
        }

        XCTAssertLessThanOrEqual(openFileDescriptorCount(), baselineCount)
        withExtendedLifetime(retainedTransports) {}
    }

    func testProcessTransportThrowsCleanupFailureWhenChildSurvivesKill() throws {
        let process = ControlledProcessHandle(terminateExits: false, killExits: false)
        let transport = ProcessRPCTransport(process: process, shutdownGraceSeconds: 0)
        try transport.start(stdout: { _ in }, stdoutEOF: {}, stderr: { _ in }, termination: { _ in })

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
        try transport.start(stdout: { _ in }, stdoutEOF: {}, stderr: { _ in }, termination: { _ in })

        XCTAssertThrowsError(try transport.shutdownAndWait()) { error in
            XCTAssertEqual(error as? ProcessCleanupError, .forceKillFailed)
        }
        XCTAssertThrowsError(try transport.shutdownAndWait()) { error in
            XCTAssertEqual(error as? ProcessCleanupError, .forceKillFailed)
        }
        XCTAssertEqual(process.terminateCount, 1)
        XCTAssertEqual(process.killCount, 1)
        XCTAssertTrue(process.handlersCleared)
    }

    func testProcessTransportDeliversNaturalExitTailsBeforeTermination() async throws {
        let process = ControlledProcessHandle(terminateExits: true, killExits: true)
        let transport = ProcessRPCTransport(process: process, shutdownGraceSeconds: 0)
        let recorder = RPCTransportEventRecorder()
        let terminated = XCTestExpectation(description: "termination delivered")

        try transport.start(
            stdout: { recorder.recordStdout($0) },
            stdoutEOF: { recorder.record("stdoutEOF") },
            stderr: { recorder.recordStderr($0) },
            termination: { status in
                recorder.record("termination:\(status)")
                terminated.fulfill()
            }
        )
        process.emitNaturalExit(
            status: 7,
            stdout: Data("final-response".utf8),
            stderr: Data("final-diagnostic".utf8)
        )

        await fulfillment(of: [terminated], timeout: 1)
        try transport.shutdownAndWait()
        let events = recorder.snapshot()
        XCTAssertEqual(String(data: events.stdout, encoding: .utf8), "final-response")
        XCTAssertEqual(String(data: events.stderr, encoding: .utf8), "final-diagnostic")
        let terminationIndex = try XCTUnwrap(events.order.firstIndex(of: "termination:7"))
        XCTAssertLessThan(try XCTUnwrap(events.order.firstIndex(of: "stdout")), terminationIndex)
        XCTAssertLessThan(try XCTUnwrap(events.order.firstIndex(of: "stderr")), terminationIndex)
        XCTAssertEqual(events.order.last, "termination:7")
        XCTAssertTrue(process.handlersCleared)
    }

    private func runCompletedTransportCycle() throws {
        let process = ControlledProcessHandle(terminateExits: true, killExits: true)
        let transport = ProcessRPCTransport(process: process, shutdownGraceSeconds: 0)
        try transport.start(stdout: { _ in }, stdoutEOF: {}, stderr: { _ in }, termination: { _ in })
        try transport.shutdownAndWait()
    }

    private func openFileDescriptorCount() -> Int {
        (0..<Int(getdtablesize())).reduce(into: 0) { count, descriptor in
            if fcntl(Int32(descriptor), F_GETFD) != -1 {
                count += 1
            }
        }
    }

    func testRPCClientCompletesOnceWithForceKillFailure() async {
        let transport = ControlledRPCTransport(cleanupError: .forceKillFailed)
        let timeoutScheduler = ControlledTimeoutScheduler()
        let client = CodexRPCClient(transport: transport, timeoutScheduler: timeoutScheduler)
        let task = Task { try await client.fetchQuota(timeoutSeconds: 60) }

        await fulfillment(of: [transport.startedExpectation, transport.initializeRequestExpectation], timeout: 1)
        transport.emitStdout(Self.initializeResponse)
        await fulfillment(of: [transport.rateLimitRequestExpectation], timeout: 1)
        transport.emitStdout(Self.rateLimitResponse)

        do {
            _ = try await task.value
            XCTFail("Expected cleanup failure")
        } catch let error as RealQuotaError {
            XCTAssertEqual(error, .processCleanupFailed)
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

    func testRPCClientProcessesAlreadyQueuedResponseBeforeLaterTimeout() async throws {
        let transport = ControlledRPCTransport()
        let timeoutScheduler = ControlledTimeoutScheduler()
        let client = CodexRPCClient(transport: transport, timeoutScheduler: timeoutScheduler)
        let task = Task { try await client.fetchQuota(timeoutSeconds: 60) }

        await fulfillment(of: [transport.initializeRequestExpectation], timeout: 1)
        transport.emitStdout(Self.initializeResponse)
        await fulfillment(of: [transport.rateLimitRequestExpectation], timeout: 1)
        transport.emitStdout(Self.rateLimitResponse)
        timeoutScheduler.fire()

        let snapshot = try await task.value
        XCTAssertEqual(snapshot.fiveHourQuotaPercent, 50)
        XCTAssertEqual(transport.shutdownCount, 1)
    }

    func testRPCClientRPCErrorReclaimsTransportExactlyOnce() async {
        let transport = ControlledRPCTransport()
        let timeoutScheduler = ControlledTimeoutScheduler()
        let client = CodexRPCClient(transport: transport, timeoutScheduler: timeoutScheduler)
        let task = Task { try await client.fetchQuota(timeoutSeconds: 60) }

        await fulfillment(of: [transport.startedExpectation], timeout: 1)
        transport.emitStdout(Data("{\"id\":1,\"error\":{\"code\":-32000,\"message\":\"rejected\"}}\n".utf8))

        do {
            _ = try await task.value
            XCTFail("Expected RPC error")
        } catch let error as RealQuotaError {
            XCTAssertEqual(error, .rpcRejected(code: -32_000))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(transport.shutdownCount, 1)
        XCTAssertEqual(timeoutScheduler.cancelCount, 1)
    }

    func testRPCClientExitBeforeInitializationIsClassifiedAsSpawnFailure() async {
        let transport = ControlledRPCTransport()
        let timeoutScheduler = ControlledTimeoutScheduler()
        let client = CodexRPCClient(transport: transport, timeoutScheduler: timeoutScheduler)
        let task = Task { try await client.fetchQuota(timeoutSeconds: 60) }

        await fulfillment(of: [transport.startedExpectation], timeout: 1)
        transport.emitTermination(status: 9)

        do {
            _ = try await task.value
            XCTFail("Expected spawn failure")
        } catch let error as RealQuotaError {
            XCTAssertEqual(error, .spawnFailed)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(transport.shutdownCount, 1)
        XCTAssertEqual(timeoutScheduler.cancelCount, 1)
    }

    func testRPCClientExitAfterInitializationIsClassifiedAsProcessExit() async {
        let transport = ControlledRPCTransport()
        let timeoutScheduler = ControlledTimeoutScheduler()
        let client = CodexRPCClient(transport: transport, timeoutScheduler: timeoutScheduler)
        let task = Task { try await client.fetchQuota(timeoutSeconds: 60) }

        await fulfillment(of: [transport.initializeRequestExpectation], timeout: 1)
        transport.emitStdout(Self.initializeResponse)
        await fulfillment(of: [transport.rateLimitRequestExpectation], timeout: 1)
        transport.emitTermination(status: 9)

        await assertFailure(.processExited(9), from: task)
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
        transport.emitStdout(Self.initializeResponse)
        await fulfillment(of: [transport.rateLimitRequestExpectation], timeout: 1)
        transport.emitStdout(Self.rateLimitResponse)

        let snapshot = try await task.value
        XCTAssertEqual(snapshot.fiveHourQuotaPercent, 50)
        XCTAssertEqual(transport.shutdownCount, 1)
        XCTAssertEqual(timeoutScheduler.cancelCount, 1)
        XCTAssertEqual(
            transport.writtenMessages,
            [
                .request(
                    id: .integer(1),
                    method: "initialize",
                    params: .object([
                        "clientInfo": .object([
                            "name": .string("codex-monitor-native"),
                            "title": .string("Codex Monitor Native"),
                            "version": .string("0.2.0")
                        ])
                    ])
                ),
                .notification(method: "initialized", params: nil),
                .request(id: .integer(2), method: "account/rateLimits/read", params: nil)
            ]
        )
        let initializeRequest = try XCTUnwrap(transport.writtenMessages.first)
        guard case .request(_, _, let params) = initializeRequest,
              let params,
              case .object(let parameters) = params else {
            return XCTFail("Expected initialize request parameters")
        }
        XCTAssertNil(parameters["protocolVersion"])
        XCTAssertNil(parameters["capabilities"])
    }

    func testRPCClientUnusableResponseReclaimsTransportExactlyOnce() async {
        let transport = ControlledRPCTransport()
        let timeoutScheduler = ControlledTimeoutScheduler()
        let client = CodexRPCClient(transport: transport, timeoutScheduler: timeoutScheduler)
        let task = Task { try await client.fetchQuota(timeoutSeconds: 60) }

        await fulfillment(of: [transport.startedExpectation, transport.initializeRequestExpectation], timeout: 1)
        transport.emitStdout(Self.initializeResponse)
        await fulfillment(of: [transport.rateLimitRequestExpectation], timeout: 1)
        transport.emitStdout(Data("{\"id\":2,\"result\":{\"rateLimits\":{},\"rateLimitsByLimitId\":{}}}\n".utf8))

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

    func testRPCClientClassifiesMismatchedInitializeResponseIDAsIncompatible() async {
        let transport = ControlledRPCTransport()
        let client = CodexRPCClient(
            transport: transport,
            timeoutScheduler: ControlledTimeoutScheduler()
        )
        let task = Task { try await client.fetchQuota(timeoutSeconds: 60) }

        await fulfillment(of: [transport.startedExpectation], timeout: 1)
        transport.emitStdout(Data("{\"id\":99,\"result\":{}}\n".utf8))

        await assertFailure(.codexIncompatible, from: task)
        XCTAssertEqual(transport.shutdownCount, 1)
    }

    func testRPCClientClassifiesMalformedInitializeFrameAsIncompatibleWithoutWaitingForTimeout() async {
        let transport = ControlledRPCTransport()
        let timeoutScheduler = ControlledTimeoutScheduler()
        let client = CodexRPCClient(transport: transport, timeoutScheduler: timeoutScheduler)
        let task = Task { try await client.fetchQuota(timeoutSeconds: 60) }

        await fulfillment(of: [transport.startedExpectation], timeout: 1)
        transport.emitStdout(Data("not-json\n".utf8))

        await assertFailure(.codexIncompatible, from: task)
        XCTAssertEqual(timeoutScheduler.cancelCount, 1)
    }

    func testRPCClientClassifiesInvalidInitializePayloadAsIncompatible() async {
        let transport = ControlledRPCTransport()
        let client = CodexRPCClient(
            transport: transport,
            timeoutScheduler: ControlledTimeoutScheduler()
        )
        let task = Task { try await client.fetchQuota(timeoutSeconds: 60) }

        await fulfillment(of: [transport.initializeRequestExpectation], timeout: 1)
        transport.emitStdout(Data("{\"id\":1,\"result\":{\"protocolVersion\":1}}\n".utf8))

        await assertFailure(.codexIncompatible, from: task)
        XCTAssertEqual(transport.shutdownCount, 1)
    }

    func testRPCClientAcceptsInitializeResponseWithUnknownExtraFields() async throws {
        let transport = ControlledRPCTransport()
        let client = CodexRPCClient(
            transport: transport,
            timeoutScheduler: ControlledTimeoutScheduler()
        )
        let task = Task { try await client.fetchQuota(timeoutSeconds: 60) }

        await fulfillment(of: [transport.initializeRequestExpectation], timeout: 1)
        transport.emitStdout(Data("{\"id\":1,\"result\":{\"codexHome\":\"/tmp/codex\",\"platformFamily\":\"unix\",\"platformOs\":\"macos\",\"userAgent\":\"codex-test\",\"futureField\":true}}\n".utf8))
        await fulfillment(of: [transport.rateLimitRequestExpectation], timeout: 1)
        transport.emitStdout(Self.rateLimitResponse)

        _ = try await task.value
    }

    func testRPCClientIgnoresNotificationsWhileAwaitingMatchingResponse() async throws {
        let transport = ControlledRPCTransport()
        let client = CodexRPCClient(
            transport: transport,
            timeoutScheduler: ControlledTimeoutScheduler()
        )
        let task = Task { try await client.fetchQuota(timeoutSeconds: 60) }

        await fulfillment(of: [transport.initializeRequestExpectation], timeout: 1)
        let blankLines = Data("\n \t\r\n".utf8)
        let notification = Data("{\"method\":\"account/rateLimits/updated\",\"params\":{}}\n".utf8)
        transport.emitStdout(blankLines + notification + Self.initializeResponse)
        await fulfillment(of: [transport.rateLimitRequestExpectation], timeout: 1)
        transport.emitStdout(Self.rateLimitResponse)

        let snapshot = try await task.value
        XCTAssertEqual(snapshot.fiveHourQuotaPercent, 50)
    }

    func testRPCClientPreservesChunkOrderAndConsumesFinalFrameAtEOF() async throws {
        let transport = ControlledRPCTransport()
        let client = CodexRPCClient(
            transport: transport,
            timeoutScheduler: ControlledTimeoutScheduler()
        )
        let task = Task { try await client.fetchQuota(timeoutSeconds: 60) }

        await fulfillment(of: [transport.initializeRequestExpectation], timeout: 1)
        let initializeSplit = Self.initializeResponse.count / 2
        transport.emitStdout(Self.initializeResponse.subdata(in: 0..<initializeSplit))
        transport.emitStdout(Self.initializeResponse.subdata(in: initializeSplit..<Self.initializeResponse.count))
        await fulfillment(of: [transport.rateLimitRequestExpectation], timeout: 1)

        let responseWithoutNewline = Data(Self.rateLimitResponse.dropLast())
        let rateLimitSplit = responseWithoutNewline.count / 2
        transport.emitStdout(responseWithoutNewline.subdata(in: 0..<rateLimitSplit))
        transport.emitStdout(responseWithoutNewline.subdata(in: rateLimitSplit..<responseWithoutNewline.count))
        transport.emitStdoutEOF()

        let snapshot = try await task.value
        XCTAssertEqual(snapshot.fiveHourQuotaPercent, 50)
        XCTAssertEqual(transport.shutdownCount, 1)
    }

    func testRPCClientNormalizesRemoteErrorWithoutExposingRemoteMessage() async {
        let transport = ControlledRPCTransport()
        let client = CodexRPCClient(
            transport: transport,
            timeoutScheduler: ControlledTimeoutScheduler()
        )
        let task = Task { try await client.fetchQuota(timeoutSeconds: 60) }

        await fulfillment(of: [transport.initializeRequestExpectation], timeout: 1)
        transport.emitStdout(Data("{\"id\":1,\"error\":{\"code\":-32000,\"message\":\"Authentication token secret-value expired\"}}\n".utf8))

        let expected = RealQuotaError.rpcRejected(code: -32_000)
        await assertFailure(expected, from: task)
        XCTAssertFalse(expected.localizedDescription.contains("secret-value"))
    }

    func testRPCClientDoesNotInferAuthenticationStateFromRemoteMessage() async {
        let transport = ControlledRPCTransport()
        let client = CodexRPCClient(
            transport: transport,
            timeoutScheduler: ControlledTimeoutScheduler()
        )
        let task = Task { try await client.fetchQuota(timeoutSeconds: 60) }

        await fulfillment(of: [transport.initializeRequestExpectation], timeout: 1)
        transport.emitStdout(Data("{\"id\":1,\"error\":{\"code\":-32077,\"message\":\"Authorization denied; sign in again\"}}\n".utf8))

        await assertFailure(.rpcRejected(code: -32_077), from: task)
    }

    func testRPCClientClassifiesUnsupportedServerRequestAsIncompatibleAndRepliesMethodNotFound() async {
        let transport = ControlledRPCTransport()
        let client = CodexRPCClient(
            transport: transport,
            timeoutScheduler: ControlledTimeoutScheduler()
        )
        let task = Task { try await client.fetchQuota(timeoutSeconds: 60) }

        await fulfillment(of: [transport.initializeRequestExpectation], timeout: 1)
        transport.emitStdout(Data("{\"id\":\"server-1\",\"method\":\"attestation/generate\",\"params\":{}}\n".utf8))

        await assertFailure(.codexIncompatible, from: task)
        XCTAssertEqual(
            transport.writtenMessages.last,
            .error(
                id: .string("server-1"),
                error: CodexAppServerRemoteError(code: -32_601, message: "Method not found")
            )
        )
    }

    func testRPCClientClassifiesOversizedInitializeFrameAsIncompatible() async {
        let transport = ControlledRPCTransport()
        let client = CodexRPCClient(
            transport: transport,
            timeoutScheduler: ControlledTimeoutScheduler(),
            maxFrameBytes: 32
        )
        let task = Task { try await client.fetchQuota(timeoutSeconds: 60) }

        await fulfillment(of: [transport.startedExpectation], timeout: 1)
        transport.emitStdout(Data(repeating: 0x41, count: 33))

        await assertFailure(.codexIncompatible, from: task)
    }

    func testRPCClientTreatsInitializeWriteFailureAsSpawnFailure() async {
        let transport = ControlledRPCTransport(writeError: .writeFailed)
        let client = CodexRPCClient(
            transport: transport,
            timeoutScheduler: ControlledTimeoutScheduler()
        )

        let task = Task { try await client.fetchQuota(timeoutSeconds: 60) }

        await assertFailure(.spawnFailed, from: task)
        XCTAssertEqual(transport.shutdownCount, 1)
    }

    func testRPCClientTreatsRateLimitWriteFailureAsTransportFailure() async {
        let transport = ControlledRPCTransport(
            writeError: .writeFailed,
            writeErrorOnMethod: "account/rateLimits/read"
        )
        let client = CodexRPCClient(
            transport: transport,
            timeoutScheduler: ControlledTimeoutScheduler()
        )
        let task = Task { try await client.fetchQuota(timeoutSeconds: 60) }

        await fulfillment(of: [transport.initializeRequestExpectation], timeout: 1)
        transport.emitStdout(Self.initializeResponse)

        await assertFailure(.transportFailed, from: task)
        XCTAssertEqual(transport.shutdownCount, 1)
    }

    func testRPCClientClassifiesRealFastExitAsSpawnFailure() async {
        let client = CodexRPCClient(codexPath: "/usr/bin/false")

        await assertFailure(
            .spawnFailed,
            from: Task { try await client.fetchQuota(timeoutSeconds: 1) }
        )
    }

    func testRPCClientNormalizesStartFailure() async {
        let transport = ControlledRPCTransport(startError: .startFailed)
        let client = CodexRPCClient(
            transport: transport,
            timeoutScheduler: ControlledTimeoutScheduler()
        )

        let task = Task { try await client.fetchQuota(timeoutSeconds: 60) }

        await assertFailure(.spawnFailed, from: task)
        XCTAssertEqual(transport.shutdownCount, 1)
    }

    func testRPCClientClassifiesInitializeMethodNotFoundAsIncompatible() async {
        let transport = ControlledRPCTransport()
        let client = CodexRPCClient(
            transport: transport,
            timeoutScheduler: ControlledTimeoutScheduler()
        )
        let task = Task { try await client.fetchQuota(timeoutSeconds: 60) }

        await fulfillment(of: [transport.initializeRequestExpectation], timeout: 1)
        transport.emitStdout(Data("{\"id\":1,\"error\":{\"code\":-32601,\"message\":\"method missing\"}}\n".utf8))

        await assertFailure(.codexIncompatible, from: task)
    }

    func testRPCClientClassifiesInitializeInvalidParamsAsIncompatible() async {
        let transport = ControlledRPCTransport()
        let client = CodexRPCClient(
            transport: transport,
            timeoutScheduler: ControlledTimeoutScheduler()
        )
        let task = Task { try await client.fetchQuota(timeoutSeconds: 60) }

        await fulfillment(of: [transport.initializeRequestExpectation], timeout: 1)
        transport.emitStdout(Data("{\"id\":1,\"error\":{\"code\":-32602,\"message\":\"invalid params\"}}\n".utf8))

        await assertFailure(.codexIncompatible, from: task)
    }

    func testRPCClientClassifiesUnavailableRateLimitsMethodAsIncompatible() async {
        let transport = ControlledRPCTransport()
        let client = CodexRPCClient(
            transport: transport,
            timeoutScheduler: ControlledTimeoutScheduler()
        )
        let task = Task { try await client.fetchQuota(timeoutSeconds: 60) }

        await fulfillment(of: [transport.initializeRequestExpectation], timeout: 1)
        transport.emitStdout(Self.initializeResponse)
        await fulfillment(of: [transport.rateLimitRequestExpectation], timeout: 1)
        transport.emitStdout(Data("{\"id\":2,\"error\":{\"code\":-32601,\"message\":\"method missing\"}}\n".utf8))

        await assertFailure(.codexIncompatible, from: task)
    }

    func testRPCClientClassifiesRejectedRateLimitsParametersAsIncompatible() async {
        let transport = ControlledRPCTransport()
        let client = CodexRPCClient(
            transport: transport,
            timeoutScheduler: ControlledTimeoutScheduler()
        )
        let task = Task { try await client.fetchQuota(timeoutSeconds: 60) }

        await fulfillment(of: [transport.initializeRequestExpectation], timeout: 1)
        transport.emitStdout(Self.initializeResponse)
        await fulfillment(of: [transport.rateLimitRequestExpectation], timeout: 1)
        transport.emitStdout(Data("{\"id\":2,\"error\":{\"code\":-32602,\"message\":\"invalid params\"}}\n".utf8))

        await assertFailure(.codexIncompatible, from: task)
    }

    func testRPCClientUsesAccountReadToClassifyRateLimitsInvalidRequestAsLoginRequired() async {
        let transport = ControlledRPCTransport()
        let client = CodexRPCClient(
            transport: transport,
            timeoutScheduler: ControlledTimeoutScheduler()
        )
        let task = Task { try await client.fetchQuota(timeoutSeconds: 60) }

        await fulfillment(of: [transport.initializeRequestExpectation], timeout: 1)
        transport.emitStdout(Self.initializeResponse)
        await fulfillment(of: [transport.rateLimitRequestExpectation], timeout: 1)
        transport.emitStdout(Data("{\"id\":2,\"error\":{\"code\":-32600,\"message\":\"invalid request\"}}\n".utf8))
        await fulfillment(of: [transport.accountRequestExpectation], timeout: 1)
        transport.emitStdout(Data("{\"id\":3,\"result\":{\"account\":null,\"requiresOpenaiAuth\":true}}\n".utf8))

        await assertFailure(.authenticationRequired, from: task)
        XCTAssertEqual(
            transport.writtenMessages.last,
            .request(id: .integer(3), method: "account/read", params: .object([:]))
        )
    }

    func testRPCClientDistinguishesAuthenticatedNonChatGPTAccount() async {
        let transport = ControlledRPCTransport()
        let client = CodexRPCClient(
            transport: transport,
            timeoutScheduler: ControlledTimeoutScheduler()
        )
        let task = Task { try await client.fetchQuota(timeoutSeconds: 60) }

        await fulfillment(of: [transport.initializeRequestExpectation], timeout: 1)
        transport.emitStdout(Self.initializeResponse)
        await fulfillment(of: [transport.rateLimitRequestExpectation], timeout: 1)
        transport.emitStdout(Data("{\"id\":2,\"error\":{\"code\":-32600,\"message\":\"invalid request\"}}\n".utf8))
        await fulfillment(of: [transport.accountRequestExpectation], timeout: 1)
        transport.emitStdout(Data("{\"id\":3,\"result\":{\"account\":{\"type\":\"apiKey\"},\"requiresOpenaiAuth\":false}}\n".utf8))

        await assertFailure(.chatGPTAccountRequired, from: task)
    }

    func testRPCClientDoesNotCallNullAccountAuthenticatedWhenOpenAIAuthIsNotRequired() async {
        let transport = ControlledRPCTransport()
        let client = CodexRPCClient(
            transport: transport,
            timeoutScheduler: ControlledTimeoutScheduler()
        )
        let task = Task { try await client.fetchQuota(timeoutSeconds: 60) }

        await fulfillment(of: [transport.initializeRequestExpectation], timeout: 1)
        transport.emitStdout(Self.initializeResponse)
        await fulfillment(of: [transport.rateLimitRequestExpectation], timeout: 1)
        transport.emitStdout(Data("{\"id\":2,\"error\":{\"code\":-32600,\"message\":\"invalid request\"}}\n".utf8))
        await fulfillment(of: [transport.accountRequestExpectation], timeout: 1)
        transport.emitStdout(Data("{\"id\":3,\"result\":{\"account\":null,\"requiresOpenaiAuth\":false}}\n".utf8))

        await assertFailure(.rpcRejected(code: -32_600), from: task)
    }

    func testRPCClientUsesAccountReadToConfirmRateLimitsCapabilityMismatch() async {
        let transport = ControlledRPCTransport()
        let client = CodexRPCClient(
            transport: transport,
            timeoutScheduler: ControlledTimeoutScheduler()
        )
        let task = Task { try await client.fetchQuota(timeoutSeconds: 60) }

        await fulfillment(of: [transport.initializeRequestExpectation], timeout: 1)
        transport.emitStdout(Self.initializeResponse)
        await fulfillment(of: [transport.rateLimitRequestExpectation], timeout: 1)
        transport.emitStdout(Data("{\"id\":2,\"error\":{\"code\":-32600,\"message\":\"invalid request\"}}\n".utf8))
        await fulfillment(of: [transport.accountRequestExpectation], timeout: 1)
        transport.emitStdout(Data("{\"id\":3,\"result\":{\"account\":{\"type\":\"chatgpt\",\"email\":null,\"planType\":\"plus\"},\"requiresOpenaiAuth\":true}}\n".utf8))

        await assertFailure(.codexIncompatible, from: task)
    }

    func testRPCClientTreatsUnavailableAccountProbeAsIncompatible() async {
        let transport = ControlledRPCTransport()
        let client = CodexRPCClient(
            transport: transport,
            timeoutScheduler: ControlledTimeoutScheduler()
        )
        let task = Task { try await client.fetchQuota(timeoutSeconds: 60) }

        await fulfillment(of: [transport.initializeRequestExpectation], timeout: 1)
        transport.emitStdout(Self.initializeResponse)
        await fulfillment(of: [transport.rateLimitRequestExpectation], timeout: 1)
        transport.emitStdout(Data("{\"id\":2,\"error\":{\"code\":-32600,\"message\":\"invalid request\"}}\n".utf8))
        await fulfillment(of: [transport.accountRequestExpectation], timeout: 1)
        transport.emitStdout(Data("{\"id\":3,\"error\":{\"code\":-32600,\"message\":\"invalid request\"}}\n".utf8))

        await assertFailure(.codexIncompatible, from: task)
    }

    func testRPCClientBoundsStderrAndClassifiesCleanStartupExitConsistently() async {
        let transport = ControlledRPCTransport()
        let client = CodexRPCClient(
            transport: transport,
            timeoutScheduler: ControlledTimeoutScheduler(),
            maxStderrBytes: 8
        )
        let task = Task { try await client.fetchQuota(timeoutSeconds: 60) }

        await fulfillment(of: [transport.startedExpectation], timeout: 1)
        transport.emitStderr(Data("private-diagnostic-value".utf8))
        transport.emitTermination(status: 0)

        await assertFailure(.spawnFailed, from: task)
        XCTAssertFalse(RealQuotaError.spawnFailed.localizedDescription.contains("private-diagnostic-value"))
    }

    func testRPCClientPreservesRemoteFailureWhenCleanupAlsoFails() async {
        let transport = ControlledRPCTransport(cleanupError: .forceKillFailed)
        let client = CodexRPCClient(
            transport: transport,
            timeoutScheduler: ControlledTimeoutScheduler()
        )
        let task = Task { try await client.fetchQuota(timeoutSeconds: 60) }

        await fulfillment(of: [transport.initializeRequestExpectation], timeout: 1)
        transport.emitStdout(Data("{\"id\":1,\"error\":{\"code\":-32042,\"message\":\"rejected\"}}\n".utf8))

        await assertFailure(.rpcRejected(code: -32_042), from: task)
        XCTAssertEqual(transport.shutdownCount, 1)
    }

    func testRPCClientAcceptsDynamicBucketsWhenLegacyRateLimitsFieldIsMissing() async throws {
        let transport = ControlledRPCTransport()
        let client = CodexRPCClient(
            transport: transport,
            timeoutScheduler: ControlledTimeoutScheduler()
        )
        let task = Task { try await client.fetchQuota(timeoutSeconds: 60) }

        await fulfillment(of: [transport.initializeRequestExpectation], timeout: 1)
        transport.emitStdout(Self.initializeResponse)
        await fulfillment(of: [transport.rateLimitRequestExpectation], timeout: 1)
        transport.emitStdout(Data("{\"id\":2,\"result\":{\"rateLimitsByLimitId\":{\"codex\":{\"primary\":{\"windowDurationMins\":300,\"usedPercent\":50},\"secondary\":{\"windowDurationMins\":10080,\"usedPercent\":25}}}}}\n".utf8))

        let snapshot = try await task.value
        XCTAssertEqual(snapshot.fiveHourQuotaPercent, 50)
        XCTAssertEqual(snapshot.fiveHourQuotaState, .live)
        XCTAssertEqual(snapshot.weeklyQuotaPercent, 75)
        XCTAssertEqual(snapshot.weeklyQuotaState, .live)
    }

    func testRPCClientAcceptsRenamedTopLevelContainer() async throws {
        let transport = ControlledRPCTransport()
        let client = CodexRPCClient(
            transport: transport,
            timeoutScheduler: ControlledTimeoutScheduler()
        )
        let task = Task { try await client.fetchQuota(timeoutSeconds: 60) }

        await fulfillment(of: [transport.initializeRequestExpectation], timeout: 1)
        transport.emitStdout(Self.initializeResponse)
        await fulfillment(of: [transport.rateLimitRequestExpectation], timeout: 1)
        transport.emitStdout(Data("{\"id\":2,\"result\":{\"rate_limits_by_limit_id\":{\"codex_v2\":{\"weekly\":{\"duration_minutes\":10080,\"remaining_percent\":64}}}}}\n".utf8))

        let snapshot = try await task.value
        XCTAssertEqual(snapshot.weeklyQuotaPercent, 64)
        XCTAssertEqual(snapshot.weeklyQuotaState, .live)
        XCTAssertEqual(snapshot.fiveHourQuotaState, .unavailable)
    }

    func testRPCClientRejectsObjectWithoutSupportedRateLimitsContainer() async {
        let transport = ControlledRPCTransport()
        let client = CodexRPCClient(
            transport: transport,
            timeoutScheduler: ControlledTimeoutScheduler()
        )
        let task = Task { try await client.fetchQuota(timeoutSeconds: 60) }

        await fulfillment(of: [transport.initializeRequestExpectation], timeout: 1)
        transport.emitStdout(Self.initializeResponse)
        await fulfillment(of: [transport.rateLimitRequestExpectation], timeout: 1)
        transport.emitStdout(Data("{\"id\":2,\"result\":{\"futureField\":{}}}\n".utf8))

        await assertFailure(.responseInvalid, from: task)
    }

    func testRPCClientRejectsResponseWhenEveryQuotaWindowIsMalformed() async {
        let transport = ControlledRPCTransport()
        let client = CodexRPCClient(
            transport: transport,
            timeoutScheduler: ControlledTimeoutScheduler()
        )
        let task = Task { try await client.fetchQuota(timeoutSeconds: 60) }

        await fulfillment(of: [transport.initializeRequestExpectation], timeout: 1)
        transport.emitStdout(Self.initializeResponse)
        await fulfillment(of: [transport.rateLimitRequestExpectation], timeout: 1)
        transport.emitStdout(Data("{\"id\":2,\"result\":{\"rateLimits\":{},\"rateLimitsByLimitId\":{\"codex\":{\"primary\":{\"windowDurationMins\":300,\"usedPercent\":\"bad\"},\"secondary\":{\"windowDurationMins\":10080}}}}}\n".utf8))

        await assertFailure(.noUsableRateLimits, from: task)
    }

    func testRPCClientRejectsUnknownOnlyWindowAsNoUsableRateLimits() async {
        let transport = ControlledRPCTransport()
        let client = CodexRPCClient(
            transport: transport,
            timeoutScheduler: ControlledTimeoutScheduler()
        )
        let task = Task { try await client.fetchQuota(timeoutSeconds: 60) }

        await fulfillment(of: [transport.initializeRequestExpectation], timeout: 1)
        transport.emitStdout(Self.initializeResponse)
        await fulfillment(of: [transport.rateLimitRequestExpectation], timeout: 1)
        transport.emitStdout(Data("{\"id\":2,\"result\":{\"rateLimitsByLimitId\":{\"future_limit\":{\"future_window\":{\"windowDurationMins\":1234,\"usedPercent\":10}}}}}\n".utf8))

        await assertFailure(.noUsableRateLimits, from: task)
    }

    func testRPCClientAcceptsValidWindowWhenSiblingWindowIsMalformed() async throws {
        let transport = ControlledRPCTransport()
        let client = CodexRPCClient(
            transport: transport,
            timeoutScheduler: ControlledTimeoutScheduler()
        )
        let task = Task { try await client.fetchQuota(timeoutSeconds: 60) }

        await fulfillment(of: [transport.initializeRequestExpectation], timeout: 1)
        transport.emitStdout(Self.initializeResponse)
        await fulfillment(of: [transport.rateLimitRequestExpectation], timeout: 1)
        transport.emitStdout(Data("{\"id\":2,\"result\":{\"rateLimits\":{},\"rateLimitsByLimitId\":{\"codex\":{\"primary\":{\"windowDurationMins\":300,\"usedPercent\":\"bad\"},\"secondary\":{\"windowDurationMins\":10080,\"usedPercent\":35}}}}}\n".utf8))

        let snapshot = try await task.value
        XCTAssertEqual(snapshot.fiveHourQuotaPercent, 0)
        XCTAssertEqual(snapshot.fiveHourQuotaState, .invalid)
        XCTAssertEqual(snapshot.weeklyQuotaPercent, 65)
        XCTAssertEqual(snapshot.weeklyQuotaState, .live)
    }

    func testRPCClientMapsRequiredLegacyRateLimitsWhenDynamicBucketsAreNull() async throws {
        let transport = ControlledRPCTransport()
        let client = CodexRPCClient(
            transport: transport,
            timeoutScheduler: ControlledTimeoutScheduler()
        )
        let task = Task { try await client.fetchQuota(timeoutSeconds: 60) }

        await fulfillment(of: [transport.initializeRequestExpectation], timeout: 1)
        transport.emitStdout(Self.initializeResponse)
        await fulfillment(of: [transport.rateLimitRequestExpectation], timeout: 1)
        transport.emitStdout(Data("{\"id\":2,\"result\":{\"rateLimits\":{\"primary\":{\"windowDurationMins\":300,\"usedPercent\":40},\"secondary\":{\"windowDurationMins\":10080,\"usedPercent\":20}},\"rateLimitsByLimitId\":null}}\n".utf8))

        let snapshot = try await task.value
        XCTAssertEqual(snapshot.fiveHourQuotaPercent, 60)
        XCTAssertEqual(snapshot.weeklyQuotaPercent, 80)
    }

    func testProviderDistinguishesMissingAndNonRunnableExecutables() async {
        let missingFileSystem = MutableResolverFileSystem()
        let missingProvider = makeProvider(
            environment: ["PATH": "/missing/bin"],
            fileSystem: missingFileSystem,
            fetcher: ControlledExecutableQuotaFetcher(outcomes: [:])
        )
        await assertFailure(.codexNotFound, from: Task { try await missingProvider.fetchQuota() })

        let nonRunnablePath = "/custom/codex"
        let nonRunnableFileSystem = MutableResolverFileSystem(items: [
            nonRunnablePath: .regularFile(executable: false)
        ])
        let nonRunnableProvider = makeProvider(
            environment: ["CODEX_BIN": nonRunnablePath],
            fileSystem: nonRunnableFileSystem,
            fetcher: ControlledExecutableQuotaFetcher(outcomes: [:])
        )
        await assertFailure(.codexNotExecutable, from: Task { try await nonRunnableProvider.fetchQuota() })
    }

    func testProviderFallsBackAcrossStartupAndCompatibilityFailures() async throws {
        let firstPath = "/first/bin/codex"
        let secondPath = "/second/bin/codex"
        let thirdPath = "/third/bin/codex"
        let expected = QuotaSnapshot(
            weeklyQuotaPercent: 64,
            fiveHourQuotaPercent: 38,
            refreshedAt: .now,
            dataSource: .real
        )
        let fileSystem = MutableResolverFileSystem(items: [
            firstPath: .regularFile(executable: true),
            secondPath: .regularFile(executable: true),
            thirdPath: .regularFile(executable: true)
        ])
        let fetcher = ControlledExecutableQuotaFetcher(outcomes: [
            firstPath: [.failure(.spawnFailed)],
            secondPath: [.failure(.codexIncompatible)],
            thirdPath: [.success(expected)]
        ])
        let provider = makeProvider(
            environment: ["PATH": "/first/bin:/second/bin:/third/bin"],
            fileSystem: fileSystem,
            fetcher: fetcher
        )

        let snapshot = try await provider.fetchQuota()
        XCTAssertEqual(snapshot, expected)
        XCTAssertEqual(fetcher.requestedPaths, [firstPath, secondPath, thirdPath])
    }

    func testProviderDoesNotFallbackForOperationalRPCFailure() async {
        let firstPath = "/first/bin/codex"
        let secondPath = "/second/bin/codex"
        let expected = QuotaSnapshot(
            weeklyQuotaPercent: 64,
            fiveHourQuotaPercent: 38,
            refreshedAt: .now,
            dataSource: .real
        )
        let fileSystem = MutableResolverFileSystem(items: [
            firstPath: .regularFile(executable: true),
            secondPath: .regularFile(executable: true)
        ])
        let fetcher = ControlledExecutableQuotaFetcher(outcomes: [
            firstPath: [.failure(.rpcRejected(code: -32_000))],
            secondPath: [.success(expected)]
        ])
        let provider = makeProvider(
            environment: ["PATH": "/first/bin:/second/bin"],
            fileSystem: fileSystem,
            fetcher: fetcher
        )

        await assertFailure(.rpcRejected(code: -32_000), from: Task { try await provider.fetchQuota() })
        XCTAssertEqual(fetcher.requestedPaths, [firstPath])
    }

    func testProviderReresolvesCandidatesAfterExecutableMoves() async throws {
        let oldPath = "/node/v1/bin/codex"
        let newPath = "/node/v2/bin/codex"
        let snapshot = QuotaSnapshot(
            weeklyQuotaPercent: 64,
            fiveHourQuotaPercent: 38,
            refreshedAt: .now,
            dataSource: .real
        )
        let fileSystem = MutableResolverFileSystem(items: [
            oldPath: .regularFile(executable: true),
            newPath: .missing
        ])
        let fetcher = ControlledExecutableQuotaFetcher(outcomes: [
            oldPath: [.success(snapshot)],
            newPath: [.success(snapshot)]
        ])
        let provider = makeProvider(
            environment: ["PATH": "/node/v1/bin:/node/v2/bin"],
            fileSystem: fileSystem,
            fetcher: fetcher
        )

        _ = try await provider.fetchQuota()
        fileSystem.setItem(.missing, at: oldPath)
        fileSystem.setItem(.regularFile(executable: true), at: newPath)
        _ = try await provider.fetchQuota()

        XCTAssertEqual(fetcher.requestedPaths, [oldPath, newPath])
    }

    func testProviderReportsCompatibilityWhenNoFallbackCandidateWorks() async {
        let firstPath = "/first/bin/codex"
        let secondPath = "/second/bin/codex"
        let fileSystem = MutableResolverFileSystem(items: [
            firstPath: .regularFile(executable: true),
            secondPath: .regularFile(executable: true)
        ])
        let fetcher = ControlledExecutableQuotaFetcher(outcomes: [
            firstPath: [.failure(.codexIncompatible)],
            secondPath: [.failure(.spawnFailed)]
        ])
        let provider = makeProvider(
            environment: ["PATH": "/first/bin:/second/bin"],
            fileSystem: fileSystem,
            fetcher: fetcher
        )

        await assertFailure(.codexIncompatible, from: Task { try await provider.fetchQuota() })
        XCTAssertEqual(fetcher.requestedPaths, [firstPath, secondPath])
    }

    private func makeProvider(
        environment: [String: String],
        fileSystem: MutableResolverFileSystem,
        fetcher: ControlledExecutableQuotaFetcher
    ) -> RealQuotaProvider {
        let resolver = CodexExecutableResolver(
            environment: { environment },
            homeDirectory: { "/Users/test" },
            fileSystem: fileSystem.interface
        )
        return RealQuotaProvider(
            executableResolver: resolver,
            fetchQuotaFromExecutable: { path, timeoutSeconds in
                try fetcher.fetch(path: path, timeoutSeconds: timeoutSeconds)
            }
        )
    }

    private static let initializeResponse = Data("{\"id\":1,\"result\":{\"codexHome\":\"/tmp/codex\",\"platformFamily\":\"unix\",\"platformOs\":\"macos\",\"userAgent\":\"codex-test\"}}\n".utf8)
    private static let rateLimitResponse = Data("{\"id\":2,\"result\":{\"rateLimits\":{},\"rateLimitsByLimitId\":{\"codex\":{\"primary\":{\"windowDurationMins\":300,\"usedPercent\":50}}}}}\n".utf8)

    private func assertFailure(
        _ expected: RealQuotaError,
        from task: Task<QuotaSnapshot, Error>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await task.value
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch let error as RealQuotaError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("Expected \(expected), got \(error)", file: file, line: line)
        }
    }

    func testParseRateLimitsUsesLegacySnapshotWhenDynamicBucketsAreAbsent() throws {
        let response: [String: Any] = [
            "rateLimits": [
                "primary": [
                    "windowDurationMins": 300,
                    "usedPercent": 40
                ],
                "secondary": [
                    "windowDurationMins": 10_080,
                    "usedPercent": 20
                ]
            ]
        ]

        let snapshot = try XCTUnwrap(RealQuotaProvider.parseRateLimits(response: response))

        XCTAssertEqual(snapshot.fiveHourQuotaPercent, 60)
        XCTAssertEqual(snapshot.weeklyQuotaPercent, 80)
        XCTAssertEqual(snapshot.quotaWindows.map(\.id), ["codex.primary", "codex.secondary"])
    }

    func testParseRateLimitsTreatsDynamicCodexBucketAsAuthoritativeOverLegacyMirror() throws {
        let response: [String: Any] = [
            "rateLimits": [
                "primary": ["windowDurationMins": 300, "usedPercent": 10],
                "secondary": ["windowDurationMins": 10_080, "usedPercent": 20]
            ],
            "rateLimitsByLimitId": [
                "codex": [
                    "primary": ["windowDurationMins": 300, "usedPercent": 40],
                    "secondary": ["windowDurationMins": 10_080, "usedPercent": 50]
                ]
            ]
        ]

        let snapshot = try XCTUnwrap(RealQuotaProvider.parseRateLimits(response: response))

        XCTAssertEqual(snapshot.fiveHourQuotaPercent, 60)
        XCTAssertEqual(snapshot.weeklyQuotaPercent, 50)
        XCTAssertEqual(snapshot.quotaWindows.map(\.id), ["codex.primary", "codex.secondary"])
    }

    func testParseRateLimitsDeepMergesComplementaryContainerAliases() throws {
        let response: [String: Any] = [
            "rateLimitsByLimitId": [
                "codex": [
                    "primary": ["windowDurationMins": 300, "usedPercent": 20]
                ]
            ],
            "rate_limits_by_limit_id": [
                "codex": [
                    "secondary": ["windowDurationMins": 10_080, "usedPercent": 35]
                ]
            ]
        ]

        let snapshot = try XCTUnwrap(RealQuotaProvider.parseRateLimits(response: response))

        XCTAssertEqual(snapshot.fiveHourQuotaPercent, 80)
        XCTAssertEqual(snapshot.weeklyQuotaPercent, 65)
        XCTAssertEqual(snapshot.quotaWindows.map(\.id), ["codex.primary", "codex.secondary"])
    }

    func testParseRateLimitsMarksConflictingContainerAliasesInvalid() throws {
        let response: [String: Any] = [
            "rateLimitsByLimitId": [
                "codex": [
                    "primary": ["windowDurationMins": 300, "usedPercent": 20]
                ]
            ],
            "rate_limits_by_limit_id": [
                "codex": [
                    "primary": ["windowDurationMins": 300, "usedPercent": 30],
                    "secondary": ["windowDurationMins": 10_080, "usedPercent": 35]
                ]
            ]
        ]

        let snapshot = try XCTUnwrap(RealQuotaProvider.parseRateLimits(response: response))

        XCTAssertEqual(snapshot.fiveHourQuotaPercent, 0)
        XCTAssertEqual(snapshot.fiveHourQuotaState, .invalid)
        XCTAssertEqual(snapshot.weeklyQuotaPercent, 65)
        XCTAssertEqual(snapshot.weeklyQuotaState, .live)
    }

    func testParseRateLimitsNeverTreatsBooleanAndNumericAliasesAsEqual() throws {
        let response: [String: Any] = [
            "rateLimitsByLimitId": [
                "codex": [
                    "primary": ["windowDurationMins": 300, "usedPercent": 1]
                ]
            ],
            "rate_limits_by_limit_id": [
                "codex": [
                    "primary": ["windowDurationMins": 300, "usedPercent": true],
                    "secondary": ["windowDurationMins": 10_080, "usedPercent": 35]
                ]
            ]
        ]

        let snapshot = try XCTUnwrap(RealQuotaProvider.parseRateLimits(response: response))

        XCTAssertEqual(snapshot.fiveHourQuotaPercent, 0)
        XCTAssertEqual(snapshot.fiveHourQuotaState, .invalid)
        XCTAssertEqual(snapshot.weeklyQuotaPercent, 65)
        XCTAssertEqual(snapshot.weeklyQuotaState, .live)
    }

    func testParseRateLimitsIgnoresAddedTopLevelAndSnapshotMetadataFields() throws {
        let response: [String: Any] = [
            "futureTopLevelField": ["opaque": 99],
            "rateLimitsByLimitId": [
                "codex": [
                    "credits": ["hasCredits": true, "unlimited": false],
                    "individualLimit": ["remainingPercent": 17],
                    "newMetadata": ["opaque": 88],
                    "primary": [
                        "windowDurationMins": 300,
                        "usedPercent": 20,
                        "futureWindowField": "ignored"
                    ]
                ]
            ]
        ]

        let snapshot = try XCTUnwrap(RealQuotaProvider.parseRateLimits(response: response))

        XCTAssertEqual(snapshot.fiveHourQuotaPercent, 80)
        XCTAssertEqual(snapshot.fiveHourQuotaState, .live)
        XCTAssertEqual(snapshot.quotaWindows.map(\.id), ["codex.primary"])
    }

    func testParseRateLimitsSupportsRenamedContainersFieldsAndWindowIDs() throws {
        let response: [String: Any] = [
            "rate_limit_reset_credits": ["available_count": "3"],
            "rate_limits_by_limit_id": [
                "codex_v2": [
                    "short_term": [
                        "window_duration_mins": "300",
                        "used_percent": "20",
                        "reset_at": "2026-06-19T14:10:00Z"
                    ],
                    "long_term": [
                        "duration_minutes": 10_080,
                        "remaining_percent": 65
                    ],
                    "future": [
                        "window_duration_minutes": 1_234,
                        "remainingPercent": 42
                    ]
                ]
            ]
        ]

        let snapshot = try XCTUnwrap(RealQuotaProvider.parseRateLimits(response: response))

        XCTAssertEqual(snapshot.fiveHourQuotaPercent, 80)
        XCTAssertEqual(snapshot.fiveHourQuotaState, .live)
        XCTAssertEqual(snapshot.weeklyQuotaPercent, 65)
        XCTAssertEqual(snapshot.weeklyQuotaState, .live)
        XCTAssertEqual(snapshot.resetAvailableCount, 3)
        XCTAssertNotNil(snapshot.fiveHourResetAt)
        XCTAssertEqual(
            snapshot.quotaWindows.first(where: { $0.windowId == "future" })?.kind,
            .unknown
        )
        XCTAssertEqual(
            snapshot.quotaWindows.first(where: { $0.windowId == "future" })?.remainingPercent,
            42
        )
    }

    func testParseRateLimitsMarksMissingPercentageInvalidWithoutSynthesizingQuota() throws {
        let response: [String: Any] = [
            "rateLimitsByLimitId": [
                "codex": [
                    "primary": ["windowDurationMins": 300],
                    "secondary": ["windowDurationMins": 10_080, "usedPercent": 35]
                ]
            ]
        ]

        let snapshot = try XCTUnwrap(RealQuotaProvider.parseRateLimits(response: response))

        XCTAssertEqual(snapshot.fiveHourQuotaPercent, 0)
        XCTAssertEqual(snapshot.fiveHourQuotaState, .invalid)
        XCTAssertEqual(snapshot.weeklyQuotaPercent, 65)
        XCTAssertEqual(snapshot.weeklyQuotaState, .live)
        XCTAssertNotEqual(snapshot.fiveHourQuotaPercent, 100)
    }

    func testParseRateLimitsRejectsConflictingAliasesAndDoesNotGuessDuration() throws {
        let response: [String: Any] = [
            "rateLimitsByLimitId": [
                "codex": [
                    "primary": [
                        "windowDurationMins": 300,
                        "usedPercent": 20,
                        "remainingPercent": 20
                    ],
                    "secondary": ["windowDurationMins": 10_080, "usedPercent": 35],
                    "conflictingDuration": [
                        "windowDurationMins": 300,
                        "durationMinutes": 10_080,
                        "usedPercent": 10
                    ]
                ]
            ]
        ]

        let snapshot = try XCTUnwrap(RealQuotaProvider.parseRateLimits(response: response))

        XCTAssertEqual(snapshot.fiveHourQuotaPercent, 0)
        XCTAssertEqual(snapshot.fiveHourQuotaState, .invalid)
        XCTAssertEqual(snapshot.weeklyQuotaPercent, 65)
        XCTAssertEqual(snapshot.weeklyQuotaState, .live)
        XCTAssertEqual(
            snapshot.quotaWindows.first(where: { $0.windowId == "conflictingDuration" })?.kind,
            .unknown
        )
    }

    func testParseRateLimitsDoesNotApplyLegacyMappingToConflictingCanonicalDurations() throws {
        let response: [String: Any] = [
            "rateLimitsByLimitId": [
                "codex": [
                    "primary": [
                        "windowDurationMins": 300,
                        "durationMinutes": 10_080,
                        "usedPercent": 20
                    ],
                    "secondary": [
                        "windowDurationMins": 10_080,
                        "durationMinutes": 300,
                        "usedPercent": 35
                    ]
                ]
            ]
        ]

        let snapshot = try XCTUnwrap(RealQuotaProvider.parseRateLimits(response: response))

        XCTAssertEqual(snapshot.fiveHourQuotaState, .unavailable)
        XCTAssertEqual(snapshot.weeklyQuotaState, .unavailable)
        XCTAssertEqual(snapshot.quotaWindows.map(\.kind), [.unknown, .unknown])
        XCTAssertTrue(snapshot.quotaWindows.allSatisfy { $0.state == .live })
    }

    func testParseRateLimitsSafelyRejectsOutOfRangeIntegerMetadata() throws {
        let response: [String: Any] = [
            "rateLimitResetCredits": ["availableCount": Double.greatestFiniteMagnitude],
            "rateLimitsByLimitId": [
                "codex": [
                    "primary": [
                        "windowDurationMins": Double.greatestFiniteMagnitude,
                        "usedPercent": 20
                    ],
                    "secondary": ["windowDurationMins": 10_080, "usedPercent": 35]
                ]
            ]
        ]

        let snapshot = try XCTUnwrap(RealQuotaProvider.parseRateLimits(response: response))

        XCTAssertNil(snapshot.resetAvailableCount)
        XCTAssertEqual(
            snapshot.quotaWindows.first(where: { $0.windowId == "primary" })?.kind,
            .unknown
        )
        XCTAssertEqual(snapshot.fiveHourQuotaState, .unavailable)
        XCTAssertEqual(snapshot.weeklyQuotaPercent, 65)
    }

    func testParseRateLimitsPreservesIntegerMetadataBeyondDoublePrecision() throws {
        let exactInteger = Int64(9_007_199_254_740_993)
        let response: [String: Any] = [
            "rateLimitResetCredits": ["availableCount": NSNumber(value: exactInteger)],
            "rateLimitsByLimitId": [
                "codex": [
                    "primary": [
                        "windowDurationMins": NSNumber(value: exactInteger),
                        "usedPercent": 20
                    ],
                    "secondary": ["windowDurationMins": 10_080, "usedPercent": 35]
                ]
            ]
        ]

        let snapshot = try XCTUnwrap(RealQuotaProvider.parseRateLimits(response: response))

        XCTAssertEqual(snapshot.resetAvailableCount, Int(exactInteger))
        XCTAssertEqual(
            snapshot.quotaWindows.first(where: { $0.windowId == "primary" })?.durationMinutes,
            Int(exactInteger)
        )
        XCTAssertEqual(snapshot.weeklyQuotaPercent, 65)
    }

    func testParseRateLimitsPreservesUnknownOnlyWindowWithoutPromotingCoreQuota() throws {
        let response: [String: Any] = [
            "rateLimitsByLimitId": [
                "future_limit": [
                    "future_window": [
                        "windowDurationMins": 1_234,
                        "usedPercent": 10
                    ]
                ]
            ]
        ]

        let snapshot = try XCTUnwrap(RealQuotaProvider.parseRateLimits(response: response))

        XCTAssertEqual(snapshot.weeklyQuotaPercent, 0)
        XCTAssertEqual(snapshot.weeklyQuotaState, .unavailable)
        XCTAssertEqual(snapshot.fiveHourQuotaPercent, 0)
        XCTAssertEqual(snapshot.fiveHourQuotaState, .unavailable)
        XCTAssertEqual(snapshot.quotaWindows.count, 1)
        XCTAssertEqual(snapshot.quotaWindows[0].kind, .unknown)
        XCTAssertEqual(snapshot.quotaWindows[0].remainingPercent, 90)
        XCTAssertEqual(snapshot.quotaWindows[0].state, .live)
    }

    func testParseRateLimitsNeverCoercesJSONBooleansIntoNumericFields() throws {
        let response: [String: Any] = [
            "rateLimitResetCredits": [
                "availableCount": true
            ],
            "rateLimitsByLimitId": [
                "codex": [
                    "primary": [
                        "windowDurationMins": 300,
                        "usedPercent": true,
                        "resetAt": true
                    ]
                ],
                "bonus": [
                    "primary": [
                        "windowDurationMins": 60,
                        "usedPercent": 10,
                        "resetAt": true
                    ]
                ]
            ]
        ]

        let snapshot = try XCTUnwrap(RealQuotaProvider.parseRateLimits(response: response))

        XCTAssertEqual(snapshot.fiveHourQuotaState, .invalid)
        XCTAssertEqual(snapshot.fiveHourQuotaPercent, 0)
        XCTAssertNil(snapshot.resetAvailableCount)
        XCTAssertNil(snapshot.fiveHourResetAt)
        XCTAssertEqual(snapshot.resetBanks.first?.resetTimeStatus, .parseFailed)
    }
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
                        "windowDurationMins": 10080,
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
        XCTAssertEqual(snapshot?.resetBanks.first?.resetTimeStatus, .actual)
        XCTAssertNotNil(snapshot?.resetBanks.first?.resetAt)
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
                        "windowDurationMins": 10080,
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

    func testParseRateLimitsRetainsLegacyFallbackPairWithoutDurations() {
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

        XCTAssertEqual(snapshot?.fiveHourQuotaPercent, 43)
        XCTAssertEqual(snapshot?.fiveHourQuotaState, .live)
        XCTAssertEqual(snapshot?.weeklyQuotaPercent, 75)
        XCTAssertEqual(snapshot?.weeklyQuotaState, .live)
        XCTAssertEqual(snapshot?.quotaWindows.first(where: { $0.id == "codex.primary" })?.kind, .fiveHour)
        XCTAssertEqual(snapshot?.quotaWindows.first(where: { $0.id == "codex_other.primary" })?.kind, .weekly)
    }

    func testParseRateLimitsMarksUnexposedWeeklyWindowInsteadOfDefaultingTo100() {
        let response: [String: Any] = [
            "rateLimitsByLimitId": [
                "codex": [
                    "primary": ["usedPercent": 57.0]
                ]
            ]
        ]

        let snapshot = RealQuotaProvider.parseRateLimits(response: response)

        XCTAssertEqual(snapshot?.fiveHourQuotaState, .unavailable)
        XCTAssertEqual(snapshot?.quotaWindows.first?.kind, .unknown)
        XCTAssertEqual(snapshot?.weeklyQuotaState, .unavailable)
        XCTAssertNotEqual(snapshot?.weeklyQuotaPercent, 100)
    }

    func testParseRateLimitsKeepsWeeklyWhenPrimaryWindowIsUnexposed() {
        let response: [String: Any] = [
            "rateLimitsByLimitId": [
                "codex": [
                    "secondary": ["windowDurationMins": 10080, "usedPercent": 42.0]
                ]
            ]
        ]

        let snapshot = RealQuotaProvider.parseRateLimits(response: response)

        XCTAssertEqual(snapshot?.weeklyQuotaPercent, 58)
        XCTAssertEqual(snapshot?.weeklyQuotaState, .live)
        XCTAssertEqual(snapshot?.fiveHourQuotaState, .unavailable)
        XCTAssertNotEqual(snapshot?.fiveHourQuotaPercent, 100)
    }

    func testParseRateLimitsMarksInvalidFieldsWithoutSynthesizing100() {
        let response: [String: Any] = [
            "rateLimitsByLimitId": [
                "codex": [
                    "primary": ["usedPercent": 101.0],
                    "secondary": ["usedPercent": "not-a-number"]
                ]
            ]
        ]

        let snapshot = RealQuotaProvider.parseRateLimits(response: response)

        XCTAssertEqual(snapshot?.fiveHourQuotaState, .invalid)
        XCTAssertEqual(snapshot?.weeklyQuotaState, .invalid)
        XCTAssertNotEqual(snapshot?.fiveHourQuotaPercent, 100)
        XCTAssertNotEqual(snapshot?.weeklyQuotaPercent, 100)
    }

    func testParseRateLimitsUsesFallbackWhenCanonicalWeeklyFieldIsInvalid() {
        let response: [String: Any] = [
            "rateLimitsByLimitId": [
                "codex": [
                    "primary": ["usedPercent": 30.0],
                    "secondary": ["usedPercent": 101.0]
                ],
                "codex_other": [
                    "primary": ["usedPercent": 25.0]
                ]
            ]
        ]

        let snapshot = RealQuotaProvider.parseRateLimits(response: response)

        XCTAssertEqual(snapshot?.weeklyQuotaPercent, 75)
        XCTAssertEqual(snapshot?.weeklyQuotaState, .live)
    }

    func testPartialQuotaMergesLiveFieldAndMarksCachedField() {
        let cached = QuotaSnapshot(
            weeklyQuotaPercent: 70,
            fiveHourQuotaPercent: 60,
            refreshedAt: Date(timeIntervalSince1970: 100),
            dataSource: .real
        )
        let partial = QuotaSnapshot(
            weeklyQuotaPercent: 0,
            fiveHourQuotaPercent: 82,
            weeklyQuotaState: .unavailable,
            fiveHourQuotaState: .live,
            refreshedAt: Date(timeIntervalSince1970: 200),
            dataSource: .real
        )

        let merged = partial.mergingPartial(with: cached)

        XCTAssertEqual(merged.weeklyQuotaPercent, 70)
        XCTAssertEqual(merged.weeklyQuotaState, .cached)
        XCTAssertEqual(merged.fiveHourQuotaPercent, 82)
        XCTAssertEqual(merged.fiveHourQuotaState, .live)
    }

    func testParseRateLimitsMapsUnknownResetMetadataToSemanticStatuses() {
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
        let statuses = Dictionary(
            uniqueKeysWithValues: (snapshot?.resetBanks ?? []).map { ($0.windowId, $0.resetTimeStatus) }
        )
        XCTAssertEqual(statuses["primary"], .unexposed)
        XCTAssertEqual(statuses["secondary"], .parseFailed)
    }

    func testParseRateLimitsClassifiesNewDurationWindowsAndPreservesUnknown() {
        let response: [String: Any] = [
            "rateLimitsByLimitId": [
                "codex": [
                    "primary": ["windowDurationMins": 300, "usedPercent": 20.0],
                    "secondary": ["windowDurationMins": 10080, "usedPercent": 40.0],
                    "monthly": ["windowDurationMins": 43200, "usedPercent": 50.0],
                    "future": ["windowDurationMins": 1234, "usedPercent": 10.0]
                ]
            ]
        ]

        let snapshot = RealQuotaProvider.parseRateLimits(response: response)

        XCTAssertEqual(snapshot?.fiveHourQuotaPercent, 80)
        XCTAssertEqual(snapshot?.weeklyQuotaPercent, 60)
        XCTAssertEqual(snapshot?.quotaWindows.first(where: { $0.windowId == "monthly" })?.kind, .monthly)
        XCTAssertEqual(snapshot?.quotaWindows.first(where: { $0.windowId == "future" })?.kind, .unknown)
        XCTAssertEqual(snapshot?.quotaWindows.first(where: { $0.windowId == "future" })?.remainingPercent, 90)
    }

    func testParseRateLimitsDoesNotGuessAmbiguousSinglePrimaryWithoutDuration() {
        let response: [String: Any] = [
            "rateLimitsByLimitId": [
                "codex": ["primary": ["usedPercent": 20.0]]
            ]
        ]

        let snapshot = RealQuotaProvider.parseRateLimits(response: response)

        XCTAssertEqual(snapshot?.fiveHourQuotaState, .unavailable)
        XCTAssertNotEqual(snapshot?.fiveHourQuotaPercent, 100)
        XCTAssertEqual(snapshot?.quotaWindows.first?.kind, .unknown)
        XCTAssertEqual(snapshot?.quotaWindows.first?.state, .live)
    }

    func testParseRateLimitsMissingFiveHourKeepsDurationBackedWeeklyWindow() {
        let response: [String: Any] = [
            "rateLimitsByLimitId": [
                "codex": ["secondary": ["windowDurationMins": 10080, "usedPercent": 42.0]]
            ]
        ]

        let snapshot = RealQuotaProvider.parseRateLimits(response: response)

        XCTAssertEqual(snapshot?.weeklyQuotaPercent, 58)
        XCTAssertEqual(snapshot?.weeklyQuotaState, .live)
        XCTAssertEqual(snapshot?.fiveHourQuotaState, .unavailable)
        XCTAssertNotEqual(snapshot?.fiveHourQuotaPercent, 100)
    }

    func testOldDualWindowWithoutDurationsRetainsLegacyMapping() {
        let response: [String: Any] = [
            "rateLimitsByLimitId": [
                "codex": [
                    "primary": ["usedPercent": 30.0],
                    "secondary": ["usedPercent": 40.0]
                ]
            ]
        ]

        let snapshot = RealQuotaProvider.parseRateLimits(response: response)

        XCTAssertEqual(snapshot?.quotaWindows.first(where: { $0.windowId == "primary" })?.kind, .fiveHour)
        XCTAssertEqual(snapshot?.quotaWindows.first(where: { $0.windowId == "secondary" })?.kind, .weekly)
        XCTAssertEqual(snapshot?.fiveHourQuotaPercent, 70)
        XCTAssertEqual(snapshot?.weeklyQuotaPercent, 60)
    }

    func testPartialQuotaMergesDynamicWindowsBySemanticIdentity() {
        let cached = QuotaSnapshot(
            weeklyQuotaPercent: 60,
            fiveHourQuotaPercent: 80,
            refreshedAt: Date(timeIntervalSince1970: 100),
            dataSource: .real,
            quotaWindows: [
                QuotaWindow(limitId: "codex", windowId: "secondary", kind: .weekly, durationMinutes: 10080, remainingPercent: 60),
                QuotaWindow(limitId: "codex", windowId: "primary", kind: .fiveHour, durationMinutes: 300, remainingPercent: 80)
            ]
        )
        let partial = QuotaSnapshot(
            weeklyQuotaPercent: 0,
            fiveHourQuotaPercent: 0,
            weeklyQuotaState: .unavailable,
            fiveHourQuotaState: .unavailable,
            refreshedAt: Date(timeIntervalSince1970: 200),
            dataSource: .real,
            quotaWindows: [
                QuotaWindow(limitId: "codex_other", windowId: "primary", kind: .weekly, durationMinutes: nil, remainingPercent: 0, state: .unavailable)
            ]
        )

        let merged = partial.mergingPartial(with: cached)

        XCTAssertEqual(merged.weeklyQuotaPercent, 60)
        XCTAssertEqual(merged.weeklyQuotaState, .cached)
        XCTAssertEqual(merged.quotaWindows.first(where: { $0.kind == .weekly })?.state, .cached)
        XCTAssertEqual(merged.quotaWindows.first(where: { $0.kind == .weekly })?.remainingPercent, 60)
    }

    func testQuotaSnapshotCodableDefaultsMissingDynamicWindowsForLegacyPayload() throws {
        let payload = """
        {
          "weeklyQuotaPercent": 72,
          "fiveHourQuotaPercent": 61,
          "refreshedAt": 100,
          "dataSource": "real",
          "schemaVersion": 7
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let snapshot = try decoder.decode(QuotaSnapshot.self, from: payload)

        XCTAssertEqual(snapshot.weeklyQuotaPercent, 72)
        XCTAssertEqual(snapshot.fiveHourQuotaPercent, 61)
        XCTAssertTrue(snapshot.quotaWindows.isEmpty)
    }

    func testQuotaSnapshotCodableRoundTripsDynamicWindows() throws {
        let snapshot = QuotaSnapshot(
            weeklyQuotaPercent: 60,
            fiveHourQuotaPercent: 80,
            refreshedAt: Date(timeIntervalSince1970: 100),
            dataSource: .real,
            quotaWindows: [
                QuotaWindow(limitId: "codex", windowId: "monthly", kind: .monthly, durationMinutes: 43200, remainingPercent: 60),
                QuotaWindow(limitId: "codex", windowId: "future", kind: .unknown, durationMinutes: 1234, remainingPercent: 80)
            ]
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let decoded = try decoder.decode(QuotaSnapshot.self, from: encoder.encode(snapshot))

        XCTAssertEqual(decoded.quotaWindows, snapshot.quotaWindows)
    }

    func testResetBankDecodesLegacyRawFieldsIntoSemanticStatusWithoutReencodingThem() throws {
        let legacyPayload = Data("{\"limitId\":\"codex\",\"windowId\":\"primary\",\"displayName\":\"5小时额度\",\"remainingPercent\":70,\"resolvedResetFieldName\":\"nextResetAt\",\"rawResetFields\":[{\"name\":\"nextResetAt\",\"value\":\"private-server-value\"}]}".utf8)

        let bank = try JSONDecoder().decode(ResetBankSnapshot.self, from: legacyPayload)

        XCTAssertEqual(bank.resetTimeStatus, .parseFailed)
        let encoded = try JSONEncoder().encode(bank)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(object["resetTimeStatus"] as? String, "parseFailed")
        XCTAssertNil(object["resolvedResetFieldName"])
        XCTAssertNil(object["rawResetFields"])
        XCTAssertFalse(String(data: encoded, encoding: .utf8)?.contains("private-server-value") ?? true)
    }
}

private final class LifetimeProbe: @unchecked Sendable {
    private let onDeinit: @Sendable () -> Void

    init(onDeinit: @escaping @Sendable () -> Void) {
        self.onDeinit = onDeinit
    }

    func touch() {}

    deinit {
        onDeinit()
    }
}

private actor AsyncTestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let waiters = waiters
        self.waiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
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
    private let runError: ControlledRPCTransportError?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?

    init(
        terminateExits: Bool,
        killExits: Bool,
        killSucceeds: Bool = true,
        runError: ControlledRPCTransportError? = nil
    ) {
        self.terminateExits = terminateExits
        self.killExits = killExits
        self.killSucceeds = killSucceeds
        self.runError = runError
    }

    private(set) var configuredArguments: [String] = []

    func configure(codexPath _: String, arguments: [String], stdin: Pipe, stdout: Pipe, stderr: Pipe) {
        configuredArguments = arguments
        stdinPipe = stdin
        stdoutPipe = stdout
        stderrPipe = stderr
    }
    func run() throws {
        if let runError { throw runError }
    }

    func terminate() {
        terminateCount += 1
        if terminateExits { exit() }
    }

    func kill() -> Bool {
        killCount += 1
        if killExits { exit() }
        return killSucceeds
    }

    func emitNaturalExit(status: Int32, stdout: Data, stderr: Data) {
        terminationStatus = status
        try? stdoutPipe?.fileHandleForWriting.write(contentsOf: stdout)
        try? stderrPipe?.fileHandleForWriting.write(contentsOf: stderr)
        exit()
    }

    private func exit() {
        guard isRunning else { return }
        isRunning = false
        stdoutPipe?.fileHandleForWriting.closeFile()
        stderrPipe?.fileHandleForWriting.closeFile()
        terminationHandler?(self)
    }
}

private final class RPCTransportEventRecorder: @unchecked Sendable {
    struct Snapshot {
        let order: [String]
        let stdout: Data
        let stderr: Data
    }

    private let lock = NSLock()
    private var order: [String] = []
    private var stdout = Data()
    private var stderr = Data()

    func record(_ event: String) {
        lock.lock()
        order.append(event)
        lock.unlock()
    }

    func recordStdout(_ data: Data) {
        lock.lock()
        order.append("stdout")
        stdout.append(data)
        lock.unlock()
    }

    func recordStderr(_ data: Data) {
        lock.lock()
        order.append("stderr")
        stderr.append(data)
        lock.unlock()
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(order: order, stdout: stdout, stderr: stderr)
    }
}

private final class ControlledRPCTransport: CodexRPCTransport, @unchecked Sendable {
    let startedExpectation = XCTestExpectation(description: "transport started")
    let initializeRequestExpectation = XCTestExpectation(description: "initialize request written")
    let rateLimitRequestExpectation = XCTestExpectation(description: "rate limits request written")
    let accountRequestExpectation = XCTestExpectation(description: "account request written")
    private(set) var shutdownCount = 0
    private(set) var handlersCleared = false
    private(set) var writtenMessages: [CodexAppServerMessage] = []
    private var stdout: (@Sendable (Data) -> Void)?
    private var stdoutEOF: (@Sendable () -> Void)?
    private var stderr: (@Sendable (Data) -> Void)?
    private var termination: (@Sendable (Int32) -> Void)?
    private let cleanupError: ProcessCleanupError?
    private let startError: ControlledRPCTransportError?
    private let writeError: ControlledRPCTransportError?
    private let writeErrorOnMethod: String?

    init(
        cleanupError: ProcessCleanupError? = nil,
        startError: ControlledRPCTransportError? = nil,
        writeError: ControlledRPCTransportError? = nil,
        writeErrorOnMethod: String? = nil
    ) {
        self.cleanupError = cleanupError
        self.startError = startError
        self.writeError = writeError
        self.writeErrorOnMethod = writeErrorOnMethod
    }

    func start(
        stdout: @escaping @Sendable (Data) -> Void,
        stdoutEOF: @escaping @Sendable () -> Void,
        stderr: @escaping @Sendable (Data) -> Void,
        termination: @escaping @Sendable (Int32) -> Void
    ) throws {
        self.stdout = stdout
        self.stdoutEOF = stdoutEOF
        self.stderr = stderr
        self.termination = termination
        startedExpectation.fulfill()
        if let startError { throw startError }
    }

    func write(_ data: Data) throws {
        let line = Data(data.dropLast(data.last == 0x0A ? 1 : 0))
        let decodedMessage = try? CodexAppServerCodec.decodeLine(line)
        if let writeError {
            if writeErrorOnMethod == nil {
                throw writeError
            }
            if case .request(_, let method, _)? = decodedMessage, method == writeErrorOnMethod {
                throw writeError
            }
        }
        if let message = decodedMessage {
            writtenMessages.append(message)
            if case .request(_, "initialize", _) = message {
                initializeRequestExpectation.fulfill()
            }
            if case .request(_, "account/rateLimits/read", _) = message {
                rateLimitRequestExpectation.fulfill()
            }
            if case .request(_, "account/read", _) = message {
                accountRequestExpectation.fulfill()
            }
        }
    }

    func shutdownAndWait() throws {
        shutdownCount += 1
        stdout = nil
        stdoutEOF = nil
        stderr = nil
        termination = nil
        handlersCleared = true
        if let cleanupError { throw cleanupError }
    }

    func emitStdout(_ data: Data) {
        stdout?(data)
    }

    func emitStdoutEOF() {
        stdoutEOF?()
    }

    func emitStderr(_ data: Data) {
        stderr?(data)
    }

    func emitTermination(status: Int32) {
        termination?(status)
    }
}

private enum ControlledRPCTransportError: Error, Equatable {
    case startFailed
    case writeFailed
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

private final class MutableResolverFileSystem: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: CodexExecutableResolver.FileSystem.Item]

    init(items: [String: CodexExecutableResolver.FileSystem.Item] = [:]) {
        self.items = items
    }

    var interface: CodexExecutableResolver.FileSystem {
        CodexExecutableResolver.FileSystem(
            itemAtPath: { [self] path in item(at: path) },
            canonicalPath: { $0 },
            directoryContents: { _ in [] }
        )
    }

    func setItem(_ item: CodexExecutableResolver.FileSystem.Item, at path: String) {
        lock.lock()
        items[path] = item
        lock.unlock()
    }

    private func item(at path: String) -> CodexExecutableResolver.FileSystem.Item {
        lock.lock()
        defer { lock.unlock() }
        return items[path] ?? .missing
    }
}

private final class ControlledExecutableQuotaFetcher: @unchecked Sendable {
    private let lock = NSLock()
    private var outcomes: [String: [Result<QuotaSnapshot, RealQuotaError>]]
    private var paths: [String] = []

    init(outcomes: [String: [Result<QuotaSnapshot, RealQuotaError>]]) {
        self.outcomes = outcomes
    }

    var requestedPaths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return paths
    }

    func fetch(path: String, timeoutSeconds _: Double) throws -> QuotaSnapshot {
        let outcome: Result<QuotaSnapshot, RealQuotaError>
        lock.lock()
        paths.append(path)
        if var pathOutcomes = outcomes[path], !pathOutcomes.isEmpty {
            outcome = pathOutcomes.removeFirst()
            outcomes[path] = pathOutcomes
        } else {
            outcome = .failure(.spawnFailed)
        }
        lock.unlock()
        return try outcome.get()
    }
}
