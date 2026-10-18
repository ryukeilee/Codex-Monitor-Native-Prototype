import Foundation
import XCTest
@testable import CodexMonitorNative

/// Opt-in live protocol integration against a real `codex app-server`.
///
/// Run with:
///
/// ```bash
/// CODEX_MONITOR_LIVE_CODEX=1 swift test --filter LiveCodexAppServerProtocolTests
/// ```
///
/// The suite is skipped by default so `swift test` stays hermetic. When it does run it talks to
/// the `codex` executable the production resolver would pick, which requires a `codex` install and
/// (for the refresh test) an authenticated ChatGPT session. It never prints or persists account,
/// session, or auth-file material; it records only frame counts, decoded value shapes, and quota
/// percentages.
///
/// What it pins, which synthetic fixtures cannot:
///
/// - a real `app-server` frame is one newline-delimited JSON object, and every frame it emits
///   decodes through `CodexAppServerCodec.decodeLine` without a protocol violation;
/// - the numbers the model reads survive the single-pass `JSONSerialization` decode unchanged: for
///   every captured frame, the multiset of wire number literals (canonicalized through the
///   documented numeric contract) equals the multiset of numbers in the decoded value tree. The
///   real notification envelope carries a top-level `emittedAtMs` beside `method` and `params`,
///   which both the current and the pre-change decoder ignore, so the comparison covers the
///   top-level fields the model reads (`id`, `result`, `error`, `method`, `params`);
/// - the real `initialize` result carries the four fields the handshake requires, and a real
///   unknown-method rejection arrives as a `.error` message with a `code`, a non-empty `message`,
///   and no `data` payload;
/// - the production `CodexRPCClient` refresh path yields an account-bound snapshot whose weekly
///   window is current.
final class LiveCodexAppServerProtocolTests: XCTestCase {
    private static let optInVariable = "CODEX_MONITOR_LIVE_CODEX"

    // MARK: - Wire contract on real frames

    func testRealAppServerFramesDecodeAndPreserveEveryWireNumber() throws {
        try Self.requireOptIn()
        let codexPath = try Self.resolveCodexPath()
        Self.reportServerVersion(codexPath: codexPath)

        let session = try LiveAppServerSession(codexPath: codexPath)
        defer { session.shutdown() }

        try session.writeFrame(
            CodexAppServerCodec.encodeRequest(
                id: .integer(1),
                method: "initialize",
                params: .object([
                    "clientInfo": .object([
                        "name": .string("codex-monitor-native"),
                        "title": .string("Codex Monitor Native"),
                        "version": .string("0.2.0")
                    ])
                ])
            )
        )
        try session.writeFrame(CodexAppServerCodec.encodeNotification(method: "initialized"))
        try session.writeFrame(
            CodexAppServerCodec.encodeRequest(id: .integer(2), method: "account/rateLimits/read")
        )
        // The app-server answers an unknown method with a rejection frame; the client's
        // classification path consumes that shape.
        try session.writeFrame(
            CodexAppServerCodec.encodeRequest(id: .integer(3), method: "nonexistent/probe")
        )

        let rateLimitsFrame = try XCTUnwrap(
            session.waitForLine(timeout: 60) { line in
                guard case .response(let id, _)? = Self.decodedMessage(line) else { return false }
                return id == .integer(2)
            },
            "the real app-server did not answer account/rateLimits/read: \(session.diagnosticSummary)"
        )
        let rejectionFrame = try XCTUnwrap(
            session.waitForLine(timeout: 60) { line in
                guard case .error(let id, _)? = Self.decodedMessage(line) else { return false }
                return id == .integer(3)
            },
            "the real app-server did not reject the unknown method: \(session.diagnosticSummary)"
        )

        // The three responses the test drives are required; the startup notification stream is
        // expected but not part of the protocol contract, so the frame count only asserts what is
        // guaranteed. Every captured frame still goes through the wire-number comparison below.
        let lines = session.capturedLines
        XCTAssertGreaterThanOrEqual(lines.count, 3)
        try Self.assertWireNumbersSurviveDecoding(lines)

        // The handshake the client performs requires these four string fields.
        let initializeResult = try Self.resultObject(of: lines, id: .integer(1))
        for key in ["codexHome", "platformFamily", "platformOs", "userAgent"] {
            XCTAssertNotNil(initializeResult[key] as? String, "initialize result is missing \(key)")
        }

        guard case .error(let rejectionID, let rejection) = try Self.decode(rejectionFrame) else {
            return XCTFail("expected an error frame for the unknown method")
        }
        XCTAssertEqual(rejectionID, .integer(3))
        XCTAssertEqual(rejection.code, -32_600)
        XCTAssertFalse(rejection.message.isEmpty)
        XCTAssertNil(rejection.data, "the real rejection frame carried an unexpected data payload")

        // The rate-limits payload the production parser consumes must stay usable.
        let rateLimitsResult = try Self.resultObject(of: [rateLimitsFrame], id: .integer(2))
        let snapshot = try XCTUnwrap(
            RealQuotaProvider.parseRateLimits(response: rateLimitsResult),
            "the real rate-limits payload did not parse"
        )
        let weekly = try XCTUnwrap(
            snapshot.quotaWindows.first { $0.kind == .weekly },
            "the real rate-limits payload had no weekly window"
        )
        XCTAssertEqual(weekly.durationMinutes, 10_080)
        XCTAssertEqual(weekly.state, .live)
        XCTAssertEqual(snapshot.weeklyQuotaState, .live)
        XCTAssertTrue((0...100).contains(snapshot.weeklyQuotaPercent))
        Self.report(
            "frames=\(lines.count) weeklyRemaining=\(snapshot.weeklyQuotaPercent) "
                + "fiveHourRemaining=\(snapshot.fiveHourQuotaPercent) windows=\(snapshot.quotaWindows.count)"
        )
    }

