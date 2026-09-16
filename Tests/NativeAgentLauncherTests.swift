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

        private func context(
            _ fixture: NativeAgentLauncherTestFixture, _ snapshot: ExtensionBridge.Snapshot,
            duration: TimeInterval = 300
        ) -> ExtensionBridge.NativeExecutionContext {
            .init(
                revisions: snapshot.revisions, observedAt: fixture.clock.date,
                executionDeadline: fixture.clock.date.addingTimeInterval(duration), fenceToken: UUID())
        }

        func testQuietRecoveryRequiresStagedWorkAndExactLiveOwner() async throws {
            let f = try fixture()
            let request = try f.request()
            let launcher = f.launcher()
            f.deliver(request)
            let pending = await launcher.hasCompatibleApprovalDelivery(
                handle: request.handle, nativeDeliveryNonce: request.nativeDeliveryNonce)
            XCTAssertFalse(pending)
            XCTAssertTrue(f.validations.isEmpty)
            f.deliver(request, staged: true)
            let staged = await launcher.hasCompatibleApprovalDelivery(
                handle: request.handle, nativeDeliveryNonce: request.nativeDeliveryNonce)
            XCTAssertTrue(staged)
            f.processes[42] = f.runtime(instance: UUID())
            let replaced = await launcher.hasCompatibleApprovalDelivery(
                handle: request.handle, nativeDeliveryNonce: request.nativeDeliveryNonce)
            XCTAssertFalse(replaced)
            f.processes.removeAll()
            let absent = await launcher.hasCompatibleApprovalDelivery(
                handle: request.handle, nativeDeliveryNonce: request.nativeDeliveryNonce)
            XCTAssertFalse(absent)
            f.deliver(request, runtime: f.runtime(build: "147"), staged: true)
            let incompatible = await launcher.hasCompatibleApprovalDelivery(
                handle: request.handle, nativeDeliveryNonce: request.nativeDeliveryNonce)
            XCTAssertFalse(incompatible)
            XCTAssertTrue(f.quits.isEmpty)
            XCTAssertTrue(f.clears.isEmpty)
            XCTAssertTrue(f.launches.isEmpty)
        }

        func testReceiptInspectionRecognizesQueuedAndExecutingOwners() async throws {
            for executing in [false, true] {
                let f = try fixture()
                let request = try f.request()
                f.deliver(request, staged: true, executing: executing)
                let status = await f.launcher().currentApprovalDeliveryStatus(
                    handle: request.handle, nativeDeliveryNonce: request.nativeDeliveryNonce)
                XCTAssertEqual(status, .delivered)
                XCTAssertTrue(f.clears.isEmpty)
            }
        }

        func testPendingApprovalPollingValidatesCodeOnlyAfterDecisionIsStaged() async throws {
            let f = try fixture()
            let request = try f.request()
            f.deliver(request)
            let launcher = f.launcher()
            for _ in 0..<3 {
                let delivered = await launcher.ensureApprovalDelivery(handle: request.handle, mode: .page)
                XCTAssertTrue(delivered)
            }
            XCTAssertTrue(f.validations.isEmpty)
            XCTAssertTrue(f.launches.isEmpty)

            let quiet = await launcher.ensureApprovalDelivery(handle: request.handle, mode: .manualRecovery)
            XCTAssertFalse(quiet)
            XCTAssertTrue(f.validations.isEmpty)

            f.deliver(request, staged: true)
            f.onValidate = { _ in false }
            let delivered = await launcher.ensureApprovalDelivery(handle: request.handle, mode: .page)
            XCTAssertFalse(delivered)
            XCTAssertEqual(f.validations.count, 1)
        }

        func testPendingApprovalPollingRejectsChangedRuntimeIdentity() async throws {
            let f = try fixture()
            let request = try f.request()
            f.deliver(request)
            let launcher = f.launcher()
            let initial = await launcher.ensureApprovalDelivery(handle: request.handle, mode: .page)
            XCTAssertTrue(initial)

            f.processes[42] = f.runtime(instance: UUID())
            let replaced = await launcher.ensureApprovalDelivery(handle: request.handle, mode: .page)
            XCTAssertFalse(replaced)
            XCTAssertTrue(f.launches.isEmpty)
        }

        func testPendingApprovalPollingHonorsDeadlineAfterLoading() async throws {
            let f = try fixture()
            let request = try f.request()
            f.deliver(request)
            let deadline = f.clock.now + 100_000_000
            f.onLoad = { _ in
                f.clock.advance(to: deadline)
                return .found(f.snapshots[request.handle]!)
            }
            let delivered = await f.launcher().ensureApprovalDelivery(
                handle: request.handle, mode: .page, waitDeadline: deadline)
            XCTAssertFalse(delivered)
            XCTAssertTrue(f.validations.isEmpty)
            XCTAssertTrue(f.launches.isEmpty)
        }

        func testPendingApprovalPollingRedeliversAfterHelperExit() async throws {
            let f = try fixture()
            let request = try f.request()
            f.deliver(request)
            f.processes.removeAll()
            f.onLaunch = { _, _, completion in
                f.deliver(request, runtime: f.runtime(pid: 43))
                completion(true)
            }
            let launcher = f.launcher()
            let delivered = try await f.finish {
                await launcher.ensureApprovalDelivery(handle: request.handle, mode: .page)
            }
            XCTAssertTrue(delivered)
            XCTAssertEqual(f.launches.count, 1)
            XCTAssertFalse(f.validations.isEmpty)
        }

        func testMissingReceiptNeedsDeliveryAndAbsentOwnerIsCleared() async throws {
            let f = try fixture()
            let request = try f.request()
            let launcher = f.launcher()
            let unowned = await launcher.currentApprovalDeliveryStatus(
                handle: request.handle, nativeDeliveryNonce: request.nativeDeliveryNonce)
            XCTAssertEqual(unowned, .needsDelivery)
            f.deliver(request, staged: true)
            let receipt = f.snapshots[request.handle]!.nativeDeliveryReceipt!
            f.processes.removeAll()
            let absent = await launcher.currentApprovalDeliveryStatus(
                handle: request.handle, nativeDeliveryNonce: request.nativeDeliveryNonce)
            XCTAssertEqual(absent, .needsDelivery)
            XCTAssertEqual(f.clears, [receipt])
            XCTAssertNil(f.snapshots[request.handle]?.nativeDeliveryReceipt)
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
            let status = await f.launcher().currentApprovalDeliveryStatus(
                handle: request.handle, nativeDeliveryNonce: request.nativeDeliveryNonce)
            XCTAssertEqual(status, .unavailable)
            XCTAssertTrue(f.clears.isEmpty)
        }

        func testIncompatibleOwnerExitsBeforeReceiptClear() async throws {
            let f = try fixture()
            let request = try f.request()
            f.deliver(request, runtime: f.runtime(build: "147"), staged: true, executing: true)
            f.onQuit = { _ in true }
            var result: NativeAgentLauncher.ExistingDeliveryStatus?
            let launcher = f.launcher()
            let task = Task {
                result = await launcher.currentApprovalDeliveryStatus(
                    handle: request.handle, nativeDeliveryNonce: request.nativeDeliveryNonce)
            }
            try await f.eventually { f.quits == [42] && !f.clock.deadlines.isEmpty }
            XCTAssertTrue(f.clears.isEmpty)
            f.processes.removeAll()
            f.clock.advance(to: f.clock.deadlines.first!)
            await task.value
            XCTAssertEqual(result, .needsDelivery)
            XCTAssertEqual(f.clears.count, 1)
        }

        func testReceiptReplacementDuringReloadPreventsQuittingOldOwner() async throws {
            let f = try fixture()
            let request = try f.request()
            f.deliver(request, runtime: f.runtime(build: "147"))
            var reads = 0
            f.onLoad = { _ in
                reads += 1
                if reads == 2 { f.deliver(request, runtime: f.runtime(pid: 43)) }
                return .found(f.snapshots[request.handle]!)
            }
            let status = await f.launcher().currentApprovalDeliveryStatus(
                handle: request.handle, nativeDeliveryNonce: request.nativeDeliveryNonce)
            XCTAssertEqual(status, .delivered)
            XCTAssertTrue(f.quits.isEmpty)
            XCTAssertTrue(f.clears.isEmpty)
        }

        func testRuntimeReplacementAndDeadlineDuringVerificationPreventQuit() async throws {
            for expires in [false, true] {
                let f = try fixture()
                let request = try f.request()
                f.deliver(request, runtime: f.runtime(build: "147"))
                var validations = 0
                f.onValidate = { _ in
                    validations += 1
                    if validations == 1 {
                        if expires {
                            f.clock.advance(to: f.clock.now + 300_000_000)
                        } else {
                            f.processes[42] = f.runtime(instance: UUID())
                        }
                    }
                    return true
                }
                let status = await f.launcher().currentApprovalDeliveryStatus(
                    handle: request.handle, nativeDeliveryNonce: request.nativeDeliveryNonce)
                XCTAssertEqual(status, .unavailable)
                XCTAssertTrue(f.quits.isEmpty)
                XCTAssertTrue(f.clears.isEmpty)
            }
        }

        func testCancelledReceiptQueryDoesNotStartWork() async throws {
            for pending in [true, false] {
                let f = try fixture()
                let request = try f.request()
                f.setState(.responded, for: request)
                let gate = NativeAgentLauncherTestFixture.Gate()
                let launcher = f.launcher()
                let task = Task {
                    await gate.wait()
                    return await launcher.approvalDeliveryStatus(
                        handle: request.handle, nativeDeliveryNonce: request.nativeDeliveryNonce,
                        isPending: { pending })
                }
                task.cancel()
                gate.open()
                let result = await task.value
                XCTAssertEqual(result, .unavailable)
                XCTAssertTrue(f.loads.isEmpty)
                XCTAssertTrue(f.quits.isEmpty)
                XCTAssertTrue(f.clears.isEmpty)
            }
        }

        func testCancelledReceiptReadCannotRepairAfterSuspension() async throws {
            let f = try fixture()
            let request = try f.request()
            f.deliver(request, runtime: f.runtime(build: "147"))
            let gate = NativeAgentLauncherTestFixture.Gate()
            f.onLoad = { _ in
                await gate.wait()
                return .found(f.snapshots[request.handle]!)
            }
            let launcher = f.launcher()
            let task = Task {
                await launcher.approvalDeliveryStatus(
                    handle: request.handle, nativeDeliveryNonce: request.nativeDeliveryNonce,
                    isPending: { true }
                )
            }
            try await f.eventually { !f.loads.isEmpty }
            task.cancel()
            gate.open()
            let result = await task.value
            XCTAssertEqual(result, .unavailable)
            XCTAssertTrue(f.quits.isEmpty)
            XCTAssertTrue(f.clears.isEmpty)
            XCTAssertTrue(f.launches.isEmpty)
        }

        func testStagedApprovalCanBeExplicitlyReactivated() async throws {
            let f = try fixture()
            let request = try f.request()
            f.deliver(request)
            let delivered = f.snapshots[request.handle]!
            f.setState(.queued(
                request: request.request!,
                approval: .staged(.init(receipt: delivered.nativeDeliveryReceipt, executionContext: nil))
            ), for: request)
            f.onLaunch = { _, _, completion in completion(true) }
            let launcher = f.launcher()
            let result = try await f.finish { await launcher.reactivate(f.route(request)) }
            XCTAssertTrue(result)
            XCTAssertEqual(f.launches.count, 1)
            f.setState(.approving(
                request: request.request!,
                nativeApproval: .init(receipt: delivered.nativeDeliveryReceipt, executionContext: nil)
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

        func testFinalizationPreservesPollingCadenceAndExecutionBudget() async throws {
            for duration in [2.25, 300.0] {
                let f = try fixture()
                let request = try f.request()
                f.deliver(request, staged: true)
                let execution = context(f, request, duration: duration)
                let start = f.clock.now
                var validationTimes = [UInt64]()
                f.onValidate = { _ in
                    validationTimes.append(f.clock.now - start)
                    return true
                }
                let launcher = f.launcher()
                let result = try await f.finish {
                    await launcher.waitForFinalization(
                        handle: request.handle, configurationKey: request.configurationKey,
                        initialContext: execution, mode: .page)
                }
                guard case .pending = result else { return XCTFail("Expected a pending decision at expiry") }
                XCTAssertEqual(f.clock.now - start, UInt64(min(duration, 170) * 1_000_000_000))
                let times = Array(Set(f.loads.map { $0.1 - start })).sorted()
                XCTAssertEqual(
                    Array(times.prefix(5)), [0, 250_000_000, 500_000_000, 750_000_000, 1_000_000_000])
                XCTAssertTrue(f.launches.isEmpty)
                let seconds = Int(min(duration, 170).rounded(.up))
                let expectedValidationTimes: [UInt64] = [0] + (0..<seconds).map { UInt64($0) * 1_000_000_000 }
                XCTAssertEqual(validationTimes, expectedValidationTimes)
            }
        }

        func testExecutingFinalizationContinuesPastApprovalExpiryToIts170SecondBudget() async throws {
            let f = try fixture()
            let request = try f.request()
            f.deliver(request, staged: true, executing: true)
            let execution = context(f, request, duration: 1)
            let start = f.clock.now
            let launcher = f.launcher()
            let result = try await f.finish {
                await launcher.waitForFinalization(
                    handle: request.handle, configurationKey: request.configurationKey,
                    initialContext: execution, mode: .page)
            }
            guard case .pending = result else { return XCTFail("Expected executing work to remain pending") }
            XCTAssertEqual(f.clock.now - start, 170_000_000_000)
            XCTAssertTrue(f.launches.isEmpty)
            XCTAssertEqual(f.validations.count, 1)
        }

        func testFinalizationDistinguishesInitialAndLaterDeliveryFailure() async throws {
            for later in [false, true] {
                let f = try fixture()
                let request = try f.request()
                f.deliver(request, staged: true)
                let start = f.clock.now
                let execution = context(f, request)
                f.onValidate = { _ in later && f.clock.now - start < 1_000_000_000 }
                let launcher = f.launcher()
                let result = try await f.finish {
                    await launcher.waitForFinalization(
                        handle: request.handle, configurationKey: request.configurationKey,
                        initialContext: execution, mode: .page)
                }
                if later {
                    guard case .pending = result else { return XCTFail("Expected pending") }
                } else {
                    guard case .deliveryUnavailable = result else { return XCTFail("Expected unavailable") }
                }
                XCTAssertEqual(f.clock.now - start, later ? 1_000_000_000 : 0)
            }
        }

        func testFinalizationDoesNotBlockOtherDeliveryOrMixCallerContexts() async throws {
            let f = try fixture()
            let request = try f.request()
            f.deliver(request, staged: true)
            let launcher = f.launcher()
            let short = context(f, request, duration: 0.5)
            let long = context(f, request, duration: 1.5)
            let first = Task {
                await launcher.waitForFinalization(
                    handle: request.handle, configurationKey: request.configurationKey, initialContext: short,
                    mode: .page)
            }
            let second = Task {
                await launcher.waitForFinalization(
                    handle: request.handle, configurationKey: request.configurationKey, initialContext: long,
                    mode: .page)
            }
            f.onLaunch = { _, _, completion in completion(true) }
            let shown = try await f.finish {
                await launcher.open(.showWallet(workflowVersion: ExtensionBridge.workflowVersion))
            }
            XCTAssertTrue(shown)
            _ = try await f.finish { await first.value }
            XCTAssertEqual(f.clock.now, 1_500_000_000)
            _ = try await f.finish { await second.value }
            XCTAssertEqual(f.clock.now, 2_500_000_000)
        }

        func testQuietFinalizationDoesNotJoinActivePageDelivery() async throws {
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
            let page = Task { await launcher.open(f.route(request)) }
            try await f.eventually { !f.validations.isEmpty }
            let result = await launcher.waitForFinalization(
                handle: request.handle, configurationKey: request.configurationKey,
                initialContext: context(f, request), mode: .manualRecovery)
            guard case .deliveryUnavailable = result else {
                return XCTFail("Quiet recovery must not join the launch")
            }
            XCTAssertTrue(f.launches.isEmpty)
            gate.open()
            let delivered = try await f.finish { await page.value }
            XCTAssertTrue(delivered)
        }

        func testFinalizationRedeliversAfterHelperLoss() async throws {
            let f = try fixture()
            let request = try f.request()
            f.deliver(request, staged: true)
            let execution = context(f, request)
            let start = f.clock.now
            f.onLoad = { _ in
                if f.clock.now - start >= 1_000_000_000 && f.launches.isEmpty { f.processes.removeAll() }
                return .found(f.snapshots[request.handle]!)
            }
            f.onLaunch = { _, _, completion in
                f.deliver(request, runtime: f.runtime(pid: 43), staged: true)
                f.setState(.responded, for: request)
                completion(true)
            }
            let launcher = f.launcher()
            let result = try await f.finish {
                await launcher.waitForFinalization(
                    handle: request.handle, configurationKey: request.configurationKey,
                    initialContext: execution, mode: .page)
            }
            guard case .readyToRead = result else { return XCTFail("Expected completed response") }
            XCTAssertEqual(f.clears.count, 1)
            XCTAssertEqual(f.launches.count, 1)
        }
    }
#endif
