#if os(macOS)
    import Foundation
    import Synchronization
    import XCTest
    @testable import Big_Wallet

    func launcherTestDependencies(
        helperURL: @escaping @MainActor () -> URL? = { nil },
        validate: @escaping @MainActor (URL) async -> Bool = { _ in false },
        helpers: @escaping @MainActor () -> [NativeAgentLauncher.RuntimeHelper] = { [] },
        helper: @escaping @MainActor (Int32) -> NativeAgentLauncher.RuntimeHelper? = { _ in nil },
        identity: @escaping @MainActor (Int32) -> AmbientRuntimeIdentity? = { _ in nil },
        launch: @escaping NativeAgentLauncher.Launch = { _, _ in false },
        uptime: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
        sleepUntil: @escaping @MainActor (UInt64) async -> Void = { deadline in
            let now = DispatchTime.now().uptimeNanoseconds
            if deadline > now { try? await Task.sleep(nanoseconds: deadline - now) }
        }
    ) -> NativeAgentLauncher.Dependencies {
        .init(
            helperURL: helperURL, validate: validate, helpers: helpers, helper: helper,
            identity: identity, launch: launch,
            uptime: uptime, sleepUntil: sleepUntil)
    }

    @MainActor
    func approvalServiceTestDependencies(
        launcher: NativeAgentLauncher? = nil,
        load: @escaping @MainActor (ExtensionBridge.Handle) async -> ExtensionBridge.SnapshotResult = { _ in .missing },
        responseStatus: @escaping @MainActor (ExtensionBridge.Handle, String) async -> ExtensionBridge.ResponseStatusResult = { _, _ in .missing },
        maintainProfile: @escaping @MainActor (UUID?) async -> Void = { _ in },
        clearReceipt:
            @escaping @MainActor (ExtensionBridge.Handle, ExtensionBridge.NativeDeliveryReceipt) async ->
            ExtensionBridge.StoreMutationResult = { _, _ in .ownershipLost },
        uptime: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
        sleepUntil: @escaping @Sendable (UInt64) async -> Void = { deadline in
            let now = DispatchTime.now().uptimeNanoseconds
            if deadline > now { try? await Task.sleep(nanoseconds: deadline - now) }
        }
    ) -> NativeApprovalService.Dependencies {
        .init(
            launcher: launcher ?? NativeAgentLauncher(dependencies: launcherTestDependencies()),
            load: { await load($0) },
            responseStatus: { await responseStatus($0, $1) },
            maintainProfile: { await maintainProfile($0) },
            clearReceipt: { await clearReceipt($0, $1) },
            uptime: uptime, sleepUntil: sleepUntil)
    }

    @MainActor
    final class NativeApprovalServiceTestFixture {
        private var observers = [UUID: (condition: @MainActor () -> Bool, expectation: XCTestExpectation)]()
        private var gates = [TestGate<Void>]()
        private var launchGates = [TestGate<Bool>]()
        private var isClosing = false
        private var activeCallbacks = 0 { didSet { changed() } }
        let bundleURL: URL
        let clock = TestClock()
        var snapshots = [ExtensionBridge.Handle: ExtensionBridge.Snapshot]() { didSet { changed() } }
        var processes = [Int32: AmbientRuntimeIdentity]() { didSet { changed() } }
        var unidentifiedProcesses = [Int32: NativeAgentLauncher.RuntimeHelper]() { didSet { changed() } }
        var launches = [(target: NativeAgentLauncher.HelperTarget, route: NativeAgentRoute, time: UInt64)]() { didSet { changed() } }
        var quits = [Int32]() { didSet { changed() } }
        var clears = [ExtensionBridge.NativeDeliveryReceipt]() { didSet { changed() } }
        var validations = [URL]() { didSet { changed() } }
        var loads = [(ExtensionBridge.Handle, UInt64)]() { didSet { changed() } }
        var maintainedProfiles = [UUID?]() { didSet { changed() } }
        var responseStatusReads = [ExtensionBridge.Handle]() { didSet { changed() } }
        var responses = [ExtensionBridge.Handle: [String: Any]]() { didSet { changed() } }
        var onResponseStatus: (@MainActor (ExtensionBridge.Handle, String) async -> ExtensionBridge.ResponseStatusResult)?
        var onValidate: (@MainActor (URL) async -> Bool)?
        var onLoad: (@MainActor (ExtensionBridge.Handle) async -> ExtensionBridge.SnapshotResult)?
        var onLaunch:
            ((NativeAgentLauncher.HelperTarget, NativeAgentRoute, @escaping (Bool) -> Void) -> Void)?
        var onQuit: ((Int32) -> Bool)?
        var onClear:
            (
                @MainActor (ExtensionBridge.Handle, ExtensionBridge.NativeDeliveryReceipt) async ->
                    ExtensionBridge.StoreMutationResult
            )?

        init() throws {
            bundleURL = FileManager.default.temporaryDirectory.appendingPathComponent(
                "launcher-\(UUID()).app", isDirectory: true)
            let contents = bundleURL.appendingPathComponent("Contents", isDirectory: true)
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(
                fromPropertyList: [
                    "CFBundleIdentifier": "org.lil.wallet.ambient",
                    "CFBundlePackageType": "APPL", "CFBundleVersion": "148",
                    "CFBundleShortVersionString": "1.0.99",
                ], format: .xml, options: 0)
            try data.write(to: contents.appendingPathComponent("Info.plist"))
            _ = try XCTUnwrap(AmbientRuntimeIdentity.bundleVersion(at: bundleURL))
            clock.onRegistration = { [weak self] _ in Task { @MainActor in self?.changed() } }
            clock.onCompletion = { [weak self] _ in Task { @MainActor in self?.changed() } }
        }

        deinit { try? FileManager.default.removeItem(at: bundleURL) }

        func runtime(pid: Int32 = 42, build: String = "148", instance: UUID = UUID(), url: URL? = nil)
            -> AmbientRuntimeIdentity
        {
            .init(
                instanceIdentifier: instance, processIdentifier: pid,
                bundlePath: (url ?? bundleURL).standardizedFileURL.path,
                version: .init(marketing: "1.0.99", build: build),
                workflowVersion: ExtensionBridge.workflowVersion,
                launchedAt: Date(timeIntervalSince1970: Double(pid)))
        }

        func helper(_ pid: Int32) -> NativeAgentLauncher.RuntimeHelper? {
            if let unidentified = unidentifiedProcesses[pid] { return unidentified }
            guard let runtime = processes[pid] else { return nil }
            return .init(
                processIdentifier: pid, bundleURL: runtime.bundleURL,
                processStartDate: runtime.launchedAt,
                isRunning: { self.processes[pid] == runtime },
                requestQuit: {
                    self.quits.append(pid)
                    if let onQuit = self.onQuit { return onQuit(pid) }
                    self.processes[pid] = nil
                    return true
                })
        }

        func request(id: Int = 1, manual: Bool = false) throws -> ExtensionBridge.Snapshot {
            let body: [String: Any] = manual ? ["latestConfigurations": []] : ["address": ""]
            let request = try XCTUnwrap(
                SafariRequest(json: [
                    "id": id, "name": manual ? "switchAccount" : "requestAccounts",
                    "provider": manual ? "unknown" : "ethereum",
                    "host": "wallet.example", "configurationKey": "https://wallet.example",
                    "enqueueAttempt": String(format: "%032x", id),
                    "admissionDeadline": Int(
                        clock.date.addingTimeInterval(900).timeIntervalSince1970 * 1_000),
                    "workflowVersion": ExtensionBridge.workflowVersion,
                    "body": body,
                ]))
            let snapshot = ExtensionBridge.Snapshot(
                handle: .init(id: id, token: .init(value: UUID()), profileIdentifier: nil),
                state: .queued(request: request, approval: .unowned),
                nativeDeliveryNonce: .init(value: UUID()), host: request.host,
                configurationKey: request.configurationKey,
                revisions: ExtensionBridge.ProviderRevisions(rawValue: ["ethereum": 0, "solana": 0])!,
                createdAt: clock.date, enqueueAttempt: request.enqueueAttempt, sequence: id
            )
            snapshots[snapshot.handle] = snapshot
            return snapshot
        }

        func setState(_ state: ExtensionBridge.Snapshot.State, for snapshot: ExtensionBridge.Snapshot) {
            snapshots[snapshot.handle] = .init(
                handle: snapshot.handle, state: state, nativeDeliveryNonce: snapshot.nativeDeliveryNonce,
                host: snapshot.host, configurationKey: snapshot.configurationKey,
                revisions: snapshot.revisions, createdAt: snapshot.createdAt,
                enqueueAttempt: snapshot.enqueueAttempt, sequence: snapshot.sequence
            )
        }

        func deliver(
            _ snapshot: ExtensionBridge.Snapshot, runtime: AmbientRuntimeIdentity? = nil,
            executing: Bool = false
        ) {
            let runtime = runtime ?? self.runtime()
            processes[runtime.processIdentifier] = runtime
            let receipt = ExtensionBridge.NativeDeliveryReceipt(
                nativeDeliveryNonce: snapshot.nativeDeliveryNonce, owner: runtime.nativeDeliveryOwner!
            )
            let approval = ExtensionBridge.Snapshot.NativeApproval(
                receipt: receipt, approvedAt: clock.date,
                executionContext: snapshots[snapshot.handle]?.nativeExecutionContext
            )
            setState(
                executing
                    ? .approving(request: snapshot.request!, nativeApproval: approval)
                    : .queued(
                        request: snapshot.request!, approval: .delivered(receipt)
                    ),
                for: snapshot)
        }

        var launcherDependencies: NativeAgentLauncher.Dependencies {
            launcherTestDependencies(
                helperURL: { self.isClosing ? nil : self.bundleURL },
                validate: { url in
                    guard !self.isClosing else { return false }
                    self.activeCallbacks += 1
                    defer { self.activeCallbacks -= 1 }
                    self.validations.append(url)
                    return await self.onValidate?(url)
                        ?? (url.standardizedFileURL == self.bundleURL.standardizedFileURL)
                },
                helpers: {
                    guard !self.isClosing else { return [] }
                    return self.processes.keys.sorted().compactMap(self.helper)
                        + Array(self.unidentifiedProcesses.values)
                },
                helper: helper,
                identity: { self.processes[$0] },
                launch: { target, url in
                    guard !self.isClosing, let route = NativeAgentRoute(url: url) else { return false }
                    self.activeCallbacks += 1
                    defer { self.activeCallbacks -= 1 }
                    self.launches.append((target, route, self.clock.uptimeNanoseconds))
                    guard let onLaunch = self.onLaunch else { return false }
                    let gate = TestGate<Bool>()
                    self.launchGates.append(gate)
                    defer { self.launchGates.removeAll { $0 === gate }; self.changed() }
                    onLaunch(target, route) { gate.resolve($0) }
                    self.changed()
                    return await gate.wait()
                },
                uptime: { [clock] in clock.uptimeNanoseconds }, sleepUntil: { [clock] in try? await clock.sleep(until: $0) }
            )
        }

        var dependencies: NativeApprovalService.Dependencies {
            approvalServiceTestDependencies(
                launcher: NativeAgentLauncher(dependencies: launcherDependencies),
                load: { handle in
                    guard !self.isClosing else { return .missing }
                    self.activeCallbacks += 1
                    defer { self.activeCallbacks -= 1 }
                    self.loads.append((handle, self.clock.uptimeNanoseconds))
                    if let onLoad = self.onLoad { return await onLoad(handle) }
                    return self.snapshots[handle].map(ExtensionBridge.SnapshotResult.found) ?? .missing
                },
                responseStatus: { handle, key in
                    guard !self.isClosing else { return .missing }
                    self.activeCallbacks += 1
                    defer { self.activeCallbacks -= 1 }
                    self.responseStatusReads.append(handle)
                    if let onResponseStatus = self.onResponseStatus { return await onResponseStatus(handle, key) }
                    guard let snapshot = self.snapshots[handle], snapshot.configurationKey == key else { return .missing }
                    return snapshot.phase == .responded ? .ready : .pending
                },
                maintainProfile: { self.maintainedProfiles.append($0) },
                clearReceipt: { handle, receipt in
                    guard !self.isClosing else { return .ownershipLost }
                    self.activeCallbacks += 1
                    defer { self.activeCallbacks -= 1 }
                    self.clears.append(receipt)
                    if let onClear = self.onClear { return await onClear(handle, receipt) }
                    guard let snapshot = self.snapshots[handle], snapshot.nativeDeliveryReceipt == receipt,
                        let request = snapshot.request
                    else { return .ownershipLost }
                    if snapshot.nativeApproval != nil {
                        self.responses[handle] = ResponseToExtension(
                            for: request, payload: .error(.approvalInterrupted)
                        ).json
                        self.setState(.responded, for: snapshot)
                    } else {
                        self.setState(.queued(request: request, approval: .unowned), for: snapshot)
                    }
                    return .persisted
                },
                uptime: { [clock] in clock.uptimeNanoseconds },
                sleepUntil: { [clock] in try? await clock.sleep(until: $0) }
            )
        }

        func service(timeout: UInt64 = 5_000_000_000) -> NativeApprovalService {
            .init(dependencies: dependencies, launchTimeoutNanoseconds: timeout)
        }

        func maintain(
            _ service: NativeApprovalService,
            _ snapshot: ExtensionBridge.Snapshot,
            allowDelivery: Bool = true
        ) async -> NativeApprovalService.ReconciliationResult {
            await service.reconcile(
                .init(handle: snapshot.handle, configurationKey: snapshot.configurationKey),
                intent: .maintenance(allowDelivery: allowDelivery)
            )
        }

        func route(_ snapshot: ExtensionBridge.Snapshot) -> NativeAgentRoute {
            .approval(
                workflowVersion: ExtensionBridge.workflowVersion, handle: snapshot.handle,
                nativeDeliveryNonce: snapshot.nativeDeliveryNonce)
        }

        func advanceClock(by interval: UInt64, steps: Int = 1, waiters: Int = 1) async throws {
            for _ in 0..<steps {
                let deadline = clock.uptimeNanoseconds + interval
                try await eventually { self.clock.pendingSleeps.map(\.deadline).filter { $0 == deadline }.count >= waiters }
                clock.advance(to: deadline)
            }
        }

        func finish<Value: Sendable>(
            afterStarting: () async throws -> Void = {},
            _ operation: @escaping @MainActor () async -> Value
        ) async throws -> Value {
            let completed = XCTestExpectation(description: "approval operation completed")
            let task = Task {
                let result = await operation()
                completed.fulfill()
                return result
            }
            defer { task.cancel() }
            try await afterStarting()
            guard await XCTWaiter.fulfillment(of: [completed], timeout: 20) == .completed else {
                XCTFail("Approval operation did not complete")
                throw CocoaError(.coderInvalidValue)
            }
            return await task.value
        }

        func eventually(_ condition: @escaping @MainActor () -> Bool) async throws {
            guard !condition() else { return }
            let id = UUID()
            let observed = XCTestExpectation(description: "approval fixture changed")
            observers[id] = (condition, observed)
            defer { observers.removeValue(forKey: id) }
            guard await XCTWaiter.fulfillment(of: [observed], timeout: 2) == .completed else {
                XCTFail("Approval service condition did not become true")
                throw CocoaError(.coderInvalidValue)
            }
        }

        private func changed() {
            Task { @MainActor [weak self] in
                guard let self else { return }
                for (id, observer) in observers where observer.condition() {
                    observers.removeValue(forKey: id)
                    observer.expectation.fulfill()
                }
            }
        }

        func waitForCallbacks() async throws {
            try await eventually { self.activeCallbacks == 0 && self.clock.activeSleepCount == 0 }
        }

        func makeGate() -> TestGate<Void> {
            let gate = TestGate<Void>()
            gates.append(gate)
            return gate
        }

        func cleanup() async throws {
            isClosing = true
            onValidate = nil
            onLoad = nil
            onLaunch = nil
            onQuit = nil
            onClear = nil
            onResponseStatus = nil
            gates.forEach { $0.resolve(()) }
            launchGates.forEach { $0.resolve(false) }
            clock.onRegistration = { [weak clock] sleep in clock?.wake(sleep.id) }
            clock.pendingSleeps.forEach { clock.wake($0.id) }
            try await eventually { self.activeCallbacks == 0 && self.clock.activeSleepCount == 0 }
            snapshots.removeAll()
            processes.removeAll()
            unidentifiedProcesses.removeAll()
            gates.removeAll()
            try FileManager.default.removeItem(at: bundleURL)
        }
    }
#endif
