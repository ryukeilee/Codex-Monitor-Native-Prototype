import Combine
import Foundation
import XCTest
@testable import CodexMonitorNative

@MainActor
final class DeterministicFaultScenarioTests: XCTestCase {
    func testActiveRefreshFaultOrderingsReplayWithoutCrossAccountLeakOrDuplicateRPC() async throws {
        let faultOrderings: [[ScenarioEvent]] = [
            [.networkUnavailable, .sleep, .accountChange(.b)],
            [.networkUnavailable, .accountChange(.b), .sleep],
            [.sleep, .networkUnavailable, .accountChange(.b)],
            [.sleep, .accountChange(.b), .networkUnavailable],
            [.accountChange(.b), .networkUnavailable, .sleep],
            [.accountChange(.b), .sleep, .networkUnavailable]
        ]

        for (index, faultOrdering) in faultOrderings.enumerated() {
            let weekly = 21 + index
            let events: [ScenarioEvent] = [
                .request(.manual, cancellation: .ignore),
                .awaitRPC(1)
            ] + faultOrdering + [
                .wake,
                .networkRestored,
                .reconcileClock(requestRefresh: true),
                .rpcSuccess(call: 1, identity: .a, weekly: 91 + index),
                .awaitRPC(2),
                .clockAdvance(seconds: 1),
                .rpcSuccess(call: 2, identity: .b, weekly: weekly)
            ]
            let world = try ScenarioWorld(name: "fault-order-\(index)")
            await world.run(events)
            await world.assertFinalSnapshot(identity: .b, weekly: weekly, physicalRPCCalls: 2)
            await world.run([.terminate])
            world.assertSuccessorOwnsNamespace()
            await world.cleanup()
        }
    }

    func testCorruptionDuplicateExitAndRestartRecoverSettledWidgetAndSuccessorOwner() async throws {
        let world = try ScenarioWorld(name: "corrupt-restart")

        await world.run([
            .request(.manual, cancellation: .ignore),
            .awaitRPC(1),
            .rpcSuccess(call: 1, identity: .a, weekly: 64),
            .request(.manual, cancellation: .ignore),
            .awaitRPC(2),
            .rpcFailure(call: 2, failure: .transport),
            .reconcileClock(requestRefresh: false),
            .duplicateInstance,
            .terminate,
            .persistenceCorruption,
            .restart,
            .request(.manual, cancellation: .finishWhenTaskIsCancelled),
            .awaitRPC(3),
            .networkUnavailable,
            .rpcCancelled(call: 3)
        ])

        await world.assertFinalSnapshot(
            identity: .a,
            weekly: 64,
            status: .networkFailed,
            physicalRPCCalls: 3
        )
        world.assertSuccessorOwnsNamespace()
        await world.run([.terminate])
        await world.cleanup()
    }
}

private enum ScenarioIdentity: String, CustomStringConvertible {
    case a = "A"
    case b = "B"

    var boundary: QuotaAccountBoundary {
        switch self {
        case .a: return .testDefault
        case .b: return .testOtherAccount
        }
    }

    var description: String { rawValue }
}

private enum ScenarioRPCFailure: String, CustomStringConvertible {
    case transport
    case rejected

    var error: RealQuotaError {
        switch self {
        case .transport: return .transportFailed
        case .rejected: return .rpcRejected(code: -1)
        }
    }

    var description: String { rawValue }
}

private enum ScenarioRPCCancellationBehavior: String, Sendable, CustomStringConvertible {
    case ignore
    case finishWhenTaskIsCancelled

    var description: String { rawValue }
}

private enum ScenarioEvent: CustomStringConvertible {
    case request(AppState.RefreshTrigger, cancellation: ScenarioRPCCancellationBehavior)
    case networkUnavailable
    case networkRestored
    case sleep
    case wake
    case accountChange(ScenarioIdentity)
    case clockAdvance(seconds: TimeInterval)
    case reconcileClock(requestRefresh: Bool)
    case awaitRPC(Int)
    case rpcSuccess(call: Int, identity: ScenarioIdentity, weekly: Int)
    case rpcFailure(call: Int, failure: ScenarioRPCFailure)
    case rpcCancelled(call: Int)
    case persistenceCorruption
    case restart
    case duplicateInstance
    case terminate

