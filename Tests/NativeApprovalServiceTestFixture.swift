#if os(macOS)
    import Foundation
    import XCTest
    @testable import Big_Wallet

    func launcherTestDependencies(
        helperURL: @escaping @MainActor () -> URL? = { nil },
        validate: @escaping @MainActor (URL) async -> Bool = { _ in false },
        helpers: @escaping @MainActor () -> [NativeAgentLauncher.RuntimeHelper] = { [] },
        helper: @escaping @MainActor (Int32) -> NativeAgentLauncher.RuntimeHelper? = { _ in nil },
        identity: @escaping @MainActor (Int32) -> AmbientRuntimeIdentity? = { _ in nil },
        launch: @escaping NativeAgentLauncher.Launch = { _, _, completion in completion(false) },
        uptime: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
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
        uptime: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
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
        final class Clock: @unchecked Sendable {
            private let lock = NSLock()
            private var uptime: UInt64 = 1_000_000_000
            private var wallTime = Date(timeIntervalSince1970: 1_800_000_000)
            private var waiters = [UUID: (UInt64, CheckedContinuation<Void, Never>)]()

            var now: UInt64 { lock.withLock { uptime } }
            var date: Date { lock.withLock { wallTime } }
            var deadlines: [UInt64] { lock.withLock { waiters.values.map { $0.0 }.sorted() } }

            func sleepUntil(_ deadline: UInt64) async {
                let id = UUID()
                await withTaskCancellationHandler {
                    await withCheckedContinuation { continuation in
                        let shouldWait = lock.withLock {
                            guard !Task.isCancelled, deadline > uptime else { return false }
                            waiters[id] = (deadline, continuation)
                            return true
                        }
                        if !shouldWait { continuation.resume() }
                    }
                } onCancel: {
                    let continuation = self.lock.withLock { self.waiters.removeValue(forKey: id)?.1 }
                    continuation?.resume()
                }
            }

            func advance(to deadline: UInt64) {
                let ready = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
                    guard deadline >= uptime else { return [] }
                    wallTime += Double(deadline - uptime) / 1_000_000_000
                    uptime = deadline
                    let ready = waiters.filter { $0.value.0 <= uptime }
                    for id in ready.keys { waiters[id] = nil }
                    return ready.values.map { $0.1 }
                }
                ready.forEach { $0.resume() }
            }
        }

        final class Gate: @unchecked Sendable {
            private let lock = NSLock()
            private var isOpen = false
            private var waiters = [CheckedContinuation<Void, Never>]()
            func wait() async {
                await withCheckedContinuation { continuation in
                    let shouldWait = lock.withLock {
                        guard !isOpen else { return false }
                        waiters.append(continuation)
                        return true
                    }
                    if !shouldWait { continuation.resume() }
                }
            }
            func open() {
                let pending = lock.withLock {
                    isOpen = true
                    let pending = waiters
                    waiters.removeAll()
                    return pending
                }
                pending.forEach { $0.resume() }
            }
        }

        let bundleURL: URL
        let clock = Clock()
        var snapshots = [ExtensionBridge.Handle: ExtensionBridge.Snapshot]()
        var processes = [Int32: AmbientRuntimeIdentity]()
        var unidentifiedProcesses = [Int32: NativeAgentLauncher.RuntimeHelper]()
        var launches = [(target: NativeAgentLauncher.HelperTarget, route: NativeAgentRoute, time: UInt64)]()
        var quits = [Int32]()
        var clears = [ExtensionBridge.NativeDeliveryReceipt]()
        var validations = [URL]()
        var loads = [(ExtensionBridge.Handle, UInt64)]()
        var maintainedProfiles = [UUID?]()
        var responseStatusReads = [ExtensionBridge.Handle]()
        var responses = [ExtensionBridge.Handle: [String: Any]]()
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
        }

        deinit { try? FileManager.default.removeItem(at: bundleURL) }

        func runtime(pid: Int32 = 42, build: String = "148", instance: UUID = UUID(), url: URL? = nil)
            -> AmbientRuntimeIdentity
        {
            .init(
                instanceIdentifier: instance, processIdentifier: pid,
                bundlePath: (url ?? bundleURL).standardizedFileURL.path,
                version: .init(marketing: "1.0.99", build: build),
                runtimeProtocolVersion: AmbientRuntimeIdentity.currentRuntimeProtocolVersion,
                supportedWorkflowVersions: [ExtensionBridge.workflowVersion],
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
                helperURL: { self.bundleURL },
                validate: { url in
                    self.validations.append(url)
                    return await self.onValidate?(url)
                        ?? (url.standardizedFileURL == self.bundleURL.standardizedFileURL)
                },
                helpers: {
                    self.processes.keys.sorted().compactMap(self.helper)
                        + Array(self.unidentifiedProcesses.values)
                },
                helper: helper,
                identity: { self.processes[$0] },
                launch: { target, url, completion in
                    guard let route = NativeAgentRoute(url: url) else {
                        completion(false)
                        return
                    }
                    self.launches.append((target, route, self.clock.now))
                    if let onLaunch = self.onLaunch {
                        onLaunch(target, route, completion)
                    } else {
                        completion(false)
                    }
                },
                uptime: { [clock] in clock.now }, sleepUntil: clock.sleepUntil
            )
        }

        var dependencies: NativeApprovalService.Dependencies {
            approvalServiceTestDependencies(
                launcher: NativeAgentLauncher(dependencies: launcherDependencies),
                load: { handle in
                    self.loads.append((handle, self.clock.now))
                    if let onLoad = self.onLoad { return await onLoad(handle) }
                    return self.snapshots[handle].map(ExtensionBridge.SnapshotResult.found) ?? .missing
                },
                responseStatus: { handle, key in
                    self.responseStatusReads.append(handle)
                    if let onResponseStatus = self.onResponseStatus { return await onResponseStatus(handle, key) }
                    guard let snapshot = self.snapshots[handle], snapshot.configurationKey == key else { return .missing }
                    return snapshot.phase == .responded ? .ready : .pending
                },
                maintainProfile: { self.maintainedProfiles.append($0) },
                clearReceipt: { handle, receipt in
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
                uptime: { [clock] in clock.now },
                sleepUntil: { [clock] in await clock.sleepUntil($0) }
            )
        }

        func service(timeout: UInt64 = 5_000_000_000) -> NativeApprovalService {
            .init(dependencies: dependencies, launchTimeoutNanoseconds: timeout)
        }

        func maintain(
            _ service: NativeApprovalService,
            _ snapshot: ExtensionBridge.Snapshot,
            allowDelivery: Bool = true
        ) async -> ExtensionBridge.ResponseStatusResult {
            await service.maintainRequest(
                handle: snapshot.handle, configurationKey: snapshot.configurationKey,
                allowDelivery: allowDelivery
            )
        }

        func route(_ snapshot: ExtensionBridge.Snapshot) -> NativeAgentRoute {
            .approval(
                workflowVersion: ExtensionBridge.workflowVersion, handle: snapshot.handle,
                nativeDeliveryNonce: snapshot.nativeDeliveryNonce)
        }

        func advanceClock(by interval: UInt64, steps: Int = 1, waiters: Int = 1) async throws {
            for _ in 0..<steps {
                let deadline = clock.now + interval
                try await eventually { self.clock.deadlines.filter { $0 == deadline }.count >= waiters }
                clock.advance(to: deadline)
            }
        }

        func finish<Value>(
            afterStarting: () async throws -> Void = {},
            _ operation: @escaping @MainActor () async -> Value
        ) async throws -> Value {
            var result: Value?
            let task = Task { result = await operation() }
            defer { task.cancel() }
            try await afterStarting()
            for _ in 0..<20_000 {
                if let result { return result }
                try await Task.sleep(for: .milliseconds(1))
            }
            throw CocoaError(.coderInvalidValue)
        }

        func eventually(_ condition: () -> Bool) async throws {
            for _ in 0..<2_000 {
                if condition() { return }
                try await Task.sleep(for: .milliseconds(1))
            }
            XCTFail("Approval service condition did not become true")
            throw CocoaError(.coderInvalidValue)
        }
    }
#endif