    // MARK: - Production refresh path

    func testRealAppServerRefreshProducesABoundUsableSnapshot() async throws {
        try Self.requireOptIn()
        let codexPath = try Self.resolveCodexPath()
        Self.reportServerVersion(codexPath: codexPath)

        guard CodexAuthIdentityReader.currentBoundary() != nil else {
            throw XCTSkip(
                "the live refresh test needs an authenticated Codex session for the "
                    + "account-bound snapshot check"
            )
        }

        let transport = RecordingRPCTransport(codexPath: codexPath)
        let client = CodexRPCClient(
            transport: transport,
            timeoutScheduler: LiveTimeoutScheduler(),
            authBoundaryReader: { CodexAuthIdentityReader.boundary(codexHome: $0) }
        )

        let snapshot = try await client.fetchQuota(timeoutSeconds: 60)

        let boundary = try XCTUnwrap(snapshot.accountBoundary, "the refresh returned no account boundary")
        XCTAssertTrue(boundary.isValid)
        XCTAssertEqual(snapshot.weeklyQuotaState, .live)
        let weekly = try XCTUnwrap(
            snapshot.quotaWindows.first { $0.kind == .weekly },
            "the live refresh produced no weekly window"
        )
        XCTAssertEqual(weekly.durationMinutes, 10_080)
        XCTAssertEqual(weekly.state, .live)
        XCTAssertEqual(snapshot.weeklyQuotaPercent, weekly.remainingPercent)

        // The client shuts the server down as soon as the response arrives, so the tail of the
        // startup notification stream can be dropped after shutdown begins: the initialize
        // response and the rate-limits response are the frames that must be present.
        let lines = transport.capturedLines
        XCTAssertGreaterThanOrEqual(lines.count, 3)
        try Self.assertWireNumbersSurviveDecoding(lines)
        Self.report(
            "refresh frames=\(lines.count) weeklyRemaining=\(snapshot.weeklyQuotaPercent) "
                + "fiveHourRemaining=\(snapshot.fiveHourQuotaPercent) windows=\(snapshot.quotaWindows.count)"
        )
        Self.report("refresh transport \(transport.bootBreakdown)")
    }

    // MARK: - Wire scanner oracle

