import Foundation
import Synchronization
import XCTest
import WalletDomain
import WalletRuntimeTestSupport
@testable import WalletNetworking

private final class SafariRPCServiceProbe: Sendable {
    private struct State {
        var started = [Int]()
        var cancelledOnExit = [Int: Bool]()
    }

    private let state = Mutex(State())
    private let gates: [Int: TestGate<Void>]
    private let dispatches: Bool

    init(blocking ids: [Int] = [], dispatches: Bool = false) {
        gates = Dictionary(uniqueKeysWithValues: ids.map { ($0, TestGate<Void>()) })
        self.dispatches = dispatches
    }

    var started: [Int] { state.withLock { $0.started } }
    var cancelledOnExit: [Int: Bool] { state.withLock { $0.cancelledOnExit } }

    func run(_ request: ValidatedRPCRequest, _ execution: SafariRPCExecution) async throws -> RPCResponseToExtension {
        if dispatches { try execution.markDispatched() }
        state.withLock { $0.started.append(request.id) }
        if let gate = gates[request.id] { await gate.wait() }
        state.withLock { $0.cancelledOnExit[request.id] = Task.isCancelled }
        return RPCResponseToExtension(upstream: ["id": request.id, "result": "result-\(request.id)"], expectedResponseID: request.id)!
    }

    func release(_ id: Int) { gates[id]?.resolve(()) }
    func releaseAll() { gates.values.forEach { $0.resolve(()) } }
}

@MainActor
final class SafariRPCServiceTests: XCTestCase {
    func testGlobalAndPerOriginActiveLimitsAllowOtherOriginsToProgress() async {
        let service = makeService(limits: limits(active: 2, activePerOrigin: 1))
        let probe = SafariRPCServiceProbe(blocking: [1, 2, 3, 4])
        defer { probe.releaseAll() }
        let first = start(service, id: 1, scope: scope("a"), probe: probe)
        await expectEventually { probe.started == [1] }
        let sameOrigin = start(service, id: 2, scope: scope("a"), probe: probe)
        await expectOutstanding(2, in: service)
        let otherOrigin = start(service, id: 3, scope: scope("b"), probe: probe)
        await expectEventually { probe.started == [1, 3] }
        let globallyQueued = start(service, id: 4, scope: scope("c"), probe: probe)
        await expectOutstanding(4, in: service)

        let full = await service.statistics
        XCTAssertEqual(full.activeRequests, 2)
        XCTAssertEqual(full.scopeCount, 3)
        XCTAssertEqual(probe.started, [1, 3])

        probe.release(3)
        assertSuccess(await otherOrigin.value, id: 3)
        await expectEventually { probe.started == [1, 3, 4] }
        probe.release(1)
        assertSuccess(await first.value, id: 1)
        await expectEventually { probe.started == [1, 3, 4, 2] }
        probe.releaseAll()
        assertSuccess(await sameOrigin.value, id: 2)
        assertSuccess(await globallyQueued.value, id: 4)
        await assertDrained(service)
    }

    func testOriginQuotaIsPartitionedBySafariProfile() async {
        let service = makeService(limits: limits(active: 3, activePerOrigin: 1, outstandingPerOrigin: 1))
        let probe = SafariRPCServiceProbe(blocking: [1, 2, 3])
        defer { probe.releaseAll() }
        let profiles: [UUID?] = [nil, UUID(), UUID()]
        var tasks = [Task<RPCResponseToExtension, Never>]()
        for (index, profile) in profiles.enumerated() {
            tasks.append(start(service, id: index + 1, scope: scope("same", profile: profile), probe: probe))
            await expectEventually { probe.started.count == index + 1 }
        }

        let full = await service.statistics
        XCTAssertEqual(full.activeRequests, 3)
        XCTAssertEqual(full.scopeCount, 3)
        let duplicate = await service.perform(id: 4, body: Self.body(4), scope: scope("same", profile: profiles[1]), operation: probe.run)
        assertFailure(duplicate, id: 4, reason: "busy", code: -32_005)
        XCTAssertEqual(probe.started, [1, 2, 3])

        probe.releaseAll()
        for (index, task) in tasks.enumerated() { assertSuccess(await task.value, id: index + 1) }
        await assertDrained(service)
    }

