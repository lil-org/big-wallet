#if os(macOS)
    import Foundation
    import XCTest
    @testable import Big_Wallet

    @MainActor
    final class NativeApprovalResponseWaiterTests: XCTestCase {
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

        private func waiter(
            _ fixture: NativeAgentLauncherTestFixture,
            launcher: NativeAgentLauncher
        ) -> NativeApprovalResponseWaiter {
            NativeApprovalResponseWaiter(
                launcher: launcher,
                load: fixture.dependencies.load,
                uptime: { fixture.clock.now },
                wallClock: { fixture.clock.date },
                sleepUntil: fixture.clock.sleepUntil
            )
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
                let waiter = waiter(f, launcher: launcher)
                let result = try await f.finish {
                    await waiter.waitForResponse(
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
            let waiter = waiter(f, launcher: launcher)
            let result = try await f.finish {
                await waiter.waitForResponse(
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
                let waiter = waiter(f, launcher: launcher)
                let result = try await f.finish {
                    await waiter.waitForResponse(
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
            let waiter = waiter(f, launcher: launcher)
            let short = context(f, request, duration: 0.5)
            let long = context(f, request, duration: 1.5)
            let first = Task {
                await waiter.waitForResponse(
                    handle: request.handle, configurationKey: request.configurationKey, initialContext: short,
                    mode: .page)
            }
            let second = Task {
                await waiter.waitForResponse(
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
            let waiter = waiter(f, launcher: launcher)
            let page = Task { await launcher.open(f.route(request)) }
            try await f.eventually { !f.validations.isEmpty }
            let result = await waiter.waitForResponse(
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

        func testFinalizationInterruptsAfterHelperLossWithoutRelaunch() async throws {
            let f = try fixture()
            let request = try f.request()
            f.deliver(request, staged: true)
            let execution = context(f, request)
            let start = f.clock.now
            f.onLoad = { _ in
                if f.clock.now - start >= 1_000_000_000 && f.launches.isEmpty { f.processes.removeAll() }
                return .found(f.snapshots[request.handle]!)
            }
            f.onLaunch = { _, _, _ in XCTFail("An approved request must not be relaunched") }
            let launcher = f.launcher()
            let waiter = waiter(f, launcher: launcher)
            let result = try await f.finish {
                await waiter.waitForResponse(
                    handle: request.handle, configurationKey: request.configurationKey,
                    initialContext: execution, mode: .page)
            }
            guard case .readyToRead = result else { return XCTFail("Expected completed response") }
            XCTAssertEqual(f.clears.count, 1)
            XCTAssertTrue(f.launches.isEmpty)
        }

        func testCancellationStopsPollingWithoutReleasingExecutionOrLaunching() async throws {
            let f = try fixture()
            let request = try f.request()
            f.deliver(request, staged: true, executing: true)
            let waiter = waiter(f, launcher: f.launcher())
            let task = Task {
                await waiter.waitForResponse(
                    handle: request.handle,
                    configurationKey: request.configurationKey,
                    initialContext: context(f, request),
                    mode: .page
                )
            }
            try await f.eventually { f.clock.deadlines.contains(f.clock.now + 250_000_000) }
            let loads = f.loads.count
            task.cancel()
            let result = await task.value
            guard case .pending = result else { return XCTFail("Expected pending after cancellation") }
            XCTAssertEqual(f.loads.count, loads)
            XCTAssertEqual(f.snapshots[request.handle]?.phase, .approving)
            XCTAssertTrue(f.launches.isEmpty)
            XCTAssertTrue(f.clears.isEmpty)
        }
    }
#endif