    /// The scanner is the oracle for the live comparison, so its model of the decoder is pinned
    /// here, without launching a process: it must agree with `decodedNumbers(_:)` for the envelope
    /// shapes the model reads and ignores, including a repeated object key at any depth
    /// (`JSONSerialization` keeps the first value) and digits inside strings.
    func testWireNumberScannerAgreesWithTheDecodedEnvelope() throws {
        let lines = [
            #"{"id":1,"result":{"n":2},"emittedAtMs":3}"#,
            #"{"method":"m","params":[1,2],"emittedAtMs":3}"#,
            #"{"method":"m","params":{"deep":[{"n":4}]},"emittedAtMs":5}"#,
            #"{"id":1,"id":2,"result":null}"#,
            #"{"method":"m","params":1,"params":2}"#,
            #"{"emittedAtMs":1,"emittedAtMs":2,"id":3,"result":null}"#,
            #"{"id":2,"result":null,"emittedAtMs":{"a":1}}"#,
            #"{"id":1,"method":"m","params":{"a":1,"a":2}}"#,
            #"{"id":1,"result":"n=42 and \"7\""}"#,
            #"{"id":1,"result":"\\u0037"}"#,
            #"{"id":1,"result":-0.0}"#,
            #"{"id":1,"result":-9223372036854775808}"#,
            #"{"id":1,"result":5e-324}"#,
            #"{"id":1,"error":{"code":-32600,"message":"m"},"emittedAtMs":9}"#,
            #"{"id":1,"result":[true,false,null,"1"]}"#
        ]
        for line in lines {
            let message = try CodexAppServerCodec.decodeLine(Data(line.utf8))
            XCTAssertEqual(
                Self.wireNumbers(Data(line.utf8)),
                Self.decodedNumbers(message),
                "line: \(line)"
            )
        }
    }

    // MARK: - Opt-in plumbing

    private static func requireOptIn() throws {
        guard ProcessInfo.processInfo.environment[optInVariable] == "1" else {
            throw XCTSkip("Opt-in live app-server integration: set \(optInVariable)=1 to run")
        }
    }

    private static func resolveCodexPath() throws -> String {
        let candidates: [CodexExecutableResolver.Candidate]
        do {
            candidates = try CodexExecutableResolver().resolve()
        } catch let failure as CodexExecutableResolver.ResolutionFailure {
            throw XCTSkip("codex executable could not be resolved: \(failure)")
        }
        guard let candidate = candidates.first else {
            throw XCTSkip("no runnable codex executable was resolved")
        }
        return candidate.path
    }

    /// Prints the CLI version for the evidence log, with a bounded wait: a broken executable that
    /// never exits must not hang the suite.
    private static func reportServerVersion(codexPath: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: codexPath)
        process.arguments = ["--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else {
            return report("serverVersion=unavailable")
        }
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        guard !process.isRunning else {
            process.terminate()
            try? pipe.fileHandleForReading.close()
            return report("serverVersion=timed out")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let version = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
        report("serverVersion=\(version)")
    }

    private static func report(_ message: String) {
        print("LIVE \(message)")
    }

    // MARK: - Wire inspection

    private static func decode(_ line: Data) throws -> CodexAppServerMessage {
        try CodexAppServerCodec.decodeLine(line)
    }

    private static func decodedMessage(_ line: Data) -> CodexAppServerMessage? {
        try? CodexAppServerCodec.decodeLine(line)
    }

    private static func assertWireNumbersSurviveDecoding(_ lines: [Data]) throws {
        for line in lines {
            let message: CodexAppServerMessage
            do {
                message = try decode(line)
            } catch {
                XCTFail("a real frame failed to decode (\(error)): \(describe(line))")
                continue
            }
            XCTAssertEqual(
                decodedNumbers(message),
                wireNumbers(line),
                "decoded numbers diverged from the wire literals in: \(describe(line))"
            )
        }
    }

    private static func resultObject(
        of lines: [Data],
        id: CodexAppServerRequestID
    ) throws -> [String: Any] {
        for line in lines {
            guard let message = decodedMessage(line),
                  case .response(let responseID, let result) = message,
                  responseID == id,
                  let object = result.foundationObject() else {
                continue
            }
            return object
        }
        throw LiveProtocolFailure("no response with id \(id) was captured")
    }