    var description: String {
        switch self {
        case .request(let trigger, let cancellation):
            return "request(\(Self.triggerName(trigger)), cancellation=\(cancellation))"
        case .networkUnavailable:
            return "network(unavailable)"
        case .networkRestored:
            return "network(restored)"
        case .sleep:
            return "system(sleep)"
        case .wake:
            return "system(wake)"
        case .accountChange(let identity):
            return "account(\(identity))"
        case .clockAdvance(let seconds):
            return "clock(advance=\(seconds)s)"
        case .reconcileClock(let requestRefresh):
            return "clock(reconcile, requestRPC=\(requestRefresh))"
        case .awaitRPC(let call):
            return "rpc(await-start #\(call))"
        case .rpcSuccess(let call, let identity, let weekly):
            return "rpc(success #\(call), owner=\(identity), weekly=\(weekly))"
        case .rpcFailure(let call, let failure):
            return "rpc(failure #\(call), \(failure))"
        case .rpcCancelled(let call):
            return "rpc(cancel #\(call))"
        case .persistenceCorruption:
            return "persistence(corrupt-primary)"
        case .restart:
            return "process(restart)"
        case .duplicateInstance:
            return "instance(duplicate-claim)"
        case .terminate:
            return "process(terminate)"
        }
    }

    private static func triggerName(_ trigger: AppState.RefreshTrigger) -> String {
        switch trigger {
        case .manual: return "manual"
        case .scheduled: return "scheduled"
        case .wake: return "wake"
        case .networkRestored: return "network-restored"
        case .networkChanged: return "network-changed"
        case .temporalBoundary: return "temporal-boundary"
        case .systemClockChange: return "system-clock-change"
        case .accountBoundaryChanged: return "account-boundary-changed"
        }
    }
}

@MainActor
private final class ScenarioWorld {
    private static let snapshotKey = "scenario.snapshot"

    private let name: String
    private let suiteName: String
    private let defaults: UserDefaults
    private let snapshotStore: SnapshotStore
    private let namespaceURL: URL
    private let instanceConfiguration: SingleInstanceConfiguration
    private let boundary = ScenarioBoundaryBox(ScenarioIdentity.a.boundary)
    private let clock = ScenarioManualClock(now: Date(timeIntervalSince1970: 1_800_000_000))
    private let sleeper = ScenarioSleepGate()
    private let provider = ScenarioRPCProvider()
    private let widgetRecorder = ScenarioWidgetRecorder()
    private var ownerCoordinator: SingleInstanceCoordinator
    private var duplicateCoordinator: SingleInstanceCoordinator?
    private var scheduler: RefreshScheduler?
    private var appState: AppState?
    private var bridge: WidgetTimelineBridge?
    private var stateGate: ScenarioStateGate?
    private var expectedTrustedSnapshot: QuotaSnapshot?
    private var currentOwnerInstanceID: UUID
    private var ownershipGeneration = 1
    private var isTerminated = false
    private var trace: [String] = []

    init(name: String) throws {
        self.name = name
        suiteName = "CodexMonitorNativeTests.scenario.\(name).\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        snapshotStore = SnapshotStore(defaults: defaults, key: Self.snapshotKey)
        namespaceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexMonitorScenario-\(UUID().uuidString)", isDirectory: true)
        instanceConfiguration = SingleInstanceConfiguration(
            namespaceURL: namespaceURL,
            ownerReadyTimeout: .milliseconds(500),
            acknowledgementTimeout: .milliseconds(500),
            handoffCompletionTimeout: .milliseconds(500)
        )
        currentOwnerInstanceID = Self.instanceID(1)
        ownerCoordinator = SingleInstanceCoordinator(
            configuration: instanceConfiguration,
            instanceIDProvider: { Self.instanceID(1) }
        )

        let claim = ownerCoordinator.claim(using: .immediate { _ in true })
        guard claim == .owner else {
            throw ScenarioWorldError.initialOwnershipFailed(String(describing: claim))
        }
        startAppComponents()
    }

