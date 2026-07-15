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
            XCTAssertEqual(error, .processExited(9))
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

    func testRPCClientRejectsMismatchedResponseID() async {
        let transport = ControlledRPCTransport()
        let client = CodexRPCClient(
            transport: transport,
            timeoutScheduler: ControlledTimeoutScheduler()
        )
        let task = Task { try await client.fetchQuota(timeoutSeconds: 60) }

        await fulfillment(of: [transport.startedExpectation], timeout: 1)
        transport.emitStdout(Data("{\"id\":99,\"result\":{}}\n".utf8))

        await assertFailure(.responseInvalid, from: task)
        XCTAssertEqual(transport.shutdownCount, 1)
    }

    func testRPCClientRejectsMalformedFrameWithoutWaitingForTimeout() async {
        let transport = ControlledRPCTransport()
        let timeoutScheduler = ControlledTimeoutScheduler()
        let client = CodexRPCClient(transport: transport, timeoutScheduler: timeoutScheduler)
        let task = Task { try await client.fetchQuota(timeoutSeconds: 60) }

        await fulfillment(of: [transport.startedExpectation], timeout: 1)
        transport.emitStdout(Data("not-json\n".utf8))

        await assertFailure(.responseInvalid, from: task)
        XCTAssertEqual(timeoutScheduler.cancelCount, 1)
    }

    func testRPCClientRejectsInvalidInitializePayloadAsHandshakeFailure() async {
        let transport = ControlledRPCTransport()
        let client = CodexRPCClient(
            transport: transport,
            timeoutScheduler: ControlledTimeoutScheduler()
        )
        let task = Task { try await client.fetchQuota(timeoutSeconds: 60) }

        await fulfillment(of: [transport.initializeRequestExpectation], timeout: 1)
        transport.emitStdout(Data("{\"id\":1,\"result\":{\"protocolVersion\":1}}\n".utf8))

        await assertFailure(.handshakeFailed, from: task)
        XCTAssertEqual(transport.shutdownCount, 1)
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

    func testRPCClientRejectsUnsupportedServerRequestAndRepliesMethodNotFound() async {
        let transport = ControlledRPCTransport()
        let client = CodexRPCClient(
            transport: transport,
            timeoutScheduler: ControlledTimeoutScheduler()
        )
        let task = Task { try await client.fetchQuota(timeoutSeconds: 60) }

        await fulfillment(of: [transport.initializeRequestExpectation], timeout: 1)
        transport.emitStdout(Data("{\"id\":\"server-1\",\"method\":\"attestation/generate\",\"params\":{}}\n".utf8))

        await assertFailure(.unsupportedServerRequest, from: task)
        XCTAssertEqual(
            transport.writtenMessages.last,
            .error(
                id: .string("server-1"),
                error: CodexAppServerRemoteError(code: -32_601, message: "Method not found")
            )
        )
    }

    func testRPCClientRejectsFrameThatExceedsConfiguredLimit() async {
        let transport = ControlledRPCTransport()
        let client = CodexRPCClient(
            transport: transport,
            timeoutScheduler: ControlledTimeoutScheduler(),
            maxFrameBytes: 32
        )
        let task = Task { try await client.fetchQuota(timeoutSeconds: 60) }

        await fulfillment(of: [transport.startedExpectation], timeout: 1)
        transport.emitStdout(Data(repeating: 0x41, count: 33))

        await assertFailure(.responseInvalid, from: task)
    }

    func testRPCClientTreatsWriteFailureAsTransportFailure() async {
        let transport = ControlledRPCTransport(writeError: .writeFailed)
        let client = CodexRPCClient(
            transport: transport,
            timeoutScheduler: ControlledTimeoutScheduler()
        )

        let task = Task { try await client.fetchQuota(timeoutSeconds: 60) }

        await assertFailure(.transportFailed, from: task)
        XCTAssertEqual(transport.shutdownCount, 1)
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

    func testRPCClientBoundsStderrAndClassifiesCleanEarlyExitConsistently() async {
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

        await assertFailure(.processExited(0), from: task)
        XCTAssertFalse(RealQuotaError.processExited(0).localizedDescription.contains("private-diagnostic-value"))
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

    func testRPCClientRequiresSchemaRateLimitsFieldBeforeMappingDynamicBuckets() async {
        let transport = ControlledRPCTransport()
        let client = CodexRPCClient(
            transport: transport,
            timeoutScheduler: ControlledTimeoutScheduler()
        )
        let task = Task { try await client.fetchQuota(timeoutSeconds: 60) }

        await fulfillment(of: [transport.initializeRequestExpectation], timeout: 1)
        transport.emitStdout(Self.initializeResponse)
        await fulfillment(of: [transport.rateLimitRequestExpectation], timeout: 1)
        transport.emitStdout(Data("{\"id\":2,\"result\":{\"rateLimitsByLimitId\":{\"codex\":{\"primary\":{\"usedPercent\":50}}}}}\n".utf8))

        await assertFailure(.responseInvalid, from: task)
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

    func configure(codexPath _: String, stdin: Pipe, stdout: Pipe, stderr: Pipe) {
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

    init(
        cleanupError: ProcessCleanupError? = nil,
        startError: ControlledRPCTransportError? = nil,
        writeError: ControlledRPCTransportError? = nil
    ) {
        self.cleanupError = cleanupError
        self.startError = startError
        self.writeError = writeError
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
        if let writeError { throw writeError }
        let line = Data(data.dropLast(data.last == 0x0A ? 1 : 0))
        if let message = try? CodexAppServerCodec.decodeLine(line) {
            writtenMessages.append(message)
            if case .request(_, "initialize", _) = message {
                initializeRequestExpectation.fulfill()
            }
            if case .request(_, "account/rateLimits/read", _) = message {
                rateLimitRequestExpectation.fulfill()
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