    /// Canonical text of every number in a decoded message, matching what `wireNumbers` produces.
    private static func decodedNumbers(_ message: CodexAppServerMessage) -> [String] {
        var numbers: [String] = []

        func collect(_ value: CodexAppServerJSONValue) {
            switch value {
            case .object(let object):
                object.values.forEach(collect)
            case .array(let array):
                array.forEach(collect)
            case .integer(let integer):
                numbers.append(String(integer))
            case .number(let number):
                numbers.append(String(number))
            case .string, .bool, .null:
                break
            }
        }

        func collect(_ id: CodexAppServerRequestID) {
            switch id {
            case .integer(let integer):
                numbers.append(String(integer))
            case .string:
                break
            }
        }

        switch message {
        case .response(let id, let result):
            collect(id)
            collect(result)
        case .error(let id, let error):
            collect(id)
            numbers.append(String(error.code))
            error.data.map(collect)
        case .request(let id, _, let params):
            collect(id)
            params.map(collect)
        case .notification(_, let params):
            params.map(collect)
        }
        return numbers.sorted()
    }

    /// Top-level keys whose values the message model reads. `method` is listed for completeness;
    /// its value is a string. A top-level key outside this set (the real envelope's
    /// `emittedAtMs`) is dropped by the model, so its numbers are not part of the comparison.
    private static let modelledTopLevelKeys: Set<String> = ["id", "result", "error", "method", "params"]

    /// Canonical text of every JSON number literal the model reads from a raw frame.
    ///
    /// The scan is deliberately independent of the codec: it walks the bytes, skips string
    /// literals (so digits inside strings are not numbers), and reads each number token it finds
    /// outside a string. It tracks the open containers only to know whether a token sits in a value
    /// the model reads: a number under an unmodelled top-level key is excluded, and a repeated
    /// object key contributes only its first value, which is what `JSONSerialization` keeps.
    ///
    /// Each token is then mapped through the documented numeric contract, so a literal and its
    /// decoded value produce the same text: an integer literal keeps its exact `Int64` when it
    /// fits and otherwise becomes its double image; a floating-point literal becomes `.integer`
    /// when its double is exactly that `Int64` (with `Int64.min` excepted, because its double
    /// image is shared with out-of-range neighbours) and its double image otherwise.
    private static func wireNumbers(_ line: Data) -> [String] {
        /// One entry per open container.
        struct Container {
            /// Whether numbers inside it belong to a value the model does not read.
            var ignoresValues: Bool
            /// Whether it is an object, the only place a key can appear.
            var isObject: Bool
            /// Keys already seen here; `JSONSerialization` keeps the first value of a repeat.
            var seenKeys: Set<String>
        }

        let bytes = [UInt8](line)
        var numbers: [String] = []
        var index = 0
        var containers: [Container] = []
        // The key whose value is being read, and whether that value must be skipped.
        var pendingKey: String?
        var ignoresPendingValue = false

        func ignoresCurrentValue() -> Bool {
            if containers.last?.ignoresValues == true || ignoresPendingValue { return true }
            // Only the top-level object has keys the model may not read; nested objects are kept
            // whole. `containers.count == 1` means the token sits directly in the top-level value.
            guard containers.count == 1, let pendingKey else { return false }
            return !modelledTopLevelKeys.contains(pendingKey)
        }

        func clearPendingValue() {
            pendingKey = nil
            ignoresPendingValue = false
        }

        while index < bytes.count {
            let byte = bytes[index]

            if byte == UInt8(ascii: "\"") {
                let start = index
                index += 1
                while index < bytes.count {
                    if bytes[index] == UInt8(ascii: "\\") {
                        index += 2
                        continue
                    }
                    if bytes[index] == UInt8(ascii: "\"") {
                        index += 1
                        break
                    }
                    index += 1
                }
                if containers.last?.isObject == true, isKeyPosition(bytes, from: index) {
                    let key = String(
                        decoding: bytes[(start + 1)..<max(start + 1, index - 1)],
                        as: UTF8.self
                    )
                    pendingKey = key
                    ignoresPendingValue = !containers[containers.count - 1].seenKeys.insert(key).inserted
                } else {
                    clearPendingValue()
                }
                continue
            }

            if byte == UInt8(ascii: "{") || byte == UInt8(ascii: "[") {
                let ignoresValues = ignoresCurrentValue()
                clearPendingValue()
                containers.append(
                    Container(
                        ignoresValues: ignoresValues,
                        isObject: byte == UInt8(ascii: "{"),
                        seenKeys: []
                    )
                )
                index += 1
                continue
            }

            if byte == UInt8(ascii: "}") || byte == UInt8(ascii: "]") {
                if !containers.isEmpty { containers.removeLast() }
                clearPendingValue()
                index += 1
                continue
            }

            guard byte == UInt8(ascii: "-") || (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")) else {
                index += 1
                continue
            }

            let start = index
            while index < bytes.count, isNumberByte(bytes[index]) {
                index += 1
            }
            let token = String(decoding: bytes[start..<index], as: UTF8.self)
            if !ignoresCurrentValue() {
                numbers.append(canonicalNumber(fromWireLiteral: token))
            }
            clearPendingValue()
        }
        return numbers.sorted()
    }