    func testOutstandingLimitsRejectBeforeParsingWithoutLeakingScopes() async {
        let service = makeService(limits: limits(active: 1, outstanding: 3, outstandingPerOrigin: 2))
        let probe = SafariRPCServiceProbe(blocking: [1, 2, 4])
        defer { probe.releaseAll() }
        let first = start(service, id: 1, scope: scope("a"), probe: probe)
        await expectEventually { probe.started == [1] }
        let sameOrigin = start(service, id: 2, scope: scope("a"), probe: probe)
        await expectOutstanding(2, in: service)

        let originOverflow = await service.perform(id: 3, body: "{", scope: scope("a"), operation: probe.run)
        assertFailure(originOverflow, id: 3, reason: "busy", code: -32_005)
        let otherOrigin = start(service, id: 4, scope: scope("b"), probe: probe)
        await expectOutstanding(3, in: service)
        let globalOverflow = await service.perform(id: 5, body: "{", scope: scope("rejected"), operation: probe.run)
        assertFailure(globalOverflow, id: 5, reason: "busy", code: -32_005)
        let full = await service.statistics
        XCTAssertEqual(full.scopeCount, 2)
        XCTAssertEqual(full.outstandingRequests, 3)
        XCTAssertEqual(full.retainedRequestBytes, Self.body(1).utf8.count * 2 + Self.body(2).utf8.count + Self.body(4).utf8.count)
        XCTAssertEqual(probe.started, [1])

        probe.releaseAll()
        assertSuccess(await first.value, id: 1)
        assertSuccess(await sameOrigin.value, id: 2)
        assertSuccess(await otherOrigin.value, id: 4)
        await assertDrained(service)
        assertSuccess(await service.perform(id: 6, body: Self.body(6), scope: scope("rejected"), operation: probe.run), id: 6)
        await assertDrained(service)
    }

    func testRequestSizeLimitCountsUTF8BytesBeforeParsing() async {
        var configured = limits()
        configured.maximumRequestBytes = 7
        let service = makeService(limits: configured)
        let probe = SafariRPCServiceProbe()
        let response = await service.perform(id: 1, body: "🦊🦊", scope: scope("a"), operation: probe.run)

        assertFailure(response, id: 1, reason: "request_too_large", code: -32_005)
        XCTAssertTrue(probe.started.isEmpty)
        await assertDrained(service)
    }

    func testAggregateRequestBytesRejectBeforeParsingAndAreReleasedOnCancellation() async {
        var configured = limits(active: 1)
        configured.maximumRetainedRequestBytes = Self.body(1).utf8.count * 2 + Self.body(2).utf8.count
        let service = makeService(limits: configured)
        let probe = SafariRPCServiceProbe(blocking: [1])
        defer { probe.releaseAll() }
        let first = start(service, id: 1, scope: scope("a"), probe: probe)
        await expectEventually { probe.started == [1] }
        let queued = start(service, id: 2, scope: scope("b"), probe: probe)
        await expectOutstanding(2, in: service)

        let response = await service.perform(id: 3, body: "{", scope: scope("rejected"), operation: probe.run)
        assertFailure(response, id: 3, reason: "busy", code: -32_005)
        queued.cancel()
        assertFailure(await queued.value, id: 2, reason: "cancelled", code: -32_603)
        let remaining = await service.statistics
        XCTAssertEqual(remaining.retainedRequestBytes, Self.body(1).utf8.count * 2)
        XCTAssertEqual(remaining.scopeCount, 1)

        let replacement = start(service, id: 4, scope: scope("rejected"), probe: probe)
        await expectOutstanding(2, in: service)
        probe.release(1)
        assertSuccess(await first.value, id: 1)
        assertSuccess(await replacement.value, id: 4)
        XCTAssertEqual(probe.started, [1, 4])
        await assertDrained(service)
    }

