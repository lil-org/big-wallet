#if os(macOS)
import Foundation
import XCTest
@testable import Big_Wallet

@MainActor
final class NativeApprovalResponseTests: XCTestCase {
    private func fixture() throws -> NativeApprovalServiceTestFixture {
        let fixture = try NativeApprovalServiceTestFixture()
        addTeardownBlock { @MainActor in
            fixture.onValidate = nil
            fixture.onLoad = nil
            fixture.onLaunch = nil
            fixture.onQuit = nil
            fixture.onClear = nil
            fixture.onBeginExecution = nil
            fixture.onResponseStatus = nil
            fixture.clock.advance(to: UInt64.max)
            for _ in 0..<20 { await Task.yield() }
            try? FileManager.default.removeItem(at: fixture.bundleURL)
        }
        return fixture
    }

    func testExplicitExecutionPreservesCadenceAndOriginalDeadline() async throws {
        for duration in [2.25, 300.0] {
            let f = try fixture()
            let request = try f.request()
            f.deliver(request, staged: true)
            let start = f.clock.now
            var validationTimes = [UInt64]()
            f.onValidate = { _ in
                validationTimes.append(f.clock.now - start)
                return true
            }
            let service = f.service()
            let result = try await f.finish(afterStarting: {
                try await f.advanceClock(by: 250_000_000, steps: Int(min(duration, 170) * 4))
            }) { await f.execute(service, request, duration: duration) }
            guard case .pending = result else { return XCTFail("Expected pending at expiry") }
            try await f.eventually { f.releasedExecutions == [request.handle] }
            XCTAssertEqual(f.clock.now - start, UInt64(min(duration, 170) * 1_000_000_000))
            let times = Array(Set(f.loads.map { $0.1 - start })).sorted()
            XCTAssertEqual(Array(times.prefix(5)), [0, 250_000_000, 500_000_000, 750_000_000, 1_000_000_000])
            XCTAssertEqual(validationTimes.filter { $0 == 0 }.count, 1)
            XCTAssertEqual(validationTimes.count, Int(min(duration, 170).rounded(.up)))
            XCTAssertTrue(f.launches.isEmpty)
            XCTAssertTrue(f.clears.isEmpty)
            XCTAssertTrue(f.maintainedProfiles.isEmpty)
        }
    }

    func testExecutingApprovalContinuesPastApprovalDeadline() async throws {
        let f = try fixture()
        let request = try f.request()
        f.deliver(request, staged: true)
        f.onValidate = { _ in
            f.deliver(request, runtime: f.processes[42]!, executing: true)
            return true
        }
        let start = f.clock.now
        let service = f.service()
        let result = try await f.finish(afterStarting: {
            try await f.advanceClock(by: 250_000_000, steps: 680)
        }) { await f.execute(service, request, duration: 1) }
        guard case .pending = result else { return XCTFail("Expected executing work to remain pending") }
        try await f.eventually { f.releasedExecutions == [request.handle] }
        XCTAssertEqual(f.clock.now - start, 170_000_000_000)
        XCTAssertEqual(f.validations.count, 1)
        XCTAssertTrue(f.launches.isEmpty)
    }

    func testFailedVerificationNeverRepairsOrLaunches() async throws {
        for later in [false, true] {
            let f = try fixture()
            let request = try f.request()
            f.deliver(request, staged: true)
            let start = f.clock.now
            f.onValidate = { _ in later && f.clock.now - start < 1_000_000_000 }
            let service = f.service()
            let result = try await f.finish(afterStarting: {
                if later { try await f.advanceClock(by: 250_000_000, steps: 4) }
            }) { await f.execute(service, request) }
            guard case .unavailable = result else { return XCTFail("Expected unavailable") }
            XCTAssertEqual(f.clock.now - start, later ? 1_000_000_000 : 0)
            XCTAssertEqual(f.releasedExecutions, [request.handle])
            XCTAssertTrue(f.clears.isEmpty)
            XCTAssertTrue(f.quits.isEmpty)
            XCTAssertTrue(f.launches.isEmpty)
        }
    }