    /// Whether the next non-whitespace byte after `index` is `:`, which makes the string that
    /// ended at `index` an object key rather than a value.
    private static func isKeyPosition(_ bytes: [UInt8], from index: Int) -> Bool {
        var cursor = index
        while cursor < bytes.count, isWhitespace(bytes[cursor]) {
            cursor += 1
        }
        return cursor < bytes.count && bytes[cursor] == UInt8(ascii: ":")
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\t")
            || byte == UInt8(ascii: "\n") || byte == UInt8(ascii: "\r")
    }

    private static func isNumberByte(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "+"), UInt8(ascii: "-"), UInt8(ascii: "."),
             UInt8(ascii: "e"), UInt8(ascii: "E"):
            return true
        default:
            return byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
        }
    }

    private static func canonicalNumber(fromWireLiteral token: String) -> String {
        let isFloatingSyntax = token.contains(".") || token.contains("e") || token.contains("E")
        if !isFloatingSyntax, let integer = Int64(token) {
            return String(integer)
        }
        guard let double = Double(token), double.isFinite else {
            return token
        }
        if double.rounded() == double, let integer = Int64(exactly: double), integer != .min {
            return String(integer)
        }
        return String(double)
    }

    private static func describe(_ line: Data) -> String {
        let text = String(decoding: line, as: UTF8.self)
        return text.count <= 240 ? text : String(text.prefix(240)) + "…"
    }
}

private struct LiveProtocolFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

/// Drives a real `codex app-server` over the production transport and records raw stdout frames.
private final class LiveAppServerSession: @unchecked Sendable {
    private let transport: ProcessRPCTransport
    private let lock = NSLock()
    private var buffer = Data()
    private var lines: [Data] = []
    private var stderrTail = ""
    private var exitStatus: Int32?

    init(codexPath: String, graceSeconds: TimeInterval = 3) throws {
        transport = ProcessRPCTransport(codexPath: codexPath, shutdownGraceSeconds: graceSeconds)
        try transport.start(
            stdout: { [weak self] chunk in self?.ingest(chunk) },
            stdoutEOF: {},
            stderr: { [weak self] chunk in
                guard let self else { return }
                lock.lock()
                stderrTail = String(decoding: chunk, as: UTF8.self).suffix(400).description
                lock.unlock()
            },
            termination: { [weak self] status in
                guard let self else { return }
                lock.lock()
                exitStatus = status
                lock.unlock()
            }
        )
    }

    private func ingest(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: 0x0A) {
            lines.append(buffer.subdata(in: buffer.startIndex..<newline))
            buffer.removeSubrange(buffer.startIndex...newline)
        }
    }

    func writeFrame(_ data: Data) throws {
        var framed = data
        framed.append(0x0A)
        try transport.write(framed)
    }

    var capturedLines: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }

    var diagnosticSummary: String {
        lock.lock()
        defer { lock.unlock() }
        let status = exitStatus.map(String.init) ?? "running"
        return "frames=\(lines.count) exit=\(status) stderr=\(stderrTail.isEmpty ? "<empty>" : stderrTail)"
    }

    func waitForLine(timeout: TimeInterval, where predicate: (Data) -> Bool) -> Data? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let match = capturedLines.first(where: predicate) {
                return match
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return capturedLines.first(where: predicate)
    }

    func shutdown() {
        try? transport.shutdownAndWait()
    }
}