    func testRequestComplexityLimitRejectsBeforeSerializationAndReleasesCapacity() async {
        var configured = limits(active: 1, outstanding: 1)
        configured.maximumRequestTokens = 12
        let serializerCalls = Mutex(0)
        let service = makeService(limits: configured, serializeRequest: { prepared in
            serializerCalls.withLock { $0 += 1 }
            return try prepared.serialize()
        })
        let probe = SafariRPCServiceProbe(dispatches: true)
        let body = #"{"jsonrpc":"2.0","id":1,"method":"vendor_method","params":[0,0,0,0]}"#

        let response = await service.perform(id: 1, body: body, scope: scope("a"), operation: probe.run)

        assertFailure(response, id: 1, reason: "request_too_large", code: -32_005)
        XCTAssertEqual(serializerCalls.withLock { $0 }, 0)
        XCTAssertTrue(probe.started.isEmpty)
        await assertDrained(service)
        assertSuccess(await service.perform(id: 2, body: Self.body(2), scope: scope("a"), operation: probe.run), id: 2)
        XCTAssertEqual(serializerCalls.withLock { $0 }, 1)
        XCTAssertEqual(probe.started, [2])
        await assertDrained(service)
    }

    func testCanonicalExpansionMustFitAggregateBudgetBeforeOperation() async throws {
        let body = #"{"jsonrpc":"2.0","id":1,"method":"vendor_method","params":["////////"]}"#
        let rawBytes = body.utf8.count
        let canonicalBytes = try ValidatedRPCRequest.prepare(body: body, id: 1).canonicalByteCount
        XCTAssertGreaterThan(canonicalBytes, rawBytes)
        var configured = limits()
        configured.maximumRetainedRequestBytes = rawBytes + canonicalBytes - 1
        let service = makeService(limits: configured)
        let probe = SafariRPCServiceProbe(dispatches: true)

        let response = await service.perform(id: 1, body: body, scope: scope("a"), operation: probe.run)

        assertFailure(response, id: 1, reason: "busy", code: -32_005)
        XCTAssertTrue(probe.started.isEmpty)
        await assertDrained(service)
    }

    func testExactCombinedBodyBudgetIsRetainedAndReusedAfterCompletion() async throws {
        let body = #"{"jsonrpc":"2.0","id":1,"method":"vendor_method","params":["////////"]}"#
        let canonicalBytes = try ValidatedRPCRequest.prepare(body: body, id: 1).canonicalByteCount
        var configured = limits()
        configured.maximumRetainedRequestBytes = body.utf8.count + canonicalBytes
        let service = makeService(limits: configured)
        let probe = SafariRPCServiceProbe(blocking: [1], dispatches: true)
        defer { probe.releaseAll() }
        let first = start(service, id: 1, body: body, scope: scope("a"), probe: probe)
        await expectEventually { probe.started == [1] }
        let full = await service.statistics
        XCTAssertEqual(full.activeRequests, 1)
        XCTAssertEqual(full.outstandingRequests, 1)
        XCTAssertEqual(full.retainedRequestBytes, configured.maximumRetainedRequestBytes)

        let overflow = await service.perform(id: 2, body: Self.body(2), scope: scope("b"), operation: probe.run)
        assertFailure(overflow, id: 2, reason: "busy", code: -32_005)
        let unchanged = await service.statistics
        XCTAssertEqual(unchanged, full)

        probe.release(1)
        assertSuccess(await first.value, id: 1)
        await assertDrained(service)
        assertSuccess(await service.perform(id: 1, body: body, scope: scope("a"), operation: probe.run), id: 1)
        XCTAssertEqual(probe.started, [1, 1])
        await assertDrained(service)
    }