    func testConcurrentExecutionsHaveSeparateDeadlinesAndDoNotBlockDelivery() async throws {
        let f = try fixture()
        let first = try f.request()
        let second = try f.request(id: 2)
        f.deliver(first, staged: true)
        f.deliver(second, runtime: f.processes[42]!, staged: true)
        let service = f.service()
        let start = f.clock.now
        let short = Task { await f.execute(service, first, duration: 0.5) }
        let long = Task { await f.execute(service, second, duration: 1.5) }
        try await f.eventually { f.activeExecutions.count == 2 }
        f.onLaunch = { _, _, completion in completion(true) }
        let shown = try await f.finish {
            await service.open(.showWallet(workflowVersion: ExtensionBridge.workflowVersion))
        }
        XCTAssertTrue(shown)
        _ = try await f.finish(afterStarting: {
            try await f.advanceClock(by: 250_000_000, steps: 2, waiters: 2)
        }) { await short.value }
        XCTAssertEqual(f.clock.now - start, 500_000_000)
        XCTAssertEqual(f.activeExecutions, [second.handle])
        _ = try await f.finish(afterStarting: {
            try await f.advanceClock(by: 250_000_000, steps: 4)
        }) { await long.value }
        XCTAssertEqual(f.clock.now - start, 1_500_000_000)
        XCTAssertEqual(Set(f.releasedExecutions), [first.handle, second.handle])
    }

    func testDuplicateExecutionSharesOneLeaseAndOriginalBounds() async throws {
        let f = try fixture()
        let request = try f.request()
        f.deliver(request, staged: true)
        let attemptID = UUID()
        let service = f.service()
        let first = Task { await f.execute(service, request, attemptID: attemptID, duration: 0.5) }
        try await f.eventually { f.activeExecutions.contains(request.handle) }
        let second = Task { await f.execute(service, request, attemptID: attemptID, duration: 0.5) }
        for _ in 0..<30 { await Task.yield() }
        XCTAssertEqual(f.executionBegins, [request.handle])
        XCTAssertTrue(f.releasedExecutions.isEmpty)
        first.cancel()
        let results = try await f.finish(afterStarting: {
            try await f.advanceClock(by: 250_000_000, steps: 2)
        }) { await [first.value, second.value] }
        for result in results {
            guard case .pending = result else { return XCTFail("Expected original deadline") }
        }
        XCTAssertEqual(f.releasedExecutions, [request.handle])
    }

    func testConcurrentChangedAttemptCannotExtendOrReplaceExecution() async throws {
        let f = try fixture()
        let request = try f.request()
        f.deliver(request, staged: true)
        let attemptID = UUID()
        let deadline = f.clock.date.addingTimeInterval(0.5)
        let service = f.service()
        let first = Task { await f.execute(service, request, attemptID: attemptID, duration: 0.5) }
        try await f.eventually { f.activeExecutions.contains(request.handle) }
        let revised = try XCTUnwrap(ExtensionBridge.ProviderRevisions(rawValue: ["ethereum": 1, "solana": 0]))
        for (candidate, revisions, expires) in [
            (UUID(), request.revisions, deadline),
            (attemptID, revised, deadline),
            (attemptID, request.revisions, deadline.addingTimeInterval(1)),
        ] {
            let result = await service.executeNativeApproval(
                handle: request.handle, configurationKey: request.configurationKey,
                attemptID: candidate, revisions: revisions, executionDeadline: expires
            )
            guard case .unavailable = result else { return XCTFail("Expected conflicting descriptor rejection") }
        }
        XCTAssertEqual(f.executionBegins, [request.handle])
        _ = try await f.finish(afterStarting: {
            try await f.advanceClock(by: 250_000_000, steps: 2)
        }) { await first.value }
        XCTAssertEqual(f.releasedExecutions, [request.handle])
    }

