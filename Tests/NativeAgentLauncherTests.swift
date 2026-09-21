#if os(macOS)
    import Foundation
    import XCTest
    @testable import Big_Wallet

    @MainActor
    final class NativeAgentLauncherTests: XCTestCase {
        private func fixture() throws -> NativeAgentLauncherTestFixture {
            let fixture = try NativeAgentLauncherTestFixture()
            addTeardownBlock { @MainActor in
                fixture.onValidate = nil
                fixture.onLoad = nil
                fixture.onLaunch = nil
                fixture.onQuit = nil
                fixture.onClear = nil
                fixture.clock.advance(to: UInt64.max)
                for _ in 0..<20 { await Task.yield() }
                try? FileManager.default.removeItem(at: fixture.bundleURL)
            }
            return fixture
        }

        func testAdmissionReconcilesReceiptAfterFailedLaunchCallback() async throws {
            for outcome in ["delivered", "completed", "replaced"] {
                let f = try fixture()
                let request = try f.request()
                f.onLaunch = { _, _, completion in
                    switch outcome {
                    case "delivered": f.deliver(request)
                    case "completed": f.setState(.responded, for: request)
                    default:
                        let replacement = try! f.request(id: 2)
                        f.snapshots[request.handle] = replacement
                    }
                    completion(false)
                }
                let launcher = f.launcher()
                let result = try await f.finish {
                    await launcher.deliverApproval(handle: request.handle, nativeDeliveryNonce: request.nativeDeliveryNonce)
                }
                XCTAssertEqual(result, outcome == "delivered" ? .pending : outcome == "completed" ? .responseReady : .unavailable)
                XCTAssertEqual(f.launches.count, 1)
            }
        }

        func testConfirmedAdmissionDoesNotRequireAnotherStoreRead() async throws {
            let f = try fixture()
            let request = try f.request()
            var confirmed = false
            f.onLoad = { handle in
                guard !confirmed else { return .unavailable }
                let snapshot = f.snapshots[handle]!
                if snapshot.nativeDeliveryReceipt != nil { confirmed = true }
                return .found(snapshot)
            }
            f.onLaunch = { _, _, completion in f.deliver(request); completion(true) }
            let launcher = f.launcher()
            let result = try await f.finish {
                await launcher.deliverApproval(handle: request.handle, nativeDeliveryNonce: request.nativeDeliveryNonce)
            }
            XCTAssertEqual(result, .pending)
            XCTAssertTrue(confirmed)
            XCTAssertEqual(f.loads.count, 3)
        }

        func testApprovedAdmissionBypassesUnrelatedLaunchQueue() async throws {
            let f = try fixture()
            let request = try f.request()
            f.deliver(request, staged: true)
            let gate = NativeAgentLauncherTestFixture.Gate()
            var firstValidation = true
            f.onValidate = { _ in
                if firstValidation { firstValidation = false; await gate.wait() }
                return true
            }
            f.onLaunch = { _, _, completion in completion(true) }
            let launcher = f.launcher()
            let wallet = Task { await launcher.open(.showWallet(workflowVersion: ExtensionBridge.workflowVersion)) }
            try await f.eventually { !f.validations.isEmpty }
            let result = await launcher.deliverApproval(handle: request.handle, nativeDeliveryNonce: request.nativeDeliveryNonce)
            XCTAssertEqual(result, .pending)
            XCTAssertTrue(f.launches.isEmpty)
            gate.open()
            let opened = await wallet.value
            XCTAssertTrue(opened)
        }

        func testPendingReadsValidateCodeOnlyAfterDecisionIsStaged() async throws {
            let f = try fixture()
            let request = try f.request()
            f.deliver(request)
            let launcher = f.launcher()
            for _ in 0..<3 {
                guard case .pending = await f.read(launcher, request) else { return XCTFail("Expected pending") }
            }
            XCTAssertTrue(f.validations.isEmpty)
            XCTAssertTrue(f.launches.isEmpty)
            f.deliver(request, staged: true)
            _ = try await f.finish { await f.read(launcher, request, duration: 0.25) }
            XCTAssertEqual(f.validations.count, 1)
        }

        func testPendingReadRedeliversAfterHelperExit() async throws {
            let f = try fixture()
            let request = try f.request()
            f.deliver(request)
            f.processes.removeAll()
            f.onLaunch = { _, _, completion in f.deliver(request); completion(true) }
            let launcher = f.launcher()
            let result = try await f.finish { await f.read(launcher, request) }
            guard case .pending = result else { return XCTFail("Expected pending review") }
            XCTAssertEqual(f.clears.count, 1)
            XCTAssertEqual(f.launches.count, 1)
        }

        func testPendingReadRejectsChangedRuntimeIdentity() async throws {
            let f = try fixture()
            let request = try f.request()
            f.deliver(request)
            f.processes[42] = f.runtime(instance: UUID())
            let result = await f.read(f.launcher(), request)
            guard case .unavailable = result else { return XCTFail("Expected unverified owner") }
            XCTAssertTrue(f.clears.isEmpty)
            XCTAssertTrue(f.launches.isEmpty)
        }

        func testUnidentifiedReceiptOwnerIsRetained() async throws {
            let f = try fixture()
            let request = try f.request()
            f.deliver(request)
            let runtime = f.processes[42]!
            f.processes.removeAll()
            f.unidentifiedProcesses[42] = .init(
                processIdentifier: 42, bundleURL: f.bundleURL,
                processStartDate: runtime.launchedAt, isRunning: { true })
            let result = await f.read(f.launcher(), request)
            guard case .unavailable = result else { return XCTFail("Expected unavailable") }
            XCTAssertTrue(f.clears.isEmpty)
            XCTAssertTrue(f.quits.isEmpty)
        }

        func testQuietRecoveryDoesNotReplaceIncompatibleHelper() async throws {
            let f = try fixture()
            let request = try f.request()
            f.deliver(request, runtime: f.runtime(build: "147"), staged: true)
            let result = await f.read(f.launcher(), request, mode: .manualRecovery)
            guard case .pending = result else { return XCTFail("Expected quiet pending") }
            XCTAssertTrue(f.executionReads.isEmpty)
            XCTAssertTrue(f.clears.isEmpty)
            XCTAssertTrue(f.quits.isEmpty)
            XCTAssertTrue(f.launches.isEmpty)
        }

        func testReceiptReplacementAfterClearCannotConfirmOldDelivery() async throws {
            for mode in [NativeAgentLauncher.ApprovalReadMode.page, .manualRecovery] {
                let f = try fixture()
                let request = try f.request()
                f.deliver(request, staged: true)
                f.processes.removeAll()
                f.onClear = { _, _ in
                    let replacement = try! f.request(id: 2)
                    f.snapshots[request.handle] = replacement
                    return .persisted
                }
                let result = await f.read(f.launcher(), request, mode: mode)
                if mode == .manualRecovery {
                    guard case .pending = result else { return XCTFail("Expected pending") }
                } else {
                    guard case .pending = result else { return XCTFail("Replacement has no response") }
                }
                XCTAssertEqual(f.clears.count, 1)
                XCTAssertTrue(f.quits.isEmpty)
                XCTAssertTrue(f.launches.isEmpty)
            }
        }

        func testIncompatibleOwnerExitsBeforeReceiptClear() async throws {
            let f = try fixture()
            let request = try f.request()
            f.deliver(request, runtime: f.runtime(build: "147"), staged: true)
            f.onQuit = { _ in true }
            let launcher = f.launcher()
            let task = Task { await f.read(launcher, request) }
            try await f.eventually { f.quits == [42] && !f.clock.deadlines.isEmpty }
            XCTAssertTrue(f.clears.isEmpty)
            f.processes.removeAll()
            f.clock.advance(to: f.clock.deadlines.first!)
            guard case .response = await task.value else { return XCTFail("Expected interrupted response") }
            XCTAssertEqual(f.clears.count, 1)
            XCTAssertTrue(f.launches.isEmpty)
        }

        func testReceiptReplacementDuringVerificationPreventsQuittingOldOwner() async throws {
            for replacementPoint in ["validation", "reload"] {
                let f = try fixture()
                let request = try f.request()
                f.deliver(request, runtime: f.runtime(build: "147"), staged: true)
                if replacementPoint == "validation" {
                    var replaced = false
                    f.onValidate = { _ in
                        if !replaced { replaced = true; f.deliver(request, runtime: f.runtime(pid: 43)) }
                        return true
                    }
                } else {
                    var reads = 0
                    f.onLoad = { handle in
                        reads += 1
                        if reads == 2 { f.deliver(request, runtime: f.runtime(pid: 43)) }
                        return .found(f.snapshots[handle]!)
                    }
                }
                let launcher = f.launcher()
                _ = try await f.finish { await f.read(launcher, request, duration: 0.25) }
                XCTAssertTrue(f.quits.isEmpty)
                XCTAssertTrue(f.clears.isEmpty)
                XCTAssertTrue(f.launches.isEmpty)
            }
        }

        func testRuntimeReplacementOrExpiryDuringVerificationPreventsQuit() async throws {
            for expires in [false, true] {
                let f = try fixture()
                let request = try f.request()
                f.deliver(request, runtime: f.runtime(build: "147"), staged: true)
                f.onValidate = { _ in
                    if expires { f.clock.advance(to: f.clock.now + 6_000_000_000) }
                    else { f.processes[42] = f.runtime(instance: UUID()) }
                    return true
                }
                let result = await f.read(f.launcher(), request)
                guard case .unavailable = result else { return XCTFail("Expected unavailable") }
                XCTAssertTrue(f.quits.isEmpty)
                XCTAssertTrue(f.clears.isEmpty)
            }
        }

        func testCancelledReadCannotRepairAfterSuspension() async throws {
            for mode in [NativeAgentLauncher.ApprovalReadMode.page, .manualRecovery] {
                let f = try fixture()
                let request = try f.request()
                f.deliver(request, staged: true)
                f.processes.removeAll()
                let gate = NativeAgentLauncherTestFixture.Gate()
                f.onLoad = { handle in await gate.wait(); return .found(f.snapshots[handle]!) }
                let launcher = f.launcher()
                let task = Task { await f.read(launcher, request, mode: mode) }
                try await f.eventually { !f.loads.isEmpty }
                task.cancel()
                guard case .pending = await task.value else { return XCTFail("Expected cancellation") }
                gate.open()
                for _ in 0..<20 { await Task.yield() }
                XCTAssertTrue(f.quits.isEmpty)
                XCTAssertTrue(f.clears.isEmpty)
                XCTAssertTrue(f.launches.isEmpty)
            }
        }

        func testCancelledReadDoesNotStartWork() async throws {
            let f = try fixture()
            let request = try f.request()
            let gate = NativeAgentLauncherTestFixture.Gate()
            let launcher = f.launcher()
            let task = Task { await gate.wait(); return await f.read(launcher, request) }
            task.cancel()
            gate.open()
            guard case .pending = await task.value else { return XCTFail("Expected pending") }
            XCTAssertTrue(f.executionReads.isEmpty)
            XCTAssertTrue(f.loads.isEmpty)
        }

        func testStagedApprovalCanBeExplicitlyReactivated() async throws {
            let f = try fixture()
            let request = try f.request()
            f.deliver(request)
            let delivered = f.snapshots[request.handle]!
            f.setState(.queued(
                request: request.request!,
                approval: .staged(.init(receipt: delivered.nativeDeliveryReceipt!, approvedAt: f.clock.date, executionContext: nil))
            ), for: request)
            f.onLaunch = { _, _, completion in completion(true) }
            let launcher = f.launcher()
            let result = try await f.finish { await launcher.reactivate(f.route(request)) }
            XCTAssertTrue(result)
            XCTAssertEqual(f.launches.count, 1)
            f.setState(.approving(
                request: request.request!,
                nativeApproval: .init(receipt: delivered.nativeDeliveryReceipt!, approvedAt: f.clock.date, executionContext: nil)
            ), for: request)
            let executing = await launcher.reactivate(f.route(request))
            XCTAssertFalse(executing)
            XCTAssertEqual(f.launches.count, 1)
        }

        func testDeliveredApprovalIsSilentUntilExplicitReactivation() async throws {
            let f = try fixture()
            let request = try f.request()
            let owner = f.runtime(pid: 43)
            f.deliver(request, runtime: owner)
            f.processes[42] = f.runtime()
            let launcher = f.launcher()
            let opened = try await f.finish { await launcher.open(f.route(request)) }
            XCTAssertTrue(opened)
            XCTAssertTrue(f.launches.isEmpty)
            f.onLaunch = { _, _, completion in completion(true) }
            let reactivated = try await f.finish { await launcher.reactivate(f.route(request)) }
            XCTAssertTrue(reactivated)
            XCTAssertEqual(
                f.launches.map(\.target),
                [
                    .running(
                        url: f.bundleURL.standardizedFileURL, processIdentifier: 43,
                        runtimeInstanceIdentifier: owner.instanceIdentifier)
                ])
            let wrongNonce = await launcher.reactivate(
                .approval(
                    workflowVersion: ExtensionBridge.workflowVersion,
                    handle: request.handle, nativeDeliveryNonce: .init(value: UUID())))
            XCTAssertFalse(wrongNonce)
            XCTAssertEqual(f.launches.count, 1)
            f.setState(.responded, for: request)
            let terminal = await launcher.reactivate(f.route(request))
            XCTAssertFalse(terminal)
            XCTAssertEqual(f.launches.count, 1)
        }

        func testReactivationWithoutReceiptRequiresConfirmedDelivery() async throws {
            for publish in [false, true] {
                let f = try fixture()
                let request = try f.request()
                f.onLaunch = { _, _, completion in
                    if publish { f.deliver(request) }
                    completion(true)
                }
                let launcher = f.launcher()
                let result = try await f.finish { await launcher.reactivate(f.route(request)) }
                XCTAssertEqual(result, publish)
                XCTAssertEqual(f.launches.count, 1)
            }
        }

        func testSingleLaunchWaitsUntilAdmissionDeadline() async throws {
            let f = try fixture()
            let request = try f.request()
            f.onLaunch = { _, _, completion in completion(true) }
            let launcher = f.launcher(timeout: 1_000_000_000)
            let started = f.clock.now
            let result = try await f.finish { await launcher.open(f.route(request)) }
            XCTAssertFalse(result)
            XCTAssertEqual(f.launches.map { $0.time - started }, [0])
            XCTAssertEqual(f.launches.map(\.route), [f.route(request)])
            XCTAssertEqual(f.clock.now - started, 1_000_000_000)
        }

        func testExplicitRetryCanPublishTheSameApprovalReceipt() async throws {
            let f = try fixture()
            let request = try f.request()
            f.onLaunch = { _, _, completion in
                if f.launches.count == 2 { f.deliver(request) }
                completion(true)
            }
            let launcher = f.launcher()
            let first = try await f.finish { await launcher.open(f.route(request)) }
            XCTAssertFalse(first)
            XCTAssertEqual(f.launches.count, 1)
            let result = try await f.finish { await launcher.open(f.route(request)) }
            XCTAssertTrue(result)
            XCTAssertEqual(f.launches.map(\.route), [f.route(request), f.route(request)])
        }

        func testUnavailablePreflightStopsButUnavailableConfirmationPolls() async throws {
            for afterLaunch in [false, true] {
                let f = try fixture()
                let request = try f.request()
                f.onLoad = { _ in
                    if !afterLaunch || !f.launches.isEmpty { return .unavailable }
                    return .found(request)
                }
                f.onLaunch = { _, _, completion in completion(true) }
                let launcher = f.launcher(timeout: 800_000_000)
                let result = try await f.finish { await launcher.open(f.route(request)) }
                XCTAssertFalse(result)
                XCTAssertEqual(f.launches.count, afterLaunch ? 1 : 0)
                if afterLaunch { XCTAssertGreaterThan(f.loads.count, 3) }
            }
        }

        func testReceiptRepairPrecedesSingleLaunch() async throws {
            let f = try fixture()
            let request = try f.request()
            f.deliver(request, runtime: f.runtime(build: "147"))
            f.onLaunch = { _, _, completion in
                f.deliver(request)
                completion(true)
            }
            f.onQuit = { _ in true }
            let launcher = f.launcher()
            let task = Task { await launcher.open(f.route(request)) }
            try await f.eventually { f.quits.count == 1 && !f.clock.deadlines.isEmpty }
            XCTAssertTrue(f.launches.isEmpty)
            f.clock.advance(to: f.clock.now + 350_000_000)
            f.processes.removeAll()
            let result = try await f.finish { await task.value }
            XCTAssertTrue(result)
            XCTAssertEqual(f.clears.count, 1)
            XCTAssertEqual(f.launches.count, 1)
        }

        func testNonceReplacementStopsDelivery() async throws {
            let f = try fixture()
            let request = try f.request()
            f.onLaunch = { _, _, completion in
                let other = try! f.request(id: 2)
                f.snapshots[request.handle] = other
                completion(true)
            }
            let launcher = f.launcher()
            let result = try await f.finish { await launcher.open(f.route(request)) }
            XCTAssertFalse(result)
            XCTAssertEqual(f.launches.count, 1)
        }

        func testShowWalletRequiresRuntimeConfirmation() async throws {
            for publish in [false, true] {
                let f = try fixture()
                f.onLaunch = { _, _, completion in
                    if publish { f.processes[42] = f.runtime() }
                    f.clock.advance(to: f.clock.now + 300_000_000)
                    completion(true)
                }
                let launcher = f.launcher()
                let result = try await f.finish {
                    await launcher.open(.showWallet(workflowVersion: ExtensionBridge.workflowVersion))
                }
                XCTAssertEqual(result, publish)
                XCTAssertEqual(f.launches.count, 1)
            }
        }

        func testWalletConfirmationAcceptsDelayedRuntimePublication() async throws {
            let f = try fixture()
            f.onLaunch = { _, _, completion in completion(true) }
            let launcher = f.launcher()
            let task = Task {
                await launcher.open(.showWallet(workflowVersion: ExtensionBridge.workflowVersion))
            }
            try await f.eventually { f.launches.count == 1 && f.clock.deadlines.count > 1 }
            f.clock.advance(to: f.clock.now + 350_000_000)
            f.processes[42] = f.runtime()
            let result = try await f.finish { await task.value }
            XCTAssertTrue(result)
            XCTAssertEqual(f.launches.count, 1)
        }

        func testReactivationPublishesAndReadsReceiptThroughFileStore() async throws {
            let f = try fixture()
            let store = try ApprovalStoreTestFixture()
            addTeardownBlock { try await store.cleanup() }
            let snapshot = try await store.enqueue(
                rawObject: [
                    "id": 8_001, "name": "requestAccounts", "provider": "ethereum",
                    "host": "wallet.example", "configurationKey": "https://wallet.example",
                    "enqueueAttempt": String(repeating: "a", count: 32),
                    "workflowVersion": ExtensionBridge.workflowVersion,
                    "body": ["address": ""],
                ], revisions: ExtensionBridge.ProviderRevisions(rawValue: ["ethereum": 0, "solana": 0])!)
            let bridge = store.bridge
            let boundary = f.dependencies
            let runtime = f.runtime()
            f.onLaunch = { _, _, completion in
                f.processes[42] = runtime
                Task {
                    let result = await bridge.recordNativeDeliveryReceipt(
                        handle: snapshot.handle,
                        nativeDeliveryNonce: snapshot.nativeDeliveryNonce, owner: runtime.nativeDeliveryOwner!
                    )
                    completion(result == .persisted)
                }
            }
            let dependencies = launcherTestDependencies(
                helperURL: boundary.helperURL, validate: boundary.validate,
                helpers: boundary.helpers, helper: boundary.helper, identity: boundary.identity,
                launch: boundary.launch, load: { await bridge.load(handle: $0) },
                clearReceipt: { handle, receipt in
                    await bridge.clearNativeDeliveryReceipt(
                        handle: handle,
                        nativeDeliveryNonce: receipt.nativeDeliveryNonce,
                        runtimeInstanceIdentifier: receipt.owner.runtimeInstanceIdentifier)
                }
            )
            let launcher = NativeAgentLauncher(dependencies: dependencies)
            let reactivated = await launcher.reactivate(f.route(snapshot))
            XCTAssertTrue(reactivated)
            let stored = try await store.snapshot(handle: snapshot.handle)
            XCTAssertEqual(stored.nativeDeliveryReceipt?.owner, runtime.nativeDeliveryOwner)
            let delivered = await launcher.open(f.route(snapshot))
            XCTAssertTrue(delivered)
            XCTAssertEqual(f.launches.count, 1)
        }

        func testLaunchNeverCompletesAndLateCompletionCannotChangeResult() async throws {
            let f = try fixture()
            var callback: ((Bool) -> Void)?
            f.onLaunch = { _, _, completion in callback = completion }
            let launcher = f.launcher(timeout: 100_000_000)
            let result = try await f.finish {
                await launcher.open(.showWallet(workflowVersion: ExtensionBridge.workflowVersion))
            }
            XCTAssertFalse(result)
            XCTAssertEqual(f.launches.count, 1)
            callback?(true)
            await Task.yield()
            XCTAssertEqual(f.launches.count, 1)
        }

        func testDeliveryDeadlineCompletesWhileMainActorIsBlocked() async throws {
            let f = try fixture()
            let clock = f.clock
            let deadline = clock.now + 100_000_000
            let launcher = f.launcher(timeout: 100_000_000)
            let route = NativeAgentRoute.showWallet(
                workflowVersion: ExtensionBridge.workflowVersion
            )
            var callback: ((Bool) -> Void)?
            f.onLaunch = { _, _, completion in callback = completion }
            let completed = DispatchSemaphore(value: 0)
            let delivery = Task.detached {
                let result = await launcher.open(route)
                completed.signal()
                return result
            }
            try await f.eventually {
                callback != nil && clock.deadlines == [deadline]
            }

            let advanceClock = DispatchSemaphore(value: 0)
            Thread.detachNewThread {
                advanceClock.wait()
                clock.advance(to: deadline)
            }
            advanceClock.signal()
            let completedWhileBlocked = completed.wait(timeout: .now() + 5)

            XCTAssertEqual(completedWhileBlocked, .success)
            let result = await delivery.value
            XCTAssertFalse(result)
            callback?(true)
            for _ in 0..<20 { await Task.yield() }
            XCTAssertEqual(f.launches.count, 1)
            XCTAssertTrue(clock.deadlines.isEmpty)
        }

        func testResolutionTimeoutDoesNotLaunchOrQuitBeforeGrace() async throws {
            let f = try fixture()
            f.unidentifiedProcesses[42] = .init(
                processIdentifier: 42, bundleURL: f.bundleURL, processStartDate: f.clock.date,
                isRunning: { true },
                requestQuit: {
                    XCTFail("Grace has not elapsed")
                    return true
                })
            let launcher = f.launcher(timeout: 100_000_000)
            let result = try await f.finish {
                await launcher.open(.showWallet(workflowVersion: ExtensionBridge.workflowVersion))
            }
            XCTAssertFalse(result)
            XCTAssertTrue(f.launches.isEmpty)
        }

        func testConcurrentWalletOpensShareOneDelivery() async throws {
            let f = try fixture()
            let gate = NativeAgentLauncherTestFixture.Gate()
            defer { gate.open() }
            f.onValidate = { _ in
                await gate.wait()
                return true
            }
            f.onLaunch = { _, _, completion in
                f.processes[42] = f.runtime()
                completion(true)
            }
            let route = NativeAgentRoute.showWallet(workflowVersion: ExtensionBridge.workflowVersion)
            let launcher = f.launcher()
            let first = Task { await launcher.open(route) }
            try await f.eventually { !f.validations.isEmpty }
            let secondDeadline = f.clock.now + 4_000_000_000
            let second = Task { await launcher.open(route, waitDeadline: secondDeadline) }
            try await f.eventually { f.clock.deadlines.contains(secondDeadline) }
            gate.open()

            let firstResult = try await f.finish { await first.value }
            let secondResult = try await f.finish { await second.value }
            XCTAssertTrue(firstResult)
            XCTAssertTrue(secondResult)
            XCTAssertEqual(f.launches.map(\.route), [route])
        }

        func testSharedDeliveryOwnsOneTimeoutWithoutEarlierCallerDeadlines() async throws {
            let f = try fixture()
            let request = try f.request()
            let launcher = f.launcher()
            var completion: ((Bool) -> Void)?
            f.onLaunch = { _, _, callback in completion = callback }
            let deadline = f.clock.now + 5_000_000_000
            let first = Task { await launcher.open(f.route(request)) }
            try await f.eventually { completion != nil && f.clock.deadlines == [deadline] }
            let second = Task { await launcher.open(f.route(request)) }
            let third = Task { await launcher.open(f.route(request)) }
            for _ in 0..<30 { await Task.yield() }
            XCTAssertEqual(f.clock.deadlines, [deadline])
            f.deliver(request)
            completion?(true)
            let results = await [first.value, second.value, third.value]
            XCTAssertEqual(results, [true, true, true])
            XCTAssertEqual(f.launches.count, 1)
            XCTAssertTrue(f.clock.deadlines.isEmpty)
        }

        func testIdenticalRoutesShareDeliveryDespiteCancelledWaiter() async throws {
            let f = try fixture()
            let request = try f.request()
            let gate = NativeAgentLauncherTestFixture.Gate()
            f.onValidate = { _ in
                await gate.wait()
                return true
            }
            f.onLaunch = { _, _, completion in
                f.deliver(request)
                completion(true)
            }
            let launcher = f.launcher()
            let first = Task { await launcher.open(f.route(request)) }
            try await f.eventually { !f.validations.isEmpty }
            let second = Task { await launcher.open(f.route(request)) }
            first.cancel()
            gate.open()
            let result = try await f.finish { await second.value }
            XCTAssertTrue(result)
            let cancelledResult = await first.value
            XCTAssertTrue(cancelledResult)
            XCTAssertEqual(f.launches.count, 1)
        }

        func testQueuedDeliveryUsesItsAdmissionBudget() async throws {
            let f = try fixture()
            let firstRequest = try f.request()
            let secondRequest = try f.request(id: 2)
            var firstCallback: ((Bool) -> Void)?
            f.onLaunch = { _, route, completion in
                if route == f.route(firstRequest) {
                    firstCallback = completion
                } else {
                    f.deliver(secondRequest)
                    completion(true)
                }
            }
            let launcher = f.launcher(timeout: 500_000_000)
            let first = Task { await launcher.open(f.route(firstRequest)) }
            try await f.eventually { firstCallback != nil }
            let second = Task {
                await launcher.open(f.route(secondRequest), waitDeadline: f.clock.now + 50_000_000)
            }
            try await f.eventually { f.clock.deadlines.contains(f.clock.now + 50_000_000) }
            f.clock.advance(to: f.clock.now + 50_000_000)
            let earlyResult = await second.value
            XCTAssertFalse(earlyResult)
            XCTAssertEqual(f.launches.count, 1)
            let firstResult = try await f.finish { await first.value }
            XCTAssertFalse(firstResult)
            firstCallback?(true)
            for _ in 0..<50 { await Task.yield() }
            XCTAssertEqual(f.launches.map(\.route), [f.route(firstRequest)])
            let later = try await f.finish { await launcher.open(f.route(secondRequest)) }
            XCTAssertTrue(later)
        }

        func testFailedSharedDeliveryAllowsLaterRetry() async throws {
            let f = try fixture()
            let request = try f.request()
            let gate = NativeAgentLauncherTestFixture.Gate()
            defer { gate.open() }
            f.onValidate = { _ in
                await gate.wait()
                return false
            }
            let launcher = f.launcher()
            let first = Task { await launcher.open(f.route(request)) }
            try await f.eventually { !f.validations.isEmpty }
            let secondDeadline = f.clock.now + 4_000_000_000
            let second = Task { await launcher.open(f.route(request), waitDeadline: secondDeadline) }
            try await f.eventually { f.clock.deadlines.contains(secondDeadline) }
            gate.open()
            let firstResult = try await f.finish { await first.value }
            let secondResult = await second.value
            XCTAssertFalse(firstResult)
            XCTAssertFalse(secondResult)
            XCTAssertTrue(f.launches.isEmpty)
            XCTAssertEqual(f.validations.count, 1)
            f.onValidate = nil
            f.onLaunch = { _, _, completion in
                f.deliver(request)
                completion(true)
            }
            let retried = try await f.finish { await launcher.open(f.route(request)) }
            XCTAssertTrue(retried)
            XCTAssertEqual(f.launches.count, 1)
        }

        func testCallerDeadlineDoesNotCancelSharedDelivery() async throws {
            let f = try fixture()
            let request = try f.request()
            let gate = NativeAgentLauncherTestFixture.Gate()
            f.onValidate = { _ in
                await gate.wait()
                return true
            }
            f.onLaunch = { _, _, completion in
                f.deliver(request)
                completion(true)
            }
            let launcher = f.launcher()
            let first = Task { await launcher.open(f.route(request), waitDeadline: f.clock.now + 50_000_000) }
            try await f.eventually { !f.validations.isEmpty }
            let second = Task { await launcher.open(f.route(request)) }
            f.clock.advance(to: f.clock.now + 50_000_000)
            let timedOut = await first.value
            XCTAssertFalse(timedOut)
            gate.open()
            let result = try await f.finish { await second.value }
            XCTAssertTrue(result)
            XCTAssertEqual(f.launches.count, 1)
        }

        func testExpiredSuspendedDeliveryDoesNotBlockExplicitRetry() async throws {
            let f = try fixture()
            let request = try f.request()
            let gate = NativeAgentLauncherTestFixture.Gate()
            f.onValidate = { _ in
                if f.validations.count == 1 { await gate.wait() }
                return true
            }
            f.onLaunch = { _, _, completion in f.deliver(request); completion(true) }
            let launcher = f.launcher()
            let first = Task { await launcher.open(f.route(request)) }
            try await f.eventually { f.validations.count == 1 }
            f.clock.advance(to: f.clock.now + 5_000_000_000)
            let expired = await first.value
            XCTAssertFalse(expired)
            let retried = try await f.finish { await launcher.open(f.route(request)) }
            XCTAssertTrue(retried)
            gate.open()
            for _ in 0..<30 { await Task.yield() }
            XCTAssertEqual(f.launches.count, 1)
        }

        func testExpiredCallerDoesNotStartWork() async throws {
            let f = try fixture()
            let request = try f.request()
            let result = await f.launcher().open(f.route(request), waitDeadline: f.clock.now)
            XCTAssertFalse(result)
            let reactivated = await f.launcher().reactivate(f.route(request), waitDeadline: f.clock.now)
            XCTAssertFalse(reactivated)
            XCTAssertTrue(f.loads.isEmpty)
            XCTAssertTrue(f.validations.isEmpty)
            XCTAssertTrue(f.launches.isEmpty)
        }

        func testReactivationTimeoutDoesNotWaitForValidationOrBlockRetry() async throws {
            let f = try fixture()
            let request = try f.request()
            f.deliver(request)
            let gate = NativeAgentLauncherTestFixture.Gate()
            defer { gate.open() }
            f.onValidate = { _ in
                if f.validations.count == 1 { await gate.wait() }
                return true
            }
            f.onLaunch = { _, _, completion in completion(true) }
            let launcher = f.launcher(timeout: 100_000_000)
            let start = f.clock.now
            let expired = try await f.finish { await launcher.reactivate(f.route(request)) }
            XCTAssertFalse(expired)
            XCTAssertEqual(f.clock.now, start + 100_000_000)
            XCTAssertTrue(f.launches.isEmpty)
            let retried = try await f.finish { await launcher.reactivate(f.route(request)) }
            XCTAssertTrue(retried)
            gate.open()
            for _ in 0..<30 { await Task.yield() }
            XCTAssertEqual(f.launches.count, 1)
            XCTAssertTrue(f.clears.isEmpty)
            XCTAssertTrue(f.quits.isEmpty)
        }

        func testCancelledReactivationReturnsWithoutRepairingOrFocusingAfterValidation() async throws {
            for build in ["148", "147"] {
                let f = try fixture()
                let request = try f.request()
                f.deliver(request, runtime: f.runtime(build: build))
                let gate = NativeAgentLauncherTestFixture.Gate()
                defer { gate.open() }
                f.onValidate = { _ in
                    await gate.wait()
                    return true
                }
                f.onLaunch = { _, _, completion in completion(true) }
                let launcher = f.launcher()
                let started = f.clock.now
                var result: Bool?
                let task = Task { result = await launcher.reactivate(f.route(request)) }
                try await f.eventually { !f.validations.isEmpty }
                task.cancel()
                try await f.eventually { result != nil }
                XCTAssertEqual(result, false)
                XCTAssertEqual(f.clock.now, started)
                gate.open()
                await task.value
                for _ in 0..<30 { await Task.yield() }
                XCTAssertTrue(f.launches.isEmpty)
                XCTAssertTrue(f.quits.isEmpty)
                XCTAssertTrue(f.clears.isEmpty)
                XCTAssertTrue(f.clock.deadlines.isEmpty)
            }
        }

        func testReactivationFallbackPreservesRemainingCallerBudget() async throws {
            let f = try fixture()
            let request = try f.request()
            var reads = 0
            f.onLoad = { _ in
                reads += 1
                if reads == 1 { f.clock.advance(to: f.clock.now + 80_000_000) }
                return .found(request)
            }
            f.onLaunch = { _, _, _ in }
            let started = f.clock.now
            let launcher = f.launcher()
            let result = try await f.finish {
                await launcher.reactivate(f.route(request), waitDeadline: started + 100_000_000)
            }
            XCTAssertFalse(result)
            XCTAssertEqual(f.clock.now, started + 100_000_000)
            f.clock.advance(to: started + 5_080_000_000)
            for _ in 0..<30 { await Task.yield() }
            XCTAssertEqual(f.launches.count, 1)
        }

    }
#endif