    func testCanonicalCapacityIsReservedBeforeSerializationAndCannotBeShared() async throws {
        let body = #"{"jsonrpc":"2.0","id":1,"method":"vendor_method","params":["////////"]}"#
        let reservedBytes = body.utf8.count + (try ValidatedRPCRequest.prepare(body: body, id: 1).canonicalByteCount)
        var configured = limits(active: 2)
        configured.maximumRetainedRequestBytes = reservedBytes + Self.body(2).utf8.count
        let serialize = TestGate<Void>()
        let serializerCalls = Mutex(0)
        defer { serialize.resolve(()) }
        let service = makeService(limits: configured, serializeRequest: { prepared in
            let invocation = serializerCalls.withLock { $0 += 1; return $0 }
            if invocation == 1 { await serialize.wait() }
            return try prepared.serialize()
        })
        let probe = SafariRPCServiceProbe(dispatches: true)
        let first = start(service, id: 1, body: body, scope: scope("a"), probe: probe)
        await expectEventually { serializerCalls.withLock { $0 } == 1 }

        let reserved = await service.statistics
        XCTAssertEqual(reserved.retainedRequestBytes, reservedBytes)
        XCTAssertEqual(reserved.activeRequests, 1)
        XCTAssertTrue(probe.started.isEmpty)

        let second = await service.perform(id: 2, body: Self.body(2), scope: scope("b"), operation: probe.run)
        assertFailure(second, id: 2, reason: "busy", code: -32_005)
        XCTAssertEqual(serializerCalls.withLock { $0 }, 1)
        XCTAssertTrue(probe.started.isEmpty)
        let unchanged = await service.statistics
        XCTAssertEqual(unchanged, reserved)

        serialize.resolve(())
        assertSuccess(await first.value, id: 1)
        await assertDrained(service)
        assertSuccess(await service.perform(id: 2, body: Self.body(2), scope: scope("b"), operation: probe.run), id: 2)
        XCTAssertEqual(serializerCalls.withLock { $0 }, 2)
        await assertDrained(service)
    }

    func testCancellationRetainsCanonicalReservationUntilSerializerExits() async throws {
        let body = Self.body(1)
        var configured = limits()
        configured.maximumRetainedRequestBytes = body.utf8.count + (try ValidatedRPCRequest.prepare(body: body, id: 1).canonicalByteCount)
        let serialize = TestGate<Void>()
        let serializerCalls = Mutex(0)
        let serializerWasCancelled = Mutex(false)
        defer { serialize.resolve(()) }
        let service = makeService(limits: configured, serializeRequest: { prepared in
            let invocation = serializerCalls.withLock { $0 += 1; return $0 }
            if invocation == 1 {
                await serialize.wait()
                serializerWasCancelled.withLock { $0 = Task.isCancelled }
            }
            return try prepared.serialize()
        })
        let probe = SafariRPCServiceProbe(dispatches: true)
        let first = start(service, id: 1, body: body, scope: scope("a"), probe: probe)
        await expectEventually { serializerCalls.withLock { $0 } == 1 }
        let reserved = await service.statistics
        XCTAssertEqual(reserved.retainedRequestBytes, configured.maximumRetainedRequestBytes)

        first.cancel()
        assertFailure(await first.value, id: 1, reason: "cancelled", code: -32_603)
        let cancelled = await service.statistics
        XCTAssertEqual(cancelled, reserved)
        let overflow = await service.perform(id: 2, body: Self.body(2), scope: scope("b"), operation: probe.run)
        assertFailure(overflow, id: 2, reason: "busy", code: -32_005)
        XCTAssertTrue(probe.started.isEmpty)

        serialize.resolve(())
        await assertDrained(service)
        XCTAssertTrue(serializerWasCancelled.withLock { $0 })
        XCTAssertTrue(probe.started.isEmpty)
    }

    func testQueuedOriginsReceiveRoundRobinProgress() async {
        let service = makeService(limits: limits(active: 1, activePerOrigin: 1))
        let probe = SafariRPCServiceProbe(blocking: Array(1...6))
        defer { probe.releaseAll() }
        let origins = ["a", "a", "a", "b", "b", "c"]
        var tasks = [Int: Task<RPCResponseToExtension, Never>]()
        for id in 1...6 {
            tasks[id] = start(service, id: id, scope: scope(origins[id - 1]), probe: probe)
            await expectOutstanding(id, in: service)
        }
        await expectEventually { probe.started == [1] }

        let order = [1, 2, 4, 6, 3, 5]
        for (index, id) in order.enumerated() {
            await expectEventually { probe.started == Array(order.prefix(index + 1)) }
            probe.release(id)
            assertSuccess(await tasks[id]!.value, id: id)
        }
        await assertDrained(service)
    }