    func testApprovedHelperLossNeedsExplicitMaintenance() async throws {
        let f = try fixture()
        let request = try f.request()
        f.deliver(request, staged: true)
        let start = f.clock.now
        f.onLoad = { handle in
            if f.clock.now - start >= 1_000_000_000 { f.processes.removeAll() }
            return .found(f.snapshots[handle]!)
        }
        let service = f.service()
        let result = try await f.finish(afterStarting: {
            try await f.advanceClock(by: 250_000_000, steps: 4)
        }) { await f.execute(service, request) }
        guard case .unavailable = result else { return XCTFail("Expected missing owner") }
        XCTAssertTrue(f.clears.isEmpty)
        XCTAssertTrue(f.launches.isEmpty)
        XCTAssertEqual(f.releasedExecutions, [request.handle])
        guard case .ready = await f.maintain(service, request) else { return XCTFail("Expected explicit interruption") }
        let json = try XCTUnwrap(f.responses[request.handle])
        guard case .error(let error) = ResponseToExtension(json: json)?.payload else {
            return XCTFail("Expected interruption response")
        }
        XCTAssertEqual(error, .approvalInterrupted)
        XCTAssertEqual(f.clears.count, 1)
        XCTAssertTrue(f.launches.isEmpty)
    }

    func testExecutionReturnsStatusWithoutPreparingResponseDelivery() async throws {
        let f = try fixture()
        let request = try f.request()
        f.deliver(request, staged: true)
        f.onValidate = { _ in f.setState(.responded, for: request); return true }
        let service = f.service()
        let result = try await f.finish(afterStarting: {
            try await f.advanceClock(by: 250_000_000)
        }) { await f.execute(service, request) }
        guard case .ready = result else { return XCTFail("Expected response status") }
        XCTAssertEqual(f.releasedExecutions, [request.handle])
        XCTAssertTrue(f.responseStatusReads.isEmpty)
        XCTAssertTrue(f.maintainedProfiles.isEmpty)
    }

    func testSupersededExecutionContextReleasesFenceWithoutRepair() async throws {
        let f = try fixture()
        let request = try f.request()
        f.deliver(request, staged: true)
        f.onValidate = { _ in
            let current = f.snapshots[request.handle]!
            f.setState(.queued(request: request.request!, approval: .delivered(current.nativeDeliveryReceipt!)), for: request)
            return true
        }
        let service = f.service()
        let result = try await f.finish(afterStarting: {
            try await f.advanceClock(by: 250_000_000)
        }) { await f.execute(service, request) }
        guard case .pending = result else { return XCTFail("Expected superseded execution") }
        XCTAssertEqual(f.releasedExecutions, [request.handle])
        XCTAssertTrue(f.clears.isEmpty)
        XCTAssertTrue(f.launches.isEmpty)
    }

    func testCancelledExecutionBeforeAdmissionDoesNoWork() async throws {
        let f = try fixture()
        let request = try f.request()
        let gate = NativeApprovalServiceTestFixture.Gate()
        let service = f.service()
        let task = Task { await gate.wait(); return await f.execute(service, request) }
        task.cancel()
        gate.open()
        guard case .pending = await task.value else { return XCTFail("Expected cancellation") }
        XCTAssertTrue(f.executionBegins.isEmpty)
        XCTAssertTrue(f.loads.isEmpty)
    }

