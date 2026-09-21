// ∅ 2026 lil org

import Foundation

actor NativeApprovalService {
    enum ApprovalDeliveryResult: Equatable {
        case pending, responseReady, unavailable
    }

    private enum ReceiptStatus: Sendable {
        case delivered, responseReady, needsDelivery, terminal, unavailable
    }

    private enum ReceiptPolicy {
        case delivery, pageRead, manualRecovery
    }

    struct Dependencies {
        let launcher: NativeAgentLauncher
        let load: (ExtensionBridge.Handle) async -> ExtensionBridge.SnapshotResult
        let loadManualSwitch: (
            ExtensionBridge.Handle, String
        ) async -> ExtensionBridge.SnapshotResult
        let beginExecutionRead: (
            ExtensionBridge.Handle, String, ExtensionBridge.ProviderRevisions, Date
        ) async -> ExtensionBridge.NativeExecutionReadResult
        let readResponse: (
            ExtensionBridge.Handle, String
        ) async -> ExtensionBridge.ResponseReadResult
        let clearReceipt: (
            ExtensionBridge.Handle,
            ExtensionBridge.NativeDeliveryReceipt
        ) async -> ExtensionBridge.StoreMutationResult
        let uptime: () -> UInt64
        let wallClock: () -> Date
        let sleepUntil: (UInt64) async -> Void

        @MainActor
        static var live: Self {
            Self(
                launcher: NativeAgentLauncher(),
                load: { await ExtensionBridge.shared.load(handle: $0) },
                loadManualSwitch: {
                    await ExtensionBridge.shared.loadManualSwitch(handle: $0, configurationKey: $1)
                },
                beginExecutionRead: {
                    await ExtensionBridge.shared.beginNativeExecutionRead(
                        handle: $0, configurationKey: $1, revisions: $2, executionDeadline: $3
                    )
                },
                readResponse: {
                    await ExtensionBridge.shared.readResponse(
                        id: $0.id, configurationKey: $1,
                        requestToken: $0.requestToken, profileIdentifier: $0.profileIdentifier
                    )
                },
                clearReceipt: { handle, receipt in
                    await ExtensionBridge.shared.clearNativeDeliveryReceipt(
                        handle: handle,
                        nativeDeliveryNonce: receipt.nativeDeliveryNonce,
                        runtimeInstanceIdentifier: receipt.owner.runtimeInstanceIdentifier
                    )
                },
                uptime: { DispatchTime.now().uptimeNanoseconds },
                wallClock: Date.init,
                sleepUntil: { deadline in
                    let now = DispatchTime.now().uptimeNanoseconds
                    guard deadline > now else { return }
                    try? await Task.sleep(nanoseconds: deadline - now)
                }
            )
        }

        func deadline(after interval: UInt64) -> UInt64 {
            let result = uptime().addingReportingOverflow(interval)
            return result.overflow ? UInt64.max : result.partialValue
        }

        func wait(_ interval: UInt64) async {
            await sleepUntil(deadline(after: interval))
        }

        @MainActor
        func receiptRuntimeStatus(
            _ receipt: ExtensionBridge.NativeDeliveryReceipt
        ) async -> NativeAgentLauncher.RuntimeAssessment {
            guard let expected = launcher.expectedRuntime() else {
                return .unidentified(nil)
            }
            return await launcher.status(owner: receipt.owner, expected: expected)
        }
    }

    private struct SharedDelivery {
        let identifier: UUID
        let route: NativeAgentRoute
        let deadline: UInt64
        let task: Task<Bool, Never>
    }

    private enum ReceiptObservation {
        case owned(ExtensionBridge.Snapshot, ExtensionBridge.NativeDeliveryReceipt)
        case unowned, completed, terminal, unavailable
    }

    @MainActor
    private static func observeReceipt(
        handle: ExtensionBridge.Handle,
        nonce: ExtensionBridge.NativeDeliveryNonce,
        isPending: () -> Bool,
        dependencies: Dependencies
    ) async -> ReceiptObservation {
        guard !Task.isCancelled, isPending() else { return .unavailable }
        let loaded = await dependencies.load(handle)
        guard !Task.isCancelled, isPending() else { return .unavailable }
        switch loaded {
        case .found(let snapshot):
            guard snapshot.nativeDeliveryNonce == nonce else { return .terminal }
            if snapshot.phase == .responded { return .completed }
            guard let receipt = snapshot.nativeDeliveryReceipt else { return .unowned }
            guard receipt.nativeDeliveryNonce == nonce else { return .terminal }
            return .owned(snapshot, receipt)
        case .missing:
            return .terminal
        case .unavailable:
            return .unavailable
        }
    }

    @MainActor
    private static func reconcileReceipt(
        handle: ExtensionBridge.Handle,
        nonce: ExtensionBridge.NativeDeliveryNonce,
        policy: ReceiptPolicy = .delivery,
        deadline: UInt64,
        dependencies: Dependencies
    ) async -> ReceiptStatus {
        let isPending = { !Task.isCancelled && dependencies.uptime() < deadline }
        while !Task.isCancelled, isPending() {
            let receipt: ExtensionBridge.NativeDeliveryReceipt
            switch await observeReceipt(
                handle: handle, nonce: nonce, isPending: isPending, dependencies: dependencies
            ) {
            case .owned(let snapshot, let current):
                if policy == .manualRecovery && !snapshot.hasStagedOrActiveExecution {
                    return .unavailable
                }
                if policy == .pageRead,
                   case .queued(_, .delivered) = snapshot.state,
                   let expected = dependencies.launcher.expectedRuntime(),
                   case .compatible = dependencies.launcher.assess(owner: current.owner, expected: expected),
                   expected.installedVersionMatches, isPending() {
                    return .delivered
                }
                receipt = current
            case .completed: return .responseReady
            case .unowned: return .needsDelivery
            case .terminal: return .terminal
            case .unavailable: return .unavailable
            }
            let status = await dependencies.receiptRuntimeStatus(receipt)
            guard !Task.isCancelled, isPending() else { return .unavailable }
            switch status {
            case .compatible:
                return .delivered
            case .incompatible(let runtime):
                guard policy != .manualRecovery else { return .unavailable }
                guard let expected = dependencies.launcher.expectedRuntime(),
                      await dependencies.launcher.verify(runtime, expected: expected),
                      !Task.isCancelled, isPending() else { return .unavailable }
                switch await observeReceipt(
                    handle: handle, nonce: nonce, isPending: isPending, dependencies: dependencies
                ) {
                case .owned(_, let current):
                    guard current == receipt else { continue }
                case .completed: return .responseReady
                case .unowned: continue
                case .terminal: return .terminal
                case .unavailable: return .unavailable
                }
                guard expected.installedVersionMatches else { return .unavailable }
                switch dependencies.launcher.assess(owner: receipt.owner, expected: expected) {
                case .absent:
                    break
                case .incompatible(let current) where current.identity == runtime.identity:
                    guard dependencies.launcher.requestQuit(current) else { return .unavailable }
                    guard await dependencies.launcher.waitForExit(current, deadline: deadline) else {
                        return .unavailable
                    }
                case .compatible:
                    continue
                case .incompatible, .unidentified:
                    return .unavailable
                }
            case .absent:
                break
            case .unidentified:
                return .unavailable
            }
            guard !Task.isCancelled, isPending() else { return .unavailable }
            let cleared = await dependencies.clearReceipt(handle, receipt)
            guard !Task.isCancelled, isPending() else { return .unavailable }
            switch cleared {
            case .persisted:
                switch await observeReceipt(
                    handle: handle, nonce: nonce, isPending: isPending, dependencies: dependencies
                ) {
                case .owned:
                    guard policy != .manualRecovery else { return .unavailable }
                    continue
                case .completed: return .responseReady
                case .unowned:
                    return policy == .manualRecovery ? .unavailable : .needsDelivery
                case .terminal: return .terminal
                case .unavailable: return .unavailable
                }
            case .ownershipLost:
                guard policy != .manualRecovery else { return .unavailable }
                continue
            case .retryablePersistenceFailure:
                return .unavailable
            }
        }
        return .unavailable
    }

    private actor LaunchResolution<Value: Sendable> {
        private var result: Value?
        private var continuation: CheckedContinuation<Value, Never>?

        func value() async -> Value {
            if let result { return result }
            return await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }

        func finish(_ succeeded: Value) {
            guard result == nil else { return }
            result = succeeded
            continuation?.resume(returning: succeeded)
            self.continuation = nil
        }
    }

    @MainActor
    static let live = NativeApprovalService(dependencies: .live)

    private let dependencies: Dependencies
    private let launchTimeoutNanoseconds: UInt64
    private var sharedDeliveries = [SharedDelivery]()
    private var deliveryTail: Task<Bool, Never>?
    private var deliveryTailIdentifier: UUID?

    init(
        dependencies: Dependencies,
        launchTimeoutNanoseconds: UInt64 = NativeApprovalTiming.launchTimeoutNanoseconds
    ) {
        self.dependencies = dependencies
        self.launchTimeoutNanoseconds = launchTimeoutNanoseconds
    }

    func open(
        _ route: NativeAgentRoute,
        waitDeadline: UInt64? = nil
    ) async -> Bool {
        let deliveryDeadline = dependencies.deadline(after: launchTimeoutNanoseconds)
        let callerDeadline = min(
            deliveryDeadline,
            waitDeadline ?? UInt64.max
        )
        guard dependencies.uptime() < callerDeadline else { return false }
        if let shared = sharedDeliveries.first(where: {
            $0.route == route && dependencies.uptime() < $0.deadline
        }) {
            return await result(of: shared, callerDeadline: callerDeadline)
        }
        let identifier = UUID()
        let precedingDelivery = deliveryTail
        let operation = Task { [weak self] in
            _ = await precedingDelivery?.value
            guard let self else { return false }
            return await self.deliver(route, deadline: deliveryDeadline)
        }
        let task = Task { [weak self] in
            guard let self else { operation.cancel(); return false }
            let result = await self.boundedResult(of: operation, deadline: deliveryDeadline, timeoutValue: false)
            await self.finishSharedDelivery(identifier: identifier)
            return result
        }
        let shared = SharedDelivery(
            identifier: identifier,
            route: route,
            deadline: deliveryDeadline,
            task: task
        )
        sharedDeliveries.append(shared)
        deliveryTail = task
        deliveryTailIdentifier = identifier
        return await result(of: shared, callerDeadline: callerDeadline)
    }

    private func result(of delivery: SharedDelivery, callerDeadline: UInt64) async -> Bool {
        if callerDeadline < delivery.deadline {
            return await awaitResult(of: delivery.task, deadline: callerDeadline, timeoutValue: false)
        }
        return await delivery.task.value
    }

    enum ApprovalReadMode {
        case page, manualRecovery
    }

    @MainActor
    private func inspectReceipt(
        handle: ExtensionBridge.Handle,
        nonce: ExtensionBridge.NativeDeliveryNonce,
        policy: ReceiptPolicy = .delivery,
        deadline: UInt64
    ) async -> ReceiptStatus {
        guard !Task.isCancelled, dependencies.uptime() < deadline else { return .unavailable }
        let dependencies = dependencies
        let operation = Task { @MainActor in
            await Self.reconcileReceipt(
                handle: handle, nonce: nonce, policy: policy,
                deadline: deadline, dependencies: dependencies
            )
        }
        return await boundedResult(of: operation, deadline: deadline, timeoutValue: .unavailable)
    }

    @MainActor
    func deliverApproval(
        handle: ExtensionBridge.Handle,
        nativeDeliveryNonce: ExtensionBridge.NativeDeliveryNonce
    ) async -> ApprovalDeliveryResult {
        guard !Task.isCancelled else { return .unavailable }
        let loaded = await dependencies.load(handle)
        guard !Task.isCancelled,
              case .found(let snapshot) = loaded,
              snapshot.nativeDeliveryNonce == nativeDeliveryNonce else { return .unavailable }
        if snapshot.phase == .responded { return .responseReady }
        if snapshot.hasStagedOrActiveExecution {
            let status = await inspectReceipt(
                handle: handle, nonce: nativeDeliveryNonce,
                deadline: dependencies.deadline(after: launchTimeoutNanoseconds)
            )
            switch status {
            case .delivered: return .pending
            case .responseReady: return .responseReady
            case .needsDelivery, .terminal, .unavailable: return .unavailable
            }
        }
        let opened = await open(.approval(
            workflowVersion: ExtensionBridge.workflowVersion,
            handle: handle,
            nativeDeliveryNonce: nativeDeliveryNonce
        ))
        guard !Task.isCancelled else { return .unavailable }
        if !opened {
            let deadline = dependencies.deadline(after: NativeApprovalTiming.receiptWaitTimeoutNanoseconds)
            let status = await inspectReceipt(
                handle: handle, nonce: nativeDeliveryNonce,
                deadline: deadline
            )
            switch status {
            case .delivered: return .pending
            case .responseReady: return .responseReady
            case .needsDelivery, .terminal, .unavailable: return .unavailable
            }
        }
        return .pending
    }

    @MainActor
    func readApprovalResponse(
        handle: ExtensionBridge.Handle,
        configurationKey: String,
        revisions: ExtensionBridge.ProviderRevisions,
        executionDeadline: Date,
        mode: ApprovalReadMode
    ) async -> ExtensionBridge.ResponseReadResult {
        guard !Task.isCancelled else { return .pending }
        if mode == .manualRecovery {
            let loaded = await dependencies.loadManualSwitch(handle, configurationKey)
            guard !Task.isCancelled else { return .pending }
            switch loaded {
            case .found(let snapshot):
                if snapshot.phase != .responded {
                    let status = await inspectReceipt(
                        handle: handle, nonce: snapshot.nativeDeliveryNonce,
                        policy: .manualRecovery,
                        deadline: dependencies.deadline(after: launchTimeoutNanoseconds)
                    )
                    guard !Task.isCancelled else { return .pending }
                    switch status {
                    case .delivered, .responseReady: break
                    case .needsDelivery, .terminal, .unavailable: return .pending
                    }
                }
            case .missing: return .missing
            case .unavailable: return .unavailable
            }
        }

        var executionLease: ExtensionBridge.NativeExecutionReadLease?
        defer { executionLease?.release() }
        let execution = await dependencies.beginExecutionRead(
            handle, configurationKey, revisions, executionDeadline
        )
        if case .acquired(let lease) = execution { executionLease = lease }
        guard !Task.isCancelled else { return .pending }
        switch execution {
        case .acquired(let lease):
            let initialDeadline = dependencies.deadline(after: launchTimeoutNanoseconds)
            let initialStatus = await inspectReceipt(
                handle: handle, nonce: lease.nativeDeliveryNonce,
                policy: mode == .page ? .pageRead : .manualRecovery,
                deadline: initialDeadline
            )
            guard !Task.isCancelled else { return .pending }
            switch initialStatus {
            case .responseReady, .terminal:
                break
            case .needsDelivery, .unavailable:
                return mode == .page ? .unavailable : .pending
            case .delivered:
                let deadline = dependencies.deadline(after: NativeApprovalTiming.responseTimeoutNanoseconds)
                var nextDeliveryCheck = dependencies.deadline(after: NativeApprovalTiming.deliveryCheckIntervalNanoseconds)
                if dependencies.wallClock() >= lease.context.executionDeadline { return .pending }
                observation: while !Task.isCancelled, dependencies.uptime() < deadline {
                    let loaded = await dependencies.load(handle)
                    guard !Task.isCancelled else { return .pending }
                    switch loaded {
                    case .found(let snapshot):
                        guard snapshot.configurationKey == configurationKey,
                              snapshot.phase != .responded else { break observation }
                        if snapshot.phase == .queued,
                           dependencies.wallClock() >= lease.context.executionDeadline { return .pending }
                        let now = dependencies.uptime()
                        if case .queued(_, .staged) = snapshot.state, now >= nextDeliveryCheck {
                            let status = await inspectReceipt(
                                handle: handle, nonce: lease.nativeDeliveryNonce,
                                policy: mode == .page ? .pageRead : .manualRecovery,
                                deadline: min(deadline, dependencies.deadline(after: launchTimeoutNanoseconds))
                            )
                            guard !Task.isCancelled else { return .pending }
                            switch status {
                            case .responseReady, .terminal: break observation
                            case .delivered: break
                            case .needsDelivery, .unavailable: return .pending
                            }
                            let next = now.addingReportingOverflow(NativeApprovalTiming.deliveryCheckIntervalNanoseconds)
                            nextDeliveryCheck = next.overflow ? UInt64.max : next.partialValue
                        }
                    case .missing: break observation
                    case .unavailable: break
                    }
                    let wake = dependencies.deadline(after: NativeApprovalTiming.responsePollIntervalNanoseconds)
                    await dependencies.sleepUntil(min(wake, deadline))
                }
                guard !Task.isCancelled, dependencies.uptime() < deadline else { return .pending }
            }
        case .needsDelivery(let nonce):
            let deadline = dependencies.deadline(after: launchTimeoutNanoseconds)
            let status = await inspectReceipt(
                handle: handle, nonce: nonce,
                policy: mode == .page ? .pageRead : .manualRecovery,
                deadline: deadline
            )
            guard !Task.isCancelled else { return .pending }
            switch status {
            case .delivered, .responseReady, .terminal: break
            case .needsDelivery where mode == .page:
                let route = NativeAgentRoute.approval(
                    workflowVersion: ExtensionBridge.workflowVersion,
                    handle: handle, nativeDeliveryNonce: nonce
                )
                let delivered = await open(route, waitDeadline: deadline)
                guard !Task.isCancelled else { return .pending }
                guard delivered else { return .unavailable }
            case .needsDelivery, .unavailable:
                return mode == .page ? .unavailable : .pending
            }
        case .pending, .responseReady, .missing: break
        case .unavailable: return .unavailable
        }
        guard !Task.isCancelled else { return .pending }
        let response = await dependencies.readResponse(handle, configurationKey)
        return Task.isCancelled ? .pending : response
    }

    func reactivate(
        _ route: NativeAgentRoute,
        waitDeadline: UInt64? = nil
    ) async -> Bool {
        guard !Task.isCancelled, case .approval = route else {
            return false
        }
        let deadline = min(
            dependencies.deadline(after: launchTimeoutNanoseconds),
            waitDeadline ?? UInt64.max
        )
        guard dependencies.uptime() < deadline else { return false }
        let operation = Task { await self.reactivateApproval(route, deadline: deadline) }
        return await boundedResult(of: operation, deadline: deadline, timeoutValue: false)
    }

    private func reactivateApproval(_ route: NativeAgentRoute, deadline: UInt64) async -> Bool {
        guard case .approval(_, let handle, let nativeDeliveryNonce) = route else { return false }
        let isPending = { !Task.isCancelled && self.dependencies.uptime() < deadline }
        switch await Self.reconcileReceipt(
            handle: handle, nonce: nativeDeliveryNonce,
            deadline: deadline, dependencies: dependencies
        ) {
        case .needsDelivery:
            return isPending() ? await open(route, waitDeadline: deadline) : false
        case .delivered:
            break
        case .responseReady, .terminal, .unavailable:
            return false
        }
        guard isPending(),
              case .found(let snapshot) = await dependencies.load(handle),
              snapshot.nativeDeliveryNonce == nativeDeliveryNonce,
              case .queued = snapshot.state,
              let receipt = snapshot.nativeDeliveryReceipt,
              receipt.nativeDeliveryNonce == nativeDeliveryNonce,
              case .compatible(let runtime) = await dependencies
                .receiptRuntimeStatus(receipt),
              runtime.identity.instanceIdentifier == receipt.owner.runtimeInstanceIdentifier else {
            return false
        }
        return await dependencies.launcher.send(route, to: runtime.target, deadline: deadline)
    }

    private func finishSharedDelivery(identifier: UUID) {
        sharedDeliveries.removeAll { $0.identifier == identifier }
        if deliveryTailIdentifier == identifier {
            deliveryTail = nil
            deliveryTailIdentifier = nil
        }
    }

    @MainActor
    private func deliver(
        _ route: NativeAgentRoute,
        deadline: UInt64
    ) async -> Bool {
        let dependencies = dependencies
        let isPending = { !Task.isCancelled && dependencies.uptime() < deadline }
        guard isPending() else { return false }
        if case .approval(_, let handle, let nonce) = route {
            switch await Self.reconcileReceipt(
                handle: handle, nonce: nonce,
                deadline: deadline, dependencies: dependencies
            ) {
            case .delivered, .responseReady: return true
            case .terminal, .unavailable: return false
            case .needsDelivery: break
            }
        }
        guard isPending(), let initialExpected = dependencies.launcher.expectedRuntime(),
              let target = await dependencies.launcher.resolveTarget(
                expected: initialExpected, deadline: deadline
              ), isPending(),
              await dependencies.launcher.send(route, to: target, deadline: deadline),
              let expected = dependencies.launcher.expectedRuntime(at: target.url) else { return false }
        while isPending() {
            switch route {
            case .approval(_, let handle, let nonce):
                switch await Self.reconcileReceipt(
                    handle: handle, nonce: nonce,
                    deadline: deadline, dependencies: dependencies
                ) {
                case .delivered, .responseReady: return isPending()
                case .terminal: return false
                case .needsDelivery, .unavailable: break
                }
            case .showWallet:
                if await dependencies.launcher.isConfirmed(expected, deadline: deadline) { return true }
            }
            let now = dependencies.uptime()
            guard isPending(), now < deadline else { return false }
            await dependencies.wait(min(NativeApprovalTiming.launchPollIntervalNanoseconds, deadline - now))
        }
        return false
    }

    private func boundedResult<Value: Sendable>(
        of task: Task<Value, Never>, deadline: UInt64, timeoutValue: Value
    ) async -> Value {
        let resolution = LaunchResolution<Value>()
        return await withTaskCancellationHandler {
            let result = await awaitResult(of: task, deadline: deadline, timeoutValue: timeoutValue, resolution: resolution)
            task.cancel()
            return result
        } onCancel: {
            task.cancel()
            Task { await resolution.finish(timeoutValue) }
        }
    }

    private func awaitResult<Value: Sendable>(
        of task: Task<Value, Never>,
        deadline: UInt64,
        timeoutValue: Value,
        resolution: LaunchResolution<Value> = LaunchResolution()
    ) async -> Value {
        guard dependencies.uptime() < deadline else { return timeoutValue }
        let timeoutTask = Task {
            await dependencies.sleepUntil(deadline)
            guard !Task.isCancelled else { return }
            await resolution.finish(timeoutValue)
        }
        let completionTask = Task { await resolution.finish(await task.value) }
        let result = await resolution.value()
        timeoutTask.cancel()
        completionTask.cancel()
        return result
    }
}