    func run(_ events: [ScenarioEvent]) async {
        for event in events {
            trace.append("\(trace.count + 1). \(event)")
            await apply(event)
            await assertStepInvariants(after: event)
        }
    }

    func assertFinalSnapshot(
        identity: ScenarioIdentity,
        weekly: Int,
        status: QuotaRefreshStatus = .success,
        physicalRPCCalls: Int
    ) async {
        guard let state = appState else {
            fail("final AppState is absent")
            return
        }
        assertEqual(state.snapshot.accountBoundary, identity.boundary, "final in-memory boundary")
        assertEqual(state.snapshot.weeklyQuotaPercent, weekly, "final in-memory weekly quota")
        assertEqual(state.status, status, "final in-memory status")

        let persisted = snapshotStore.loadState()
        assertEqual(persisted?.snapshot.accountBoundary, identity.boundary, "final persisted boundary")
        assertEqual(persisted?.snapshot.weeklyQuotaPercent, weekly, "final persisted weekly quota")
        assertEqual(persisted?.status, status, "final persisted status")

        let widget = widgetRecorder.lastState
        assertEqual(widget?.snapshot.accountBoundary, identity.boundary, "final Widget boundary")
        assertEqual(widget?.snapshot.weeklyQuotaPercent, weekly, "final Widget weekly quota")
        assertEqual(widget?.status, status, "final Widget status")

        let metrics = await provider.metrics()
        assertEqual(metrics.startedCallIDs, Array(1...physicalRPCCalls), "physical RPC call IDs")
        assertEqual(metrics.maximumConcurrency, 1, "physical RPC max concurrency")
    }

    func assertSuccessorOwnsNamespace() {
        assertTrue(ownershipGeneration >= 2, "a successor ownership generation exists")
        let record = ownerCoordinator.stableOwnerRecordHoldingLock()
        assertEqual(record?.instanceID, currentOwnerInstanceID, "successor holds the namespace lock")
    }