/// Wraps the production transport so a test can inspect the exact bytes the app-server wrote.
///
/// It also records the structure of the stdout stream and the phases of a refresh, so the opt-in
/// live report can show *where* a refresh spends its time: how many stdout callbacks the transport
/// delivered, how many bytes they carried, how many callbacks contributed to each frame, and the
/// start → first frame → shutdown split. Recording is passive: `capturedLines` and the production
/// transport's behaviour are unchanged, and every counter is guarded by `lock`.
private final class RecordingRPCTransport: CodexRPCTransport, @unchecked Sendable {
    private let inner: ProcessRPCTransport
    private let lock = NSLock()
    private var buffer = Data()
    private var lines: [Data] = []

    /// Wall-clock origin of `start()`, the reference for every phase below.
    private var startedAt: Date?
    /// Time from `start()` until the first complete frame.
    private var firstFrameElapsed: TimeInterval?
    /// Time from `start()` until `shutdownAndWait()` was called.
    private var stopRequestedElapsed: TimeInterval?
    /// Time from `start()` until `shutdownAndWait()` returned.
    private var totalElapsed: TimeInterval?
    /// Total stdout callbacks and the bytes they delivered.
    private var stdoutChunkCount = 0
    private var stdoutByteCount = 0
    /// How many *earlier* stdout callbacks already contributed bytes to the frame that is still
    /// incomplete in `buffer`. It is cleared whenever a callback starts with an empty buffer and
    /// after every completed frame, so `recordFrame` can turn it into the frame's contribution
    /// callback count as `residueCallbacks + 1`.
    private var residueCallbacks = 0
    /// Per-frame contribution callback count: how many stdout callbacks delivered the bytes of that
    /// frame. 1 means the frame arrived complete inside a single callback; 2 or more means the frame
    /// was reassembled across callback boundaries, i.e. it was genuinely split. Frame-by-frame
    /// reasoning for the interesting chunk sequences:
    /// - `"A\n"` then `"B\n"` → `[1, 1]`: each frame is owned by its own callback.
    /// - `"A\nB\n"` → `[1, 1]`: two frames inside one callback, each contributed by that callback
    ///   only (the counter restarts at 1 after every frame).
    /// - `"A\nB"` then `"C\n"` → `[1, 2]`: the second frame is `"BC"` and spans two callbacks.
    /// - `"A"` then `"\n"` → `[2]`: the single frame needed both callbacks.
    private var frameCallbacks: [Int] = []
    /// Per-frame byte length on the wire, including frames reassembled from several callbacks.
    private var frameByteCounts: [Int] = []
    /// Per-frame completion time relative to `start()`, parallel to `frameByteCounts`.
    private var frameElapsed: [TimeInterval] = []
    /// Time relative to `start()` of every `write(_:)` call (production refresh issues three:
    /// the initialize request, the initialized notification, and the rate-limits request).
    private var writeElapsed: [TimeInterval] = []

    init(codexPath: String, graceSeconds: TimeInterval = 3) {
        inner = ProcessRPCTransport(codexPath: codexPath, shutdownGraceSeconds: graceSeconds)
    }