    func testQueuedCancellationAndExpiryNeverInvokeOperation() async {
        let clock = TestClock()
        var configured = limits(active: 1)
        configured.maximumQueueWait = .seconds(5)
        let service = makeService(limits: configured, clock: clock)
        let probe = SafariRPCServiceProbe(blocking: [1])
        defer { probe.releaseAll() }
        let first = start(service, id: 1, scope: scope("a"), probe: probe)
        await expectEventually { probe.started == [1] }
        let cancelled = start(service, id: 2, scope: scope("cancelled"), probe: probe)
        await expectOutstanding(2, in: service)
        cancelled.cancel()
        assertFailure(await cancelled.value, id: 2, reason: "cancelled", code: -32_603)
        let expiring = start(service, id: 3, scope: scope("expiring"), probe: probe)
        await expectOutstanding(2, in: service)

        clock.advance(by: 5_000_000_000)
        assertFailure(await expiring.value, id: 3, reason: "queue_timeout", code: -32_603)
        let remaining = await service.statistics
        XCTAssertEqual(remaining.activeRequests, 1)
        XCTAssertEqual(remaining.outstandingRequests, 1)
        XCTAssertEqual(remaining.scopeCount, 1)
        XCTAssertEqual(remaining.retainedRequestBytes, Self.body(1).utf8.count * 2)
        XCTAssertEqual(probe.started, [1])

        probe.release(1)
        assertSuccess(await first.value, id: 1)
        await assertDrained(service)
        assertSuccess(await service.perform(id: 4, body: Self.body(4), scope: scope("expiring"), operation: probe.run), id: 4)
        await assertDrained(service)
    }

    func testActiveCancellationRetainsCapacityUntilUncooperativeOperationExits() async {
        for dispatches in [false, true] {
            let service = makeService(limits: limits(active: 1, outstanding: 1))
            let probe = SafariRPCServiceProbe(blocking: [1], dispatches: dispatches)
            defer { probe.releaseAll() }
            let first = start(service, id: 1, scope: scope("a"), probe: probe)
            await expectEventually { probe.started == [1] }

            first.cancel()
            let cancelled = await first.value
            assertFailure(cancelled, id: 1, reason: "cancelled", code: -32_603, dispatched: dispatches)
            await assertRetainedActiveRequest(service, id: 1)
            let overflow = await service.perform(id: 2, body: Self.body(2), scope: scope("b"), operation: probe.run)
            assertFailure(overflow, id: 2, reason: "busy", code: -32_005)

            probe.release(1)
            await assertDrained(service)
            XCTAssertEqual(probe.cancelledOnExit[1], true)
            assertFailure(await first.value, id: 1, reason: "cancelled", code: -32_603, dispatched: dispatches)
            assertSuccess(await service.perform(id: 3, body: Self.body(3), scope: scope("b"), operation: probe.run), id: 3)
            XCTAssertEqual(probe.started, [1, 3])
            await assertDrained(service)
        }
    }