    func cleanup() async {
        if appState != nil {
            _ = stopAndReleaseAppComponents()
        }
        ownerCoordinator.release()
        duplicateCoordinator?.release()
        duplicateCoordinator = nil
        await provider.cancelAll()
        await sleeper.cancelAll()
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: namespaceURL)
    }

    private func apply(_ event: ScenarioEvent) async {
        switch event {
        case .request(let trigger, let cancellation):
            guard let scheduler else {
                fail("request received without a live scheduler")
                return
            }
            await provider.enqueueCancellationBehavior(cancellation)
            scheduler.requestRefresh(trigger)

        case .networkUnavailable:
            guard let scheduler, let state = appState else {
                fail("network-unavailable received without live components")
                return
            }
            scheduler.pause(for: .networkUnavailable)
            state.updateNetworkReachability(false)

        case .networkRestored:
            guard let scheduler, let state = appState else {
                fail("network-restored received without live components")
                return
            }
            state.updateNetworkReachability(true)
            scheduler.resume(for: .networkUnavailable)
            scheduler.requestRefresh(.networkRestored)

        case .sleep:
            guard let scheduler else {
                fail("sleep received without a live scheduler")
                return
            }
            scheduler.pause(for: .systemSleep)

        case .wake:
            guard let scheduler else {
                fail("wake received without a live scheduler")
                return
            }
            scheduler.resume(for: .systemSleep)
            scheduler.requestRefresh(.wake)

        case .accountChange(let identity):
            guard let state = appState else {
                fail("account change received without a live AppState")
                return
            }
            boundary.value = identity.boundary
            expectedTrustedSnapshot = nil
            state.accountBoundaryDidChange()

        case .clockAdvance(let seconds):
            clock.advance(by: seconds)

        case .reconcileClock(let requestRefresh):
            guard let scheduler, let state = appState else {
                fail("clock reconciliation received without live components")
                return
            }
            let reloadCountBefore = widgetRecorder.reloadCount
            state.reconcileTemporalState()
            assertEqual(
                widgetRecorder.reloadCount,
                reloadCountBefore + 1,
                "temporal reconciliation reloads the Widget timeline"
            )
            if requestRefresh {
                scheduler.requestRefresh(.systemClockChange)
            }

        case .awaitRPC(let call):
            await provider.waitForStart(call)

        case .rpcSuccess(let call, let identity, let weekly):
            let snapshot = QuotaSnapshot(
                weeklyQuotaPercent: weekly,
                fiveHourQuotaPercent: max(0, weekly - 5),
                refreshedAt: clock.now,
                dataSource: .real,
                accountBoundary: identity.boundary
            )
            let resumed = await provider.succeed(call: call, snapshot: snapshot)
            assertTrue(resumed, "RPC #\(call) had a pending success continuation")
            await provider.waitForCompletion(call)
            if identity.boundary.matches(boundary.value) {
                guard let stateGate else {
                    fail("matching RPC success has no state gate")
                    return
                }
                await stateGate.wait { event in
                    event.persistedState.snapshot == snapshot && event.persistedState.status == .success
                }
                expectedTrustedSnapshot = snapshot
            }

        case .rpcFailure(let call, let failure):
            let resumed = await provider.fail(call: call, error: failure.error)
            assertTrue(resumed, "RPC #\(call) had a pending failure continuation")
            await provider.waitForCompletion(call)
            if let stateGate {
                await stateGate.wait { $0.persistedState.status == failure.error.refreshStatus }
            }

        case .rpcCancelled(let call):
            await provider.waitForCompletion(call)
            let wasCancelledByTask = await provider.wasCancelledByTask(call)
            assertTrue(wasCancelledByTask, "RPC #\(call) completed through task cancellation")
            if let stateGate {
                await stateGate.wait { $0.persistedState.status == .networkFailed }
            }

        case .persistenceCorruption:
            defaults.set(Data("deterministic-corruption".utf8), forKey: Self.snapshotKey)

        case .restart:
            guard appState == nil, scheduler == nil else {
                fail("restart requires a terminated process")
                return
            }
            isTerminated = false
            startAppComponents()

        case .duplicateInstance:
            guard duplicateCoordinator == nil else {
                fail("only one duplicate claimant is supported per scenario")
                return
            }
            let duplicateID = Self.instanceID(2)
            let claimant = SingleInstanceCoordinator(
                configuration: instanceConfiguration,
                instanceIDProvider: { duplicateID }
            )
            let result = claimant.claim(using: .immediate { _ in true })
            assertEqual(result, .secondary(forwardedActivation: true), "duplicate remains secondary")
            duplicateCoordinator = claimant

        case .terminate:
            guard appState != nil else {
                fail("terminate requires a live process")
                return
            }
            let releasedState = stopAndReleaseAppComponents()
            assertTrue(releasedState.value == nil, "terminated AppState is reclaimable")

            ownerCoordinator.prepareForShutdown()
            ownerCoordinator.release()
            let successorID: UUID
            let successor: SingleInstanceCoordinator
            if let duplicateCoordinator {
                successorID = Self.instanceID(2)
                successor = duplicateCoordinator
                self.duplicateCoordinator = nil
            } else {
                successorID = Self.instanceID(3)
                successor = SingleInstanceCoordinator(
                    configuration: instanceConfiguration,
                    instanceIDProvider: { successorID }
                )
            }
            let result = successor.claim(using: .immediate { _ in true })
            assertEqual(result, .owner, "successor claims ownership after primary exit")
            ownerCoordinator = successor
            currentOwnerInstanceID = successorID
            ownershipGeneration += 1
            isTerminated = true
        }
    }

    private func startAppComponents() {
        let state = AppState(
            snapshotStore: snapshotStore,
            refreshService: provider,
            staleAfterInterval: 60 * 60,
            now: { [clock] in clock.now },
            sleep: { [sleeper] nanoseconds in
                try await sleeper.suspend(nanoseconds: nanoseconds)
            },
            initialNetworkReachability: true,
            accountBoundaryProvider: { [boundary] in boundary.value }
        )
        let scheduler = RefreshScheduler(clock: clock) { [weak state] trigger in
            guard let state else { return }
            await state.refreshNow(trigger: trigger)
        }
        state.onRefreshSchedulingStateChanged = { [weak scheduler] schedulingState in
            scheduler?.updateSchedule(with: schedulingState)
        }
        state.onRefreshRequested = { [weak scheduler] trigger in
            scheduler?.requestRefresh(trigger)
        }
        scheduler.updateSchedule(with: state.refreshSchedulingState)

        let bridge = WidgetTimelineBridge(
            appState: state,
            saveState: { [widgetRecorder] in widgetRecorder.save($0) },
            reloadTimelines: { [widgetRecorder] in widgetRecorder.reload() }
        )
        self.appState = state
        self.scheduler = scheduler
        self.bridge = bridge
        stateGate = ScenarioStateGate(appState: state)
        scheduler.start()
    }

    private func stopAndReleaseAppComponents() -> ScenarioWeakAppStateBox {
        guard let state = appState else { return ScenarioWeakAppStateBox(nil) }
        scheduler?.stop()
        state.shutdown()
        assertTrue(state.status != .refreshing, "shutdown publishes a settled AppState")
        assertTrue(!state.hasScheduledFreshnessTask, "shutdown clears AppState temporal work")
        assertTrue(scheduler?.hasActiveRefreshTask != true, "shutdown clears scheduler task")
        assertTrue(scheduler?.hasScheduledTimer != true, "shutdown clears scheduler timer")

        let releasedState = ScenarioWeakAppStateBox(state)
        state.onRefreshRequested = nil
        state.onRefreshSchedulingStateChanged = nil
        bridge = nil
        stateGate = nil
        appState = nil
        scheduler = nil
        return releasedState
    }

    private func assertStepInvariants(after event: ScenarioEvent) async {
        let metrics = await provider.metrics()
        assertTrue(
            metrics.maximumConcurrency <= 1,
            "provider remains physical single-flight after \(event)"
        )
        assertEqual(
            Set(metrics.startedCallIDs).count,
            metrics.startedCallIDs.count,
            "physical RPC IDs are unique after \(event)"
        )
        assertTrue(
            widgetRecorder.savedStates.allSatisfy { $0.status != .refreshing },
            "Widget never persists refreshing after \(event)"
        )

        if let state = appState {
            assertBoundary(state.snapshot, source: "in-memory AppState after \(event)")
            if let expectedTrustedSnapshot, state.snapshot.dataSource == .real {
                assertEqual(
                    state.snapshot,
                    expectedTrustedSnapshot,
                    "old RPC cannot overwrite trusted in-memory state after \(event)"
                )
            }
        } else {
            assertTrue(isTerminated, "AppState is absent only after termination")
        }

        if let persisted = snapshotStore.loadState() {
            assertBoundary(persisted.snapshot, source: "SnapshotStore after \(event)")
            if let expectedTrustedSnapshot, persisted.snapshot.dataSource == .real {
                assertEqual(
                    persisted.snapshot,
                    expectedTrustedSnapshot,
                    "old RPC cannot overwrite trusted persistence after \(event)"
                )
            }
        }

        if let widget = widgetRecorder.lastState {
            assertBoundary(widget.snapshot, source: "Widget after \(event)")
            if let expectedTrustedSnapshot, widget.snapshot.dataSource == .real {
                assertEqual(
                    widget.snapshot,
                    expectedTrustedSnapshot,
                    "old RPC cannot overwrite trusted Widget state after \(event)"
                )
            }
        }

        if isTerminated {
            assertTrue(scheduler == nil, "terminated world retains no scheduler")
            assertTrue(appState == nil, "terminated world retains no AppState")
        }

        let owner = ownerCoordinator.stableOwnerRecordHoldingLock()
        assertEqual(owner?.instanceID, currentOwnerInstanceID, "one verified owner remains after \(event)")
    }

    private func assertBoundary(_ snapshot: QuotaSnapshot, source: String) {
        guard snapshot.dataSource == .real else { return }
        assertTrue(
            snapshot.accountBoundary?.matches(boundary.value) == true,
            "\(source) matches current identity"
        )
    }

    private func assertTrue(
        _ condition: @autoclosure () -> Bool,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(condition(), "\(message)\n\(traceDescription)", file: file, line: line)
    }

    private func assertEqual<T: Equatable>(
        _ actual: @autoclosure () -> T,
        _ expected: @autoclosure () -> T,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual(), expected(), "\(message)\n\(traceDescription)", file: file, line: line)
    }

    private func fail(
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTFail("\(message)\n\(traceDescription)", file: file, line: line)
    }

    private var traceDescription: String {
        "Scenario \(name) trace:\n" + (trace.isEmpty ? "<empty>" : trace.joined(separator: "\n"))
    }

    nonisolated private static func instanceID(_ value: UInt8) -> UUID {
        UUID(uuid: (
            0, 0, 0, 0,
            0, 0,
            0, 0,
            0, 0,
            0, 0, 0, 0, 0, value
        ))
    }
}