    func testRealStoreExecutionFencePreservesAttemptAfterRelease() async throws {
        let f = try fixture()
        let store = try ApprovalStoreTestFixture(clock: { f.clock.date })
        addTeardownBlock { try await store.cleanup() }
        let snapshot = try await store.enqueue(
            rawObject: [
                "id": 9_001, "name": "requestAccounts", "provider": "ethereum",
                "host": "wallet.example", "configurationKey": "https://wallet.example",
                "enqueueAttempt": String(repeating: "a", count: 32),
                "workflowVersion": ExtensionBridge.workflowVersion,
                "body": ["address": ""],
            ], revisions: ExtensionBridge.ProviderRevisions(rawValue: ["ethereum": 0, "solana": 0])!
        )
        let bridge = store.bridge
        let runtime = f.runtime()
        f.processes[42] = runtime
        await store.setNativeDeliveryReceipt(
            .init(nativeDeliveryNonce: snapshot.nativeDeliveryNonce, owner: runtime.nativeDeliveryOwner!),
            handle: snapshot.handle
        )
        _ = try await store.prepareNativeApproval(handle: snapshot.handle, decision: .addEthereumChain)
        let active = NativeApprovalServiceTestFixture.ExecutionLeases()
        let attemptID = UUID()
        let executionDeadline = f.clock.date.addingTimeInterval(0.25)
        f.onValidate = { _ in false }
        let dependencies = approvalServiceTestDependencies(
            launcher: NativeAgentLauncher(dependencies: f.launcherDependencies),
            load: { await bridge.load(handle: $0) },
            beginExecution: { handle, key, attempt, revisions, deadline in
                let result = await bridge.beginNativeExecution(
                    handle: handle, configurationKey: key, attemptID: attempt,
                    revisions: revisions, executionDeadline: deadline
                )
                guard case .acquired(let lease) = result else { return result }
                XCTAssertTrue(active.acquire(handle))
                let competing = await bridge.beginNativeExecution(
                    handle: handle, configurationKey: key, attemptID: attempt,
                    revisions: revisions, executionDeadline: deadline
                )
                guard case .pending = competing else {
                    lease.release()
                    XCTFail("Another execution acquired the real fence")
                    return .unavailable
                }
                return .acquired(.init(
                    handle: handle, context: lease.context, nativeDeliveryNonce: lease.nativeDeliveryNonce,
                    finish: { lease.release(); active.release(handle) }
                ))
            },
            uptime: { [clock = f.clock] in clock.now },
            wallClock: { [clock = f.clock] in clock.date },
            sleepUntil: { [clock = f.clock] in await clock.sleepUntil($0) }
        )
        let service = NativeApprovalService(dependencies: dependencies)
        let result = try await f.finish {
            await service.executeNativeApproval(
                handle: snapshot.handle, configurationKey: snapshot.configurationKey,
                attemptID: attemptID, revisions: snapshot.revisions,
                executionDeadline: executionDeadline
            )
        }
        guard case .unavailable = result else { return XCTFail("Expected verification failure") }
        XCTAssertTrue(active.activeHandles.isEmpty)
        XCTAssertEqual(active.releasedHandles, [snapshot.handle])
        let stored = try await store.snapshot(handle: snapshot.handle)
        XCTAssertEqual(stored.nativeExecutionContext?.attemptID, attemptID)
        XCTAssertEqual(stored.nativeExecutionContext?.executionDeadline, executionDeadline)
        let replacement = await bridge.beginNativeExecution(
            handle: snapshot.handle, configurationKey: snapshot.configurationKey,
            attemptID: UUID(), revisions: snapshot.revisions,
            executionDeadline: f.clock.date.addingTimeInterval(1)
        )
        guard case .unavailable = replacement else { return XCTFail("A retained attempt was extended") }
        f.clock.advance(to: f.clock.now + 250_000_000)
        let retry = await bridge.beginNativeExecution(
            handle: snapshot.handle, configurationKey: snapshot.configurationKey,
            attemptID: attemptID, revisions: snapshot.revisions,
            executionDeadline: executionDeadline
        )
        guard case .responseReady = retry else { return XCTFail("Expired execution must remain terminal") }
        let expired = try await store.snapshot(handle: snapshot.handle)
        XCTAssertEqual(expired.phase, .responded)
    }

    func testSuspendedReceiptValidationTimesOutWithoutLateMutation() async throws {
        let f = try fixture()
        let request = try f.request()
        f.deliver(request, staged: true)
        let gate = NativeApprovalServiceTestFixture.Gate()
        f.onValidate = { _ in await gate.wait(); return true }
        let service = f.service()
        let result = try await f.finish(afterStarting: {
            try await f.eventually { !f.validations.isEmpty }
            try await f.advanceClock(by: 5_000_000_000)
        }) { await f.execute(service, request) }
        guard case .unavailable = result else { return XCTFail("Expected bounded initial validation") }
        XCTAssertEqual(f.releasedExecutions, [request.handle])
        gate.open()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(f.clears.isEmpty)
        XCTAssertTrue(f.launches.isEmpty)
    }
}
#endif