    func testLifetimeTimeoutRetainsCapacityAndDiscardsLateSuccess() async {
        let clock = TestClock()
        var configured = limits(active: 1, outstanding: 1)
        configured.maximumLifetime = .seconds(5)
        let service = makeService(limits: configured, clock: clock)
        let probe = SafariRPCServiceProbe(blocking: [1], dispatches: true)
        defer { probe.releaseAll() }
        let first = start(service, id: 1, scope: scope("a"), probe: probe)
        await expectEventually { probe.started == [1] }

        clock.advance(by: 5_000_000_000)
        assertFailure(await first.value, id: 1, reason: "timeout", code: -32_603, dispatched: true)
        await assertRetainedActiveRequest(service, id: 1)
        let overflow = await service.perform(id: 2, body: Self.body(2), scope: scope("b"), operation: probe.run)
        assertFailure(overflow, id: 2, reason: "busy", code: -32_005)

        probe.release(1)
        await assertDrained(service)
        XCTAssertEqual(probe.cancelledOnExit[1], true)
        assertFailure(await first.value, id: 1, reason: "timeout", code: -32_603, dispatched: true)
        assertSuccess(await service.perform(id: 3, body: Self.body(3), scope: scope("b"), operation: probe.run), id: 3)
        XCTAssertEqual(probe.started, [1, 3])
        await assertDrained(service)
    }

    func testLifetimeIncludesTimeSpentWaitingForAnActiveSlot() async {
        let clock = TestClock()
        var configured = limits(active: 1)
        configured.maximumQueueWait = .seconds(20)
        configured.maximumLifetime = .seconds(10)
        let service = makeService(limits: configured, clock: clock)
        let probe = SafariRPCServiceProbe(blocking: [1, 2])
        defer { probe.releaseAll() }
        let first = start(service, id: 1, scope: scope("a"), probe: probe)
        await expectEventually { probe.started == [1] }
        let queued = start(service, id: 2, scope: scope("b"), probe: probe)
        await expectOutstanding(2, in: service)

        clock.advance(by: 4_000_000_000)
        probe.release(1)
        assertSuccess(await first.value, id: 1)
        await expectEventually { probe.started == [1, 2] }
        clock.advance(by: 6_000_000_000)

        assertFailure(await queued.value, id: 2, reason: "timeout", code: -32_603)
        await assertRetainedActiveRequest(service, id: 2)
        probe.release(2)
        await assertDrained(service)
        XCTAssertEqual(probe.cancelledOnExit[2], true)
    }

    func testCancellationBeforeAdmissionNeverInvokesOperationOrRetainsCapacity() async {
        let service = makeService(limits: limits())
        let probe = SafariRPCServiceProbe()
        let admit = TestGate<Void>()
        let requestScope = scope("a")
        let task = Task {
            await admit.wait()
            return await service.perform(id: 1, body: Self.body(1), scope: requestScope, operation: probe.run)
        }
        task.cancel()
        admit.resolve(())

        assertFailure(await task.value, id: 1, reason: "cancelled", code: -32_603)
        XCTAssertTrue(probe.started.isEmpty)
        await assertDrained(service)
    }

    func testMalformedAndProhibitedRequestsNeverSerializeOrInvokeOperation() async {
        let serializerCalls = Mutex(0)
        let service = makeService(limits: limits(), serializeRequest: { prepared in
            serializerCalls.withLock { $0 += 1 }
            return try prepared.serialize()
        })
        let probe = SafariRPCServiceProbe()
        let inputs: [(String, String, Int)] = [
            ("{", "invalid_json", -32_700),
            ("[]", "invalid_request", -32_600),
            (Self.body(2), "invalid_request", -32_600),
            (Self.body(1, method: "eth_sign"), "prohibited_method", 4_200),
            (Self.body(1, method: "personal_unlockAccount"), "prohibited_method", 4_200),
        ]
        for (body, reason, code) in inputs {
            let response = await service.perform(id: 1, body: body, scope: scope("a"), operation: probe.run)
            assertFailure(response, id: 1, reason: reason, code: code)
            await assertDrained(service)
            XCTAssertEqual(serializerCalls.withLock { $0 }, 0)
        }

        XCTAssertTrue(probe.started.isEmpty)
        assertSuccess(await service.perform(id: 1, body: Self.body(1), scope: scope("a"), operation: probe.run), id: 1)
        XCTAssertEqual(serializerCalls.withLock { $0 }, 1)
        XCTAssertEqual(probe.started, [1])
        await assertDrained(service)
    }