private enum ScenarioWorldError: Error {
    case initialOwnershipFailed(String)
}

@MainActor
private final class ScenarioBoundaryBox {
    var value: QuotaAccountBoundary

    init(_ value: QuotaAccountBoundary) {
        self.value = value
    }
}

@MainActor
private final class ScenarioWeakAppStateBox {
    weak var value: AppState?

    init(_ value: AppState?) {
        self.value = value
    }
}

@MainActor
private final class ScenarioWidgetRecorder {
    private(set) var savedStates: [WidgetDisplayState] = []
    private(set) var reloadCount = 0

    var lastState: WidgetDisplayState? { savedStates.last }

    func save(_ state: WidgetDisplayState) {
        savedStates.append(state)
    }

    func reload() {
        reloadCount += 1
    }
}

@MainActor
private final class ScenarioStateGate {
    private struct Waiter {
        let predicate: @MainActor (AppStateEvent) -> Bool
        let continuation: CheckedContinuation<Void, Never>
    }

    private var latestEvent: AppStateEvent
    private var waiters: [UUID: Waiter] = [:]
    private var cancellable: AnyCancellable?

    init(appState: AppState) {
        latestEvent = appState.stateEvent
        cancellable = appState.$stateEvent.sink { [weak self] event in
            self?.receive(event)
        }
    }

