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
            fixture.onManualLoad = nil
            fixture.onBeginRead = nil
            fixture.onReadResponse = nil
            fixture.clock.advance(to: UInt64.max)
            for _ in 0..<20 { await Task.yield() }
            try? FileManager.default.removeItem(at: fixture.bundleURL)
        }
        return fixture
    }

    func testStagedReadPreservesCadenceAndValidatesOnceInitially() async throws {
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
            let result = try await f.finish { await f.read(service, request, duration: duration) }
            guard case .pending = result else { return XCTFail("Expected pending at expiry") }
            XCTAssertEqual(f.clock.now - start, UInt64(min(duration, 170) * 1_000_000_000))
            let times = Array(Set(f.loads.map { $0.1 - start })).sorted()
            XCTAssertEqual(Array(times.prefix(5)), [0, 250_000_000, 500_000_000, 750_000_000, 1_000_000_000])
            XCTAssertEqual(validationTimes.filter { $0 == 0 }.count, 1)
            XCTAssertEqual(validationTimes.count, Int(min(duration, 170).rounded(.up)))
            XCTAssertTrue(f.launches.isEmpty)
            XCTAssertEqual(f.releasedReads, [request.handle])
        }
    }

    func testExecutingReadContinuesPastApprovalExpiry() async throws {
        let f = try fixture()
        let request = try f.request()
        f.deliver(request, staged: true)
        f.onValidate = { _ in
            f.deliver(request, runtime: f.processes[42]!, staged: true, executing: true)
            return true
        }
        let start = f.clock.now
        let service = f.service()
        let result = try await f.finish { await f.read(service, request, duration: 1) }
        guard case .pending = result else { return XCTFail("Expected executing work to remain pending") }
        XCTAssertEqual(f.clock.now - start, 170_000_000_000)
        XCTAssertEqual(f.validations.count, 1)
        XCTAssertEqual(f.releasedReads, [request.handle])
        XCTAssertTrue(f.launches.isEmpty)
    }

    func testInitialAndLaterDeliveryFailuresHaveDifferentOutcomes() async throws {
        for later in [false, true] {
            let f = try fixture()
            let request = try f.request()
            f.deliver(request, staged: true)
            let start = f.clock.now
            f.onValidate = { _ in later && f.clock.now - start < 1_000_000_000 }
            let service = f.service()
            let result = try await f.finish { await f.read(service, request) }
            if later {
                guard case .pending = result else { return XCTFail("Expected pending") }
            } else {
                guard case .unavailable = result else { return XCTFail("Expected unavailable") }
            }
            XCTAssertEqual(f.clock.now - start, later ? 1_000_000_000 : 0)
            XCTAssertEqual(f.releasedReads, [request.handle])
        }
    }

    func testConcurrentReadsKeepSeparateDeadlinesAndDoNotBlockDelivery() async throws {
        let f = try fixture()
        let first = try f.request()
        let second = try f.request(id: 2)
        f.deliver(first, staged: true)
        f.deliver(second, runtime: f.processes[42]!, staged: true)
        let service = f.service()
        let start = f.clock.now
        let short = Task { await f.read(service, first, duration: 0.5) }
        let long = Task { await f.read(service, second, duration: 1.5) }
        try await f.eventually { f.activeReads.count == 2 }
        f.onLaunch = { _, _, completion in completion(true) }
        let shown = try await f.finish {
            await service.open(.showWallet(workflowVersion: ExtensionBridge.workflowVersion))
        }
        XCTAssertTrue(shown)
        _ = try await f.finish { await short.value }
        XCTAssertEqual(f.clock.now - start, 500_000_000)
        XCTAssertEqual(f.activeReads, [second.handle])
        _ = try await f.finish { await long.value }
        XCTAssertEqual(f.clock.now - start, 1_500_000_000)
        XCTAssertEqual(Set(f.releasedReads), [first.handle, second.handle])
    }

    func testSecondReadOfSameHandleDoesNotReleaseFirstLease() async throws {
        let f = try fixture()
        let request = try f.request()
        f.deliver(request, staged: true)
        let service = f.service()
        let first = Task { await f.read(service, request) }
        try await f.eventually { f.activeReads.contains(request.handle) }
        let second = await f.read(service, request)
        guard case .pending = second else { return XCTFail("Expected contention") }
        XCTAssertTrue(f.releasedReads.isEmpty)
        XCTAssertEqual(f.activeReads, [request.handle])
        first.cancel()
        _ = await first.value
        XCTAssertEqual(f.releasedReads, [request.handle])
    }

    func testQuietReadNeverJoinsAnActiveForegroundLaunch() async throws {
        let f = try fixture()
        let request = try f.request()
        let gate = NativeApprovalServiceTestFixture.Gate()
        f.onValidate = { _ in await gate.wait(); return true }
        f.onLaunch = { _, _, completion in f.deliver(request); completion(true) }
        let service = f.service()
        let page = Task { await service.deliverApproval(handle: request.handle, nativeDeliveryNonce: request.nativeDeliveryNonce) }
        try await f.eventually { !f.validations.isEmpty }
        let result = await f.read(service, request, mode: .manualRecovery)
        guard case .pending = result else { return XCTFail("Quiet recovery must remain pending") }
        XCTAssertTrue(f.executionReads.isEmpty)
        XCTAssertTrue(f.launches.isEmpty)
        gate.open()
        let delivered = try await f.finish { await page.value }
        XCTAssertEqual(delivered, .pending)
    }

    func testApprovedHelperLossInterruptsWithoutRelaunch() async throws {
        let f = try fixture()
        let request = try f.request()
        f.deliver(request, staged: true)
        let start = f.clock.now
        f.onLoad = { handle in
            if f.clock.now - start >= 1_000_000_000 { f.processes.removeAll() }
            return .found(f.snapshots[handle]!)
        }
        let service = f.service()
        let result = try await f.finish { await f.read(service, request) }
        guard case .response(let json) = result,
              case .error(let error) = ResponseToExtension(json: json)?.payload else {
            return XCTFail("Expected interruption response")
        }
        XCTAssertEqual(error, .approvalInterrupted)
        XCTAssertEqual(f.clears.count, 1)
        XCTAssertTrue(f.launches.isEmpty)
        XCTAssertEqual(f.releasedReads, [request.handle])
    }

    func testLeaseIsHeldUntilFinalReadCompletes() async throws {
        let f = try fixture()
        let request = try f.request()
        f.deliver(request, staged: true)
        f.onValidate = { _ in f.setState(.responded, for: request); return true }
        let gate = NativeApprovalServiceTestFixture.Gate()
        f.onReadResponse = { handle, _ in
            XCTAssertTrue(f.activeReads.contains(handle))
            await gate.wait()
            XCTAssertTrue(f.activeReads.contains(handle))
            return .response(["id": handle.id])
        }
        let service = f.service()
        let task = Task { await f.read(service, request) }
        try await f.eventually { !f.responseReads.isEmpty }
        XCTAssertTrue(f.releasedReads.isEmpty)
        gate.open()
        guard case .response = await task.value else { return XCTFail("Expected response") }
        XCTAssertEqual(f.releasedReads, [request.handle])
    }

    func testCancellationReleasesOnlyTheReadLease() async throws {
        let f = try fixture()
        let request = try f.request()
        f.deliver(request, staged: true)
        f.onValidate = { _ in f.deliver(request, runtime: f.processes[42]!, staged: true, executing: true); return true }
        let service = f.service()
        let task = Task { await f.read(service, request) }
        try await f.eventually { f.clock.deadlines.contains(f.clock.now + 250_000_000) }
        let loads = f.loads.count
        task.cancel()
        guard case .pending = await task.value else { return XCTFail("Expected pending") }
        XCTAssertEqual(f.loads.count, loads)
        XCTAssertEqual(f.snapshots[request.handle]?.phase, .approving)
        XCTAssertEqual(f.releasedReads, [request.handle])
        XCTAssertTrue(f.launches.isEmpty)
        XCTAssertTrue(f.clears.isEmpty)
    }

    func testCancellationDuringLeaseAcquisitionStillReleasesLease() async throws {
        let f = try fixture()
        let request = try f.request()
        let gate = NativeApprovalServiceTestFixture.Gate()
        var releases = 0
        f.onBeginRead = { handle, _, revisions, deadline in
            await gate.wait()
            return .acquired(.init(
                handle: handle,
                context: .init(revisions: revisions, observedAt: f.clock.date, executionDeadline: deadline, fenceToken: UUID()),
                nativeDeliveryNonce: request.nativeDeliveryNonce,
                finish: { releases += 1 }
            ))
        }
        let service = f.service()
        let task = Task { await f.read(service, request) }
        try await f.eventually { !f.executionReads.isEmpty }
        task.cancel()
        gate.open()
        guard case .pending = await task.value else { return XCTFail("Expected pending") }
        XCTAssertEqual(releases, 1)
        XCTAssertTrue(f.loads.isEmpty)
        XCTAssertTrue(f.launches.isEmpty)
    }

    func testManualReadEligibilityAndStoreFailuresRemainDistinct() async throws {
        for scenario in ["missing", "unavailable", "unowned", "delivered", "invalid", "completed", "readFailure"] {
            let f = try fixture()
            let request = try f.request()
            switch scenario {
            case "missing": f.onManualLoad = { _, _ in .missing }
            case "unavailable": f.onManualLoad = { _, _ in .unavailable }
            case "delivered": f.deliver(request)
            case "invalid":
                f.deliver(request, staged: true)
                f.onValidate = { _ in false }
            case "completed", "readFailure":
                f.setState(.responded, for: request)
                if scenario == "readFailure" { f.onReadResponse = { _, _ in .unavailable } }
            default: break
            }
            let result = await f.read(f.service(), request, mode: .manualRecovery)
            switch (scenario, result) {
            case ("missing", .missing), ("unavailable", .unavailable), ("readFailure", .unavailable),
                 ("unowned", .pending), ("delivered", .pending), ("invalid", .pending), ("completed", .response): break
            default: XCTFail("Unexpected result for \(scenario)")
            }
            XCTAssertTrue(f.launches.isEmpty)
            XCTAssertTrue(f.quits.isEmpty)
            if scenario != "completed" && scenario != "readFailure" { XCTAssertTrue(f.executionReads.isEmpty) }
        }
    }

    func testFinalReadFailureReleasesLeaseInBothModes() async throws {
        for mode in [NativeApprovalService.ApprovalReadMode.page, .manualRecovery] {
            let f = try fixture()
            let request = try f.request()
            f.deliver(request, staged: true)
            f.onValidate = { _ in
                if !f.activeReads.isEmpty { f.setState(.responded, for: request) }
                return true
            }
            f.onReadResponse = { handle, _ in
                XCTAssertTrue(f.activeReads.contains(handle))
                return .unavailable
            }
            let result = await f.read(f.service(), request, mode: mode)
            guard case .unavailable = result else { return XCTFail("Expected store failure") }
            XCTAssertEqual(f.releasedReads, [request.handle])
        }
    }

    func testRealStoreFenceSurvivesFinalReadAndClearsOnEveryExit() async throws {
        for completes in [false, true] {
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
            let boundary = f.launcherDependencies
            var held = false
            var releases = 0
            var finalReads = 0
            let dependencies = approvalServiceTestDependencies(
                launcher: NativeAgentLauncher(dependencies: boundary),
                load: { handle in
                    if held && completes {
                        _ = await bridge.interruptNativeApproval(
                            handle: handle, nativeDeliveryNonce: snapshot.nativeDeliveryNonce,
                            runtimeInstanceIdentifier: runtime.instanceIdentifier
                        )
                    }
                    return await bridge.load(handle: handle)
                },
                beginExecutionRead: { handle, key, revisions, deadline in
                    let result = await bridge.beginNativeExecutionRead(
                        handle: handle, configurationKey: key, revisions: revisions, executionDeadline: deadline
                    )
                    guard case .acquired(let lease) = result else { return result }
                    held = true
                    let competing = await bridge.beginNativeExecutionRead(
                        handle: handle, configurationKey: key, revisions: revisions, executionDeadline: deadline
                    )
                    guard case .pending = competing else {
                        lease.release()
                        XCTFail("A second reader acquired the real fence")
                        return .unavailable
                    }
                    return .acquired(.init(
                        handle: handle, context: lease.context, nativeDeliveryNonce: lease.nativeDeliveryNonce,
                        finish: { lease.release(); held = false; releases += 1 }
                    ))
                },
                readResponse: { handle, key in
                    XCTAssertTrue(held)
                    finalReads += 1
                    let result = await bridge.readResponse(
                        id: handle.id, configurationKey: key, requestToken: handle.requestToken,
                        profileIdentifier: handle.profileIdentifier
                    )
                    XCTAssertTrue(held)
                    return result
                },
                uptime: { f.clock.now }, wallClock: { f.clock.date },
                sleepUntil: { [clock = f.clock] in await clock.sleepUntil($0) }
            )
            let service = NativeApprovalService(dependencies: dependencies)
            let result = try await f.finish { await f.read(service, snapshot, duration: 0.25) }
            if completes {
                guard case .response = result else { return XCTFail("Expected interruption") }
            } else {
                guard case .pending = result else { return XCTFail("Expected expiry") }
            }
            XCTAssertFalse(held)
            XCTAssertEqual(releases, 1)
            XCTAssertEqual(finalReads, completes ? 1 : 0)
            let stored = try await store.snapshot(handle: snapshot.handle)
            XCTAssertNil(stored.nativeExecutionContext)
            if !completes {
                let next = await bridge.beginNativeExecutionRead(
                    handle: snapshot.handle, configurationKey: snapshot.configurationKey,
                    revisions: snapshot.revisions, executionDeadline: f.clock.date.addingTimeInterval(1)
                )
                guard case .acquired(let lease) = next else { return XCTFail("Fence was not released") }
                lease.release()
            }
        }
    }

    func testSuspendedReceiptValidationTimesOutWithoutLateMutation() async throws {
        let f = try fixture()
        let request = try f.request()
        f.deliver(request, staged: true)
        let gate = NativeApprovalServiceTestFixture.Gate()
        f.onValidate = { _ in await gate.wait(); return true }
        let service = f.service()
        let result = try await f.finish { await f.read(service, request) }
        guard case .unavailable = result else { return XCTFail("Expected bounded initial validation") }
        XCTAssertEqual(f.releasedReads, [request.handle])
        gate.open()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(f.clears.isEmpty)
        XCTAssertTrue(f.launches.isEmpty)
    }
}
#endif