    private func limits(active: Int = 2, activePerOrigin: Int = 1, outstanding: Int = 16, outstandingPerOrigin: Int = 8) -> SafariRPCLimits {
        SafariRPCLimits(
            maximumActivePerOrigin: activePerOrigin,
            maximumActiveRequests: active,
            maximumOutstandingPerOrigin: outstandingPerOrigin,
            maximumOutstandingRequests: outstanding,
            maximumQueueWait: .seconds(500),
            maximumLifetime: .seconds(1_000)
        )
    }

    private func makeService(
        limits: SafariRPCLimits, clock: TestClock = TestClock(),
        serializeRequest: @escaping SafariRPCService.Serializer = { try $0.serialize() }
    ) -> SafariRPCService {
        let anchor = clock.instant
        let uptime = clock.uptimeNanoseconds
        return SafariRPCService(limits: limits, clock: .init(now: { clock.instant }, sleepUntil: { deadline in
            let duration = anchor.duration(to: deadline).components
            let nanoseconds = UInt64(duration.seconds) * 1_000_000_000 + UInt64(duration.attoseconds / 1_000_000_000)
            try await clock.sleep(until: uptime + nanoseconds)
        }), serializeRequest: serializeRequest)
    }

    private func scope(_ origin: String, profile: UUID? = nil) -> RPCScope {
        .init(profileIdentifier: profile, origin: "https://\(origin).example")
    }

    private nonisolated static func body(_ id: Int, method: String = "eth_blockNumber") -> String {
        "{\"jsonrpc\":\"2.0\",\"id\":\(id),\"method\":\"\(method)\",\"params\":[]}"
    }

    private func start(_ service: SafariRPCService, id: Int, body: String? = nil, scope: RPCScope, probe: SafariRPCServiceProbe) -> Task<RPCResponseToExtension, Never> {
        let task = Task { await service.perform(id: id, body: body ?? Self.body(id), scope: scope, operation: probe.run) }
        addTeardownBlock {
            task.cancel()
            probe.releaseAll()
        }
        return task
    }

    private func expectOutstanding(_ count: Int, in service: SafariRPCService, file: StaticString = #filePath, line: UInt = #line) async {
        await expectEventually(file: file, line: line) { await service.statistics.outstandingRequests == count }
    }

    private func assertDrained(_ service: SafariRPCService, file: StaticString = #filePath, line: UInt = #line) async {
        let empty = SafariRPCService.Statistics(activeRequests: 0, outstandingRequests: 0, retainedRequestBytes: 0, scopeCount: 0)
        await expectEventually(file: file, line: line) { await service.statistics == empty }
    }

    private func assertRetainedActiveRequest(_ service: SafariRPCService, id: Int, file: StaticString = #filePath, line: UInt = #line) async {
        let retained = await service.statistics
        XCTAssertEqual(retained.activeRequests, 1, file: file, line: line)
        XCTAssertEqual(retained.outstandingRequests, 1, file: file, line: line)
        XCTAssertEqual(retained.retainedRequestBytes, Self.body(id).utf8.count * 2, file: file, line: line)
        XCTAssertEqual(retained.scopeCount, 1, file: file, line: line)
    }

    private func assertSuccess(_ response: RPCResponseToExtension, id: Int, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(response.json["id"] as? Int, id, file: file, line: line)
        XCTAssertEqual(response.json["result"] as? String, "result-\(id)", file: file, line: line)
        XCTAssertNil(response.json["error"], file: file, line: line)
    }

    private func assertFailure(_ response: RPCResponseToExtension, id: Int, reason: String, code: Int, dispatched: Bool = false, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(response.json["id"] as? Int, id, file: file, line: line)
        XCTAssertNil(response.json["result"], file: file, line: line)
        let error = response.json["error"] as? [String: Any]
        XCTAssertEqual(error?["code"] as? Int, code, file: file, line: line)
        let data = error?["data"] as? [String: Any]
        XCTAssertEqual(data?["reason"] as? String, reason, file: file, line: line)
        XCTAssertEqual(data?["dispatched"] as? Bool, dispatched, file: file, line: line)
    }
}