    var capturedLines: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }

    /// One-line millisecond/byte summary of the measured phases and per-frame contribution
    /// callbacks for the live report. A phase that was never reached reads `n/a` rather than a
    /// fabricated number.
    var bootBreakdown: String {
        lock.lock()
        defer { lock.unlock() }
        func milliseconds(_ elapsed: TimeInterval?) -> String {
            guard let elapsed else { return "n/a" }
            return String(format: "%.2f", elapsed * 1000)
        }
        func millisecondList(_ elapsed: [TimeInterval]) -> String {
            elapsed.map { String(format: "%.1f", $0 * 1000) }.joined(separator: ",")
        }
        let frames = frameByteCounts.map(String.init).joined(separator: ",")
        let callbacks = frameCallbacks.map(String.init).joined(separator: ",")
        return "totalMs=\(milliseconds(totalElapsed)) "
            + "startToFirstFrameMs=\(milliseconds(firstFrameElapsed)) "
            + "startToStopMs=\(milliseconds(stopRequestedElapsed)) "
            + "shutdownMs=\(milliseconds(shutdownDuration)) "
            + "stdoutChunks=\(stdoutChunkCount) stdoutBytes=\(stdoutByteCount) "
            + "frames=[\(frames)] frameCallbacks=[\(callbacks)] "
            + "timesMs=[\(millisecondList(frameElapsed))] "
            + "writesMs=[\(millisecondList(writeElapsed))]"
    }

    private var shutdownDuration: TimeInterval? {
        guard let totalElapsed, let stopRequestedElapsed else { return nil }
        return totalElapsed - stopRequestedElapsed
    }

    func start(
        stdout: @escaping @Sendable (Data) -> Void,
        stdoutEOF: @escaping @Sendable () -> Void,
        stderr: @escaping @Sendable (Data) -> Void,
        termination: @escaping @Sendable (Int32) -> Void
    ) throws {
        lock.lock()
        startedAt = Date()
        lock.unlock()
        try inner.start(
            stdout: { [weak self] chunk in
                self?.ingest(chunk)
                stdout(chunk)
            },
            stdoutEOF: stdoutEOF,
            stderr: stderr,
            termination: termination
        )
    }

    private func ingest(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        stdoutChunkCount += 1
        stdoutByteCount += chunk.count
        if buffer.isEmpty {
            residueCallbacks = 0
        } else {
            residueCallbacks += 1
        }
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let frame = buffer.subdata(in: buffer.startIndex..<newline)
            lines.append(frame)
            buffer.removeSubrange(buffer.startIndex...newline)
            recordFrame(frame)
        }
    }

    /// Records one completed frame; the caller must hold `lock`.
    ///
    /// Its contribution callback count is this callback plus every earlier callback that left bytes
    /// in `buffer` (`residueCallbacks`); the residue is cleared immediately so a following frame
    /// inside the same callback counts from 1 again.
    private func recordFrame(_ frame: Data) {
        let completedAt = Date()
        if firstFrameElapsed == nil, let startedAt {
            firstFrameElapsed = completedAt.timeIntervalSince(startedAt)
        }
        if let startedAt {
            frameElapsed.append(completedAt.timeIntervalSince(startedAt))
        }
        frameCallbacks.append(residueCallbacks + 1)
        residueCallbacks = 0
        frameByteCounts.append(frame.count)
    }

    func write(_ data: Data) throws {
        lock.lock()
        if let startedAt {
            writeElapsed.append(Date().timeIntervalSince(startedAt))
        }
        lock.unlock()
        try inner.write(data)
    }

    func shutdownAndWait() throws {
        lock.lock()
        if let startedAt {
            stopRequestedElapsed = Date().timeIntervalSince(startedAt)
        }
        lock.unlock()
        try inner.shutdownAndWait()
        lock.lock()
        if let startedAt {
            totalElapsed = Date().timeIntervalSince(startedAt)
        }
        lock.unlock()
    }
}

/// Production-equivalent timeout scheduling for the live refresh test, so a stalled server cannot
/// hang the suite.
private final class LiveTimeoutScheduler: CodexRPCTimeoutScheduling, @unchecked Sendable {
    func schedule(
        after seconds: Double,
        action: @escaping @Sendable () -> Void
    ) -> any CodexRPCCancellable {
        let work = DispatchWorkItem(block: action)
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: work)
        return LiveTimeoutToken(work: work)
    }

    private final class LiveTimeoutToken: CodexRPCCancellable, @unchecked Sendable {
        private let work: DispatchWorkItem

        init(work: DispatchWorkItem) {
            self.work = work
        }

        func cancel() {
            work.cancel()
        }
    }
}