    func wait(until predicate: @escaping @MainActor (AppStateEvent) -> Bool) async {
        if predicate(latestEvent) { return }
        let id = UUID()
        await withCheckedContinuation { continuation in
            waiters[id] = Waiter(predicate: predicate, continuation: continuation)
        }
    }

    private func receive(_ event: AppStateEvent) {
        latestEvent = event
        let ready = waiters.filter { $0.value.predicate(event) }
        for (id, waiter) in ready {
            waiters.removeValue(forKey: id)
            waiter.continuation.resume()
        }
    }
}

@MainActor
private final class ScenarioManualClock: RefreshSchedulerClock {
    private struct ScheduledAction {
        let deadline: Date
        let action: @MainActor () -> Void
    }

    var now: Date
    private var scheduledAction: ScheduledAction?

    var hasScheduledAction: Bool { scheduledAction != nil }

    init(now: Date) {
        self.now = now
    }

    func schedule(at date: Date, action: @escaping @MainActor () -> Void) {
        scheduledAction = ScheduledAction(deadline: date, action: action)
    }

    func cancelScheduledAction() {
        scheduledAction = nil
    }

    func advance(by interval: TimeInterval) {
        precondition(interval >= 0)
        now = now.addingTimeInterval(interval)
        while let action = scheduledAction, action.deadline <= now {
            scheduledAction = nil
            action.action()
        }
    }
}

