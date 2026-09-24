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
        case delivery, manualRecovery
    }

    struct Dependencies {
        let launcher: NativeAgentLauncher
        let load: (ExtensionBridge.Handle) async -> ExtensionBridge.SnapshotResult
        let responseStatus: (
            ExtensionBridge.Handle, String
        ) async -> ExtensionBridge.ResponseStatusResult
        let maintainProfile: (UUID?) async -> Void
        let clearReceipt: (
            ExtensionBridge.Handle,
            ExtensionBridge.NativeDeliveryReceipt
        ) async -> ExtensionBridge.StoreMutationResult
        let uptime: () -> UInt64
        let sleepUntil: @Sendable (UInt64) async -> Void

        @MainActor
        static var live: Self {
            Self(
                launcher: NativeAgentLauncher(),
                load: { await ExtensionBridge.shared.load(handle: $0) },
                responseStatus: {
                    await ExtensionBridge.shared.responseStatus(
                        handle: $0, configurationKey: $1
                    )
                },
                maintainProfile: {
                    await ExtensionBridge.shared.performMaintenance(profileIdentifier: $0)
                },
                clearReceipt: { handle, receipt in
                    await ExtensionBridge.shared.clearNativeDeliveryReceipt(
                        handle: handle,
                        nativeDeliveryNonce: receipt.nativeDeliveryNonce,
                        runtimeInstanceIdentifier: receipt.owner.runtimeInstanceIdentifier
                    )
                },
                uptime: { DispatchTime.now().uptimeNanoseconds },
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

    private func isPending(until deadline: UInt64) -> Bool {
        !Task.isCancelled && dependencies.uptime() < deadline
    }

    private func observeReceipt(
        handle: ExtensionBridge.Handle,
        nonce: ExtensionBridge.NativeDeliveryNonce,
        deadline: UInt64
    ) async -> ReceiptObservation {
        guard isPending(until: deadline) else { return .unavailable }
        let loaded = await dependencies.load(handle)
        guard isPending(until: deadline) else { return .unavailable }
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

    private func reconcileReceipt(
        handle: ExtensionBridge.Handle,
        nonce: ExtensionBridge.NativeDeliveryNonce,
        policy: ReceiptPolicy = .delivery,
        deadline: UInt64
    ) async -> ReceiptStatus {
        while isPending(until: deadline) {
            let receipt: ExtensionBridge.NativeDeliveryReceipt
            switch await observeReceipt(
                handle: handle, nonce: nonce, deadline: deadline
            ) {
            case .owned(let snapshot, let current):
                if policy == .manualRecovery && !snapshot.hasActiveExecution {
                    return .unavailable
                }
                receipt = current
            case .completed: return .responseReady
            case .unowned: return .needsDelivery
            case .terminal: return .terminal
            case .unavailable: return .unavailable
            }
            let status = await dependencies.launcher.status(owner: receipt.owner)
            guard isPending(until: deadline) else { return .unavailable }
            switch status {
            case .compatible:
                return .delivered
            case .incompatible(let runtime):
                guard policy != .manualRecovery else { return .unavailable }
                guard let expected = await dependencies.launcher.verifiedExpectedRuntime(for: runtime),
                      isPending(until: deadline) else { return .unavailable }
                switch await observeReceipt(
                    handle: handle, nonce: nonce, deadline: deadline
                ) {
                case .owned(_, let current):
                    guard current == receipt else { continue }
                case .completed: return .responseReady
                case .unowned: continue
                case .terminal: return .terminal
                case .unavailable: return .unavailable
                }
                switch await dependencies.launcher.retireVerifiedOwner(
                    owner: receipt.owner,
                    observedRuntime: runtime,
                    expected: expected,
                    deadline: deadline
                ) {
                case .exited:
                    break
                case .reassess:
                    continue
                case .unavailable:
                    return .unavailable
                }
            case .absent:
                break
            case .unidentified:
                return .unavailable
            }
            guard isPending(until: deadline) else { return .unavailable }
            let cleared = await dependencies.clearReceipt(handle, receipt)
            guard isPending(until: deadline) else { return .unavailable }
            switch cleared {
            case .persisted:
                switch await observeReceipt(
                    handle: handle, nonce: nonce, deadline: deadline
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

    private func inspectReceipt(
        handle: ExtensionBridge.Handle,
        nonce: ExtensionBridge.NativeDeliveryNonce,
        policy: ReceiptPolicy = .delivery,
        deadline: UInt64
    ) async -> ReceiptStatus {
        guard isPending(until: deadline) else { return .unavailable }
        let operation = Task {
            await reconcileReceipt(
                handle: handle, nonce: nonce, policy: policy,
                deadline: deadline
            )
        }
        return await boundedResult(of: operation, deadline: deadline, timeoutValue: .unavailable)
    }

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
        if snapshot.hasActiveExecution {
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

    func maintainRequest(
        handle: ExtensionBridge.Handle,
        configurationKey: String,
        allowDelivery: Bool
    ) async -> ExtensionBridge.ResponseStatusResult {
        guard !Task.isCancelled else { return .pending }
        let deadline = dependencies.deadline(after: launchTimeoutNanoseconds)
        let operation = Task {
            await maintainRequest(
                handle: handle, configurationKey: configurationKey,
                allowDelivery: allowDelivery, deadline: deadline
            )
        }
        return await boundedResult(of: operation, deadline: deadline, timeoutValue: .unavailable)
    }

    private func maintainRequest(
        handle: ExtensionBridge.Handle,
        configurationKey: String,
        allowDelivery: Bool,
        deadline: UInt64
    ) async -> ExtensionBridge.ResponseStatusResult {
        await dependencies.maintainProfile(handle.profileIdentifier)
        guard isPending(until: deadline) else { return .unavailable }
        let snapshot: ExtensionBridge.Snapshot
        switch await dependencies.load(handle) {
        case .found(let found) where found.configurationKey == configurationKey:
            snapshot = found
        case .found, .missing: return .missing
        case .unavailable: return .unavailable
        }
        guard isPending(until: deadline) else { return .unavailable }
        if snapshot.phase == .responded { return .ready }
        let manual = snapshot.request?.provider == .unknown &&
            snapshot.request?.name == "switchAccount"
        let quiet = manual || !allowDelivery
        if quiet && !snapshot.hasActiveExecution { return .pending }
        let status = await reconcileReceipt(
            handle: handle, nonce: snapshot.nativeDeliveryNonce,
            policy: quiet ? .manualRecovery : .delivery, deadline: deadline
        )
        guard isPending(until: deadline) else { return .unavailable }
        switch status {
        case .delivered: return .pending
        case .responseReady: return .ready
        case .terminal:
            return await dependencies.responseStatus(handle, configurationKey)
        case .unavailable: return .unavailable
        case .needsDelivery:
            guard !quiet, !snapshot.hasActiveExecution else { return .pending }
            let opened = await open(.approval(
                workflowVersion: ExtensionBridge.workflowVersion,
                handle: handle, nativeDeliveryNonce: snapshot.nativeDeliveryNonce
            ), waitDeadline: deadline)
            guard isPending(until: deadline), opened else { return .unavailable }
            return await dependencies.responseStatus(handle, configurationKey)
        }
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
        switch await reconcileReceipt(
            handle: handle, nonce: nativeDeliveryNonce,
            deadline: deadline
        ) {
        case .needsDelivery:
            return isPending(until: deadline) ? await open(route, waitDeadline: deadline) : false
        case .delivered:
            break
        case .responseReady, .terminal, .unavailable:
            return false
        }
        guard isPending(until: deadline),
              case .found(let snapshot) = await dependencies.load(handle),
              snapshot.nativeDeliveryNonce == nativeDeliveryNonce,
              case .queued = snapshot.state,
              let receipt = snapshot.nativeDeliveryReceipt,
              receipt.nativeDeliveryNonce == nativeDeliveryNonce,
              case .compatible(let runtime) = await dependencies.launcher.status(owner: receipt.owner),
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

    private func deliver(
        _ route: NativeAgentRoute,
        deadline: UInt64
    ) async -> Bool {
        guard isPending(until: deadline) else { return false }
        if case .approval(_, let handle, let nonce) = route {
            switch await reconcileReceipt(
                handle: handle, nonce: nonce,
                deadline: deadline
            ) {
            case .delivered, .responseReady: return true
            case .terminal, .unavailable: return false
            case .needsDelivery: break
            }
        }
        guard isPending(until: deadline), let initialExpected = await dependencies.launcher.expectedRuntime(),
              let target = await dependencies.launcher.resolveTarget(
                expected: initialExpected, deadline: deadline
              ), isPending(until: deadline),
              await dependencies.launcher.send(route, to: target, deadline: deadline),
              let expected = await dependencies.launcher.expectedRuntime(at: target.url) else { return false }
        while isPending(until: deadline) {
            switch route {
            case .approval(_, let handle, let nonce):
                switch await reconcileReceipt(
                    handle: handle, nonce: nonce,
                    deadline: deadline
                ) {
                case .delivered, .responseReady: return isPending(until: deadline)
                case .terminal: return false
                case .needsDelivery, .unavailable: break
                }
            case .showWallet:
                if await dependencies.launcher.isConfirmed(expected, deadline: deadline) { return true }
            }
            let now = dependencies.uptime()
            guard isPending(until: deadline), now < deadline else { return false }
            await dependencies.wait(min(NativeApprovalTiming.launchPollIntervalNanoseconds, deadline - now))
        }
        return false
    }

    private func boundedResult<Value: Sendable>(
        of task: Task<Value, Never>, deadline: UInt64, timeoutValue: Value
    ) async -> Value {
        let resolution = ApprovalResolution<Value>()
        return await withTaskCancellationHandler {
            let result = await awaitResult(of: task, deadline: deadline, timeoutValue: timeoutValue, resolution: resolution)
            task.cancel()
            return result
        } onCancel: {
            task.cancel()
            Task { await resolution.resolve(timeoutValue) }
        }
    }

    private func awaitResult<Value: Sendable>(
        of task: Task<Value, Never>,
        deadline: UInt64,
        timeoutValue: Value,
        resolution: ApprovalResolution<Value> = ApprovalResolution()
    ) async -> Value {
        guard dependencies.uptime() < deadline else { return timeoutValue }
        let sleepUntil = dependencies.sleepUntil
        return await resolution.value(
            timeoutValue: timeoutValue,
            waitForTimeout: { await sleepUntil(deadline) },
            operation: { await task.value }
        )
    }
}