private actor ScenarioSleepGate {
    private var continuations: [UUID: CheckedContinuation<Void, Error>] = [:]

    func suspend(nanoseconds: UInt64) async throws {
        _ = nanoseconds
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                continuations[id] = continuation
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    func cancelAll() {
        let pending = continuations.values
        continuations.removeAll()
        pending.forEach { $0.resume(throwing: CancellationError()) }
    }

    private func cancel(_ id: UUID) {
        continuations.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }
}

private actor ScenarioRPCProvider: QuotaRefreshing {
    struct Metrics: Sendable {
        let startedCallIDs: [Int]
        let maximumConcurrency: Int
    }

    private struct PendingCall {
        let continuation: CheckedContinuation<QuotaSnapshot, Error>
    }

    private var nextCallID = 1
    private var activeCalls = 0
    private var maximumActiveCalls = 0
    private var startedCallIDs: [Int] = []
    private var completedCallIDs: Set<Int> = []
    private var taskCancelledCallIDs: Set<Int> = []
    private var pendingCalls: [Int: PendingCall] = [:]
    private var startWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private var completionWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private var cancellationBehaviors: [ScenarioRPCCancellationBehavior] = []

    func refresh(basedOn currentSnapshot: QuotaSnapshot) async throws -> QuotaSnapshot {
        _ = currentSnapshot
        let callID = nextCallID
        nextCallID += 1
        let cancellationBehavior = cancellationBehaviors.isEmpty
            ? ScenarioRPCCancellationBehavior.ignore
            : cancellationBehaviors.removeFirst()
        activeCalls += 1
        maximumActiveCalls = max(maximumActiveCalls, activeCalls)

        do {
            let snapshot = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    pendingCalls[callID] = PendingCall(continuation: continuation)
                    startedCallIDs.append(callID)
                    resumeStartWaiters(through: callID)
                }
            } onCancel: {
                guard cancellationBehavior == .finishWhenTaskIsCancelled else { return }
                Task { await self.cancelFromTask(callID) }
            }
            finish(callID)
            return snapshot
        } catch {
            finish(callID)
            throw error
        }
    }

    func enqueueCancellationBehavior(_ behavior: ScenarioRPCCancellationBehavior) {
        cancellationBehaviors.append(behavior)
    }

    func waitForStart(_ callID: Int) async {
        guard !startedCallIDs.contains(callID) else { return }
        await withCheckedContinuation { continuation in
            startWaiters[callID, default: []].append(continuation)
        }
    }

    func waitForCompletion(_ callID: Int) async {
        guard !completedCallIDs.contains(callID) else { return }
        await withCheckedContinuation { continuation in
            completionWaiters[callID, default: []].append(continuation)
        }
    }

    @discardableResult
    func succeed(call callID: Int, snapshot: QuotaSnapshot) -> Bool {
        guard let call = pendingCalls.removeValue(forKey: callID) else { return false }
        call.continuation.resume(returning: snapshot)
        return true
    }

    @discardableResult
    func fail(call callID: Int, error: any Error) -> Bool {
        guard let call = pendingCalls.removeValue(forKey: callID) else { return false }
        call.continuation.resume(throwing: error)
        return true
    }

    func metrics() -> Metrics {
        Metrics(
            startedCallIDs: startedCallIDs,
            maximumConcurrency: maximumActiveCalls
        )
    }

    func wasCancelledByTask(_ callID: Int) -> Bool {
        taskCancelledCallIDs.contains(callID)
    }

    func cancelAll() {
        let calls = pendingCalls.values
        pendingCalls.removeAll()
        calls.forEach { $0.continuation.resume(throwing: CancellationError()) }
    }

    private func cancelFromTask(_ callID: Int) {
        guard let call = pendingCalls.removeValue(forKey: callID) else { return }
        taskCancelledCallIDs.insert(callID)
        call.continuation.resume(throwing: CancellationError())
    }

    private func finish(_ callID: Int) {
        activeCalls -= 1
        completedCallIDs.insert(callID)
        let pending = completionWaiters.removeValue(forKey: callID) ?? []
        pending.forEach { $0.resume() }
    }

    private func resumeStartWaiters(through callID: Int) {
        let readyIDs = startWaiters.keys.filter { $0 <= callID }
        for id in readyIDs {
            let pending = startWaiters.removeValue(forKey: id) ?? []
            pending.forEach { $0.resume() }
        }
    }
}
