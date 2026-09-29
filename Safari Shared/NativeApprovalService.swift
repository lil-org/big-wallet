// ∅ 2026 lil org

import Foundation

actor NativeApprovalService {
    enum ReconciliationIntent: Equatable, Sendable {
        case admission
        case maintenance(allowDelivery: Bool)
        case focus
    }

    enum ReconciliationResult: Equatable, Sendable {
        case pending, responseReady, opened, missing, unavailable
    }

    struct RequestReference: Sendable {
        let handle: ExtensionBridge.Handle
        let configurationKey: String
        let expectedNonce: ExtensionBridge.NativeDeliveryNonce?

        init(
            handle: ExtensionBridge.Handle,
            configurationKey: String,
            expectedNonce: ExtensionBridge.NativeDeliveryNonce? = nil
        ) {
            self.handle = handle
            self.configurationKey = configurationKey
            self.expectedNonce = expectedNonce
        }

        init(_ snapshot: ExtensionBridge.Snapshot) {
            self.init(
                handle: snapshot.handle,
                configurationKey: snapshot.configurationKey,
                expectedNonce: snapshot.nativeDeliveryNonce
            )
        }

        var route: NativeAgentRoute? {
            guard let expectedNonce else { return nil }
            return .approval(
                workflowVersion: ExtensionBridge.workflowVersion,
                handle: handle,
                nativeDeliveryNonce: expectedNonce
            )
        }
    }

    private enum Ownership: Sendable {
        case owned(
            receipt: ExtensionBridge.NativeDeliveryReceipt,
            runtime: NativeAgentLauncher.IdentifiedRuntime
        )
        case needsDelivery
        case finished(ReconciliationResult)

        var result: ReconciliationResult {
            switch self {
            case .owned: return .pending
            case .needsDelivery: return .unavailable
            case .finished(let result): return result
            }
        }
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
        let task: Task<ReconciliationResult, Never>
    }

    @MainActor
    static let live = NativeApprovalService(dependencies: .live)

    private let dependencies: Dependencies
    private let launchTimeoutNanoseconds: UInt64
    private var sharedDeliveries = [SharedDelivery]()
    private var preparationTail: ApprovalResolution<Void>?

    init(
        dependencies: Dependencies,
        launchTimeoutNanoseconds: UInt64 = NativeApprovalTiming.launchTimeoutNanoseconds
    ) {
        self.dependencies = dependencies
        self.launchTimeoutNanoseconds = launchTimeoutNanoseconds
    }

    func reconcile(
        _ reference: RequestReference,
        intent: ReconciliationIntent,
        waitDeadline: UInt64? = nil
    ) async -> ReconciliationResult {
        guard !Task.isCancelled else {
            if case .maintenance = intent { return .pending }
            return .unavailable
        }
        if intent == .admission || intent == .focus {
            guard reference.expectedNonce != nil else { return .missing }
        }
        let deadline = min(
            dependencies.deadline(after: launchTimeoutNanoseconds),
            waitDeadline ?? UInt64.max
        )
        guard isPending(until: deadline) else { return .unavailable }
        if intent == .admission {
            return await reconcileRequest(
                reference, intent: intent, deadline: deadline, waitDeadline: waitDeadline
            )
        }
        let result = await bounded(deadline: deadline, timeoutValue: ReconciliationResult.unavailable) {
            await self.reconcileRequest(reference, intent: intent, deadline: deadline)
        }
        guard intent == .focus,
              result == .unavailable || result == .missing,
              !Task.isCancelled else { return result }
        switch await load(reference) {
        case .found(let snapshot):
            switch snapshot.state {
            case .responded: return .responseReady
            case .approving: return .pending
            case .queued: return result
            }
        case .missing, .unavailable:
            return result
        }
    }

    func openWallet(waitDeadline: UInt64? = nil) async -> Bool {
        await scheduleDelivery(
            .showWallet(workflowVersion: ExtensionBridge.workflowVersion),
            reference: nil,
            waitDeadline: waitDeadline
        ) == .opened
    }

    private func reconcileRequest(
        _ reference: RequestReference,
        intent: ReconciliationIntent,
        deadline: UInt64,
        waitDeadline: UInt64? = nil
    ) async -> ReconciliationResult {
        if case .maintenance = intent {
            await dependencies.maintainProfile(reference.handle.profileIdentifier)
        }
        guard isPending(until: deadline) else { return .unavailable }
        let snapshot: ExtensionBridge.Snapshot
        switch await load(reference) {
        case .found(let found): snapshot = found
        case .missing: return .missing
        case .unavailable: return .unavailable
        }
        guard isPending(until: deadline) else { return .unavailable }
        if snapshot.phase == .responded { return .responseReady }
        switch intent {
        case .admission:
            return await reconcileAdmission(snapshot, deadline: deadline, waitDeadline: waitDeadline)
        case .maintenance(let allowDelivery):
            return await reconcileMaintenance(snapshot, allowDelivery: allowDelivery, deadline: deadline)
        case .focus:
            return await reconcileFocus(snapshot, deadline: deadline)
        }
    }

    private func reconcileAdmission(
        _ snapshot: ExtensionBridge.Snapshot,
        deadline: UInt64,
        waitDeadline: UInt64?
    ) async -> ReconciliationResult {
        let reference = RequestReference(snapshot)
        if snapshot.hasActiveExecution {
            return await inspectOwnership(reference, deadline: deadline)
        }
        let delivered = await deliverRequest(reference, deadline: deadline)
        guard !Task.isCancelled else { return .unavailable }
        guard delivered == .unavailable else { return delivered }
        let receiptDeadline = min(
            dependencies.deadline(after: NativeApprovalTiming.receiptWaitTimeoutNanoseconds),
            waitDeadline ?? UInt64.max
        )
        return await inspectOwnership(reference, deadline: receiptDeadline)
    }

    private func reconcileMaintenance(
        _ snapshot: ExtensionBridge.Snapshot,
        allowDelivery: Bool,
        deadline: UInt64
    ) async -> ReconciliationResult {
        let reference = RequestReference(snapshot)
        let quiet = !allowDelivery || (snapshot.request?.provider == .unknown &&
            snapshot.request?.name == "switchAccount")
        if quiet && !snapshot.hasActiveExecution { return .pending }
        let ownership = await reconcileOwnership(
            reference,
            policy: quiet ? .manualRecovery : .delivery,
            deadline: deadline
        )
        guard isPending(until: deadline) else { return .unavailable }
        switch ownership {
        case .finished(.missing):
            switch await dependencies.responseStatus(reference.handle, reference.configurationKey) {
            case .pending: return .pending
            case .ready: return .responseReady
            case .missing: return .missing
            case .unavailable: return .unavailable
            }
        case .finished(let result):
            return result
        case .needsDelivery:
            guard !quiet, !snapshot.hasActiveExecution else { return .pending }
            return await deliverRequest(reference, deadline: deadline)
        case .owned:
            return .pending
        }
    }

    private func reconcileFocus(
        _ snapshot: ExtensionBridge.Snapshot,
        deadline: UInt64
    ) async -> ReconciliationResult {
        let reference = RequestReference(snapshot)
        var snapshot = snapshot
        while isPending(until: deadline) {
            let ownership = await reconcileOwnership(reference, deadline: deadline)
            guard isPending(until: deadline) else { return .unavailable }
            switch ownership {
            case .finished(let result):
                return result
            case .needsDelivery:
                guard !snapshot.hasActiveExecution else { return .pending }
                let result = await deliverRequest(reference, deadline: deadline)
                return result == .pending ? .opened : result
            case .owned(let receipt, let runtime):
                guard case .found(let current) = await load(reference) else { return .unavailable }
                guard isPending(until: deadline) else { return .unavailable }
                switch current.state {
                case .responded: return .responseReady
                case .approving: return .pending
                case .queued: break
                }
                guard current.nativeDeliveryReceipt != nil else { return .unavailable }
                guard current.nativeDeliveryReceipt == receipt else {
                    snapshot = current
                    continue
                }
                guard let expected = await dependencies.launcher.expectedRuntime(),
                      case .compatible(let currentRuntime) = await dependencies.launcher.assess(
                          owner: receipt.owner, expected: expected
                      ), currentRuntime.identity == runtime.identity,
                      let route = reference.route else { return .unavailable }
                return await dependencies.launcher.send(route, to: runtime.target, deadline: deadline)
                    ? .opened : .unavailable
            }
        }
        return .unavailable
    }

    private func isPending(until deadline: UInt64) -> Bool {
        !Task.isCancelled && dependencies.uptime() < deadline
    }

    private func load(_ reference: RequestReference) async -> ExtensionBridge.SnapshotResult {
        guard !Task.isCancelled else { return .unavailable }
        let result = await dependencies.load(reference.handle)
        guard !Task.isCancelled else { return .unavailable }
        guard case .found(let snapshot) = result else { return result }
        guard snapshot.handle == reference.handle,
              snapshot.configurationKey == reference.configurationKey,
              reference.expectedNonce.map({ $0 == snapshot.nativeDeliveryNonce }) ?? true,
              snapshot.nativeDeliveryReceipt.map({
                  $0.nativeDeliveryNonce == snapshot.nativeDeliveryNonce
              }) ?? true else { return .missing }
        return .found(snapshot)
    }

    private func reconcileOwnership(
        _ reference: RequestReference,
        policy: ReceiptPolicy = .delivery,
        deadline: UInt64
    ) async -> Ownership {
        while isPending(until: deadline) {
            let snapshot: ExtensionBridge.Snapshot
            switch await load(reference) {
            case .found(let found): snapshot = found
            case .missing: return .finished(.missing)
            case .unavailable: return .finished(.unavailable)
            }
            guard isPending(until: deadline) else { return .finished(.unavailable) }
            if snapshot.phase == .responded { return .finished(.responseReady) }
            guard let receipt = snapshot.nativeDeliveryReceipt else { return .needsDelivery }
            if policy == .manualRecovery && !snapshot.hasActiveExecution {
                return .finished(.unavailable)
            }
            let status = await dependencies.launcher.status(owner: receipt.owner)
            guard isPending(until: deadline) else { return .finished(.unavailable) }
            switch status {
            case .compatible(let runtime):
                return .owned(receipt: receipt, runtime: runtime)
            case .incompatible(let runtime):
                guard policy != .manualRecovery,
                      let expected = await dependencies.launcher.verifiedExpectedRuntime(for: runtime),
                      isPending(until: deadline) else { return .finished(.unavailable) }
                switch await load(reference) {
                case .found(let current):
                    if current.phase == .responded { return .finished(.responseReady) }
                    guard current.nativeDeliveryReceipt == receipt else { continue }
                case .missing: return .finished(.missing)
                case .unavailable: return .finished(.unavailable)
                }
                guard isPending(until: deadline) else { return .finished(.unavailable) }
                switch await dependencies.launcher.retireVerifiedOwner(
                    owner: receipt.owner,
                    observedRuntime: runtime,
                    expected: expected,
                    deadline: deadline
                ) {
                case .exited: break
                case .reassess: continue
                case .unavailable: return .finished(.unavailable)
                }
            case .absent:
                break
            case .unidentified:
                return .finished(.unavailable)
            }
            guard isPending(until: deadline) else { return .finished(.unavailable) }
            let cleared = await dependencies.clearReceipt(reference.handle, receipt)
            guard isPending(until: deadline) else { return .finished(.unavailable) }
            switch cleared {
            case .persisted:
                switch await load(reference) {
                case .found(let current):
                    guard isPending(until: deadline) else { return .finished(.unavailable) }
                    if current.phase == .responded { return .finished(.responseReady) }
                    guard policy != .manualRecovery else { return .finished(.unavailable) }
                    if current.nativeDeliveryReceipt == nil { return .needsDelivery }
                case .missing: return .finished(.missing)
                case .unavailable: return .finished(.unavailable)
                }
            case .ownershipLost:
                guard policy != .manualRecovery else { return .finished(.unavailable) }
            case .retryablePersistenceFailure:
                return .finished(.unavailable)
            }
        }
        return .finished(.unavailable)
    }

    private func inspectOwnership(
        _ reference: RequestReference,
        deadline: UInt64
    ) async -> ReconciliationResult {
        guard isPending(until: deadline) else { return .unavailable }
        return await bounded(deadline: deadline, timeoutValue: ReconciliationResult.unavailable) {
            await self.reconcileOwnership(reference, deadline: deadline).result
        }
    }

    private func deliverRequest(
        _ reference: RequestReference,
        deadline: UInt64
    ) async -> ReconciliationResult {
        guard let route = reference.route else { return .missing }
        return await scheduleDelivery(route, reference: reference, waitDeadline: deadline)
    }

    private func scheduleDelivery(
        _ route: NativeAgentRoute,
        reference: RequestReference?,
        waitDeadline: UInt64?
    ) async -> ReconciliationResult {
        let deliveryDeadline = dependencies.deadline(after: launchTimeoutNanoseconds)
        let callerDeadline = min(deliveryDeadline, waitDeadline ?? UInt64.max)
        guard dependencies.uptime() < callerDeadline else { return .unavailable }
        if let shared = sharedDeliveries.first(where: {
            $0.route == route && dependencies.uptime() < $0.deadline
        }) {
            return await result(of: shared, callerDeadline: callerDeadline)
        }
        let identifier = UUID()
        let precedingPreparation = preparationTail
        let preparationFinished = ApprovalResolution<Void>()
        preparationTail = preparationFinished
        let task = Task { [weak self] in
            guard let self else {
                await preparationFinished.resolve(())
                return ReconciliationResult.unavailable
            }
            let result = await self.bounded(
                deadline: deliveryDeadline, timeoutValue: ReconciliationResult.unavailable
            ) {
                await precedingPreparation?.value()
                return await self.deliver(
                    route, reference: reference,
                    preparationFinished: preparationFinished, deadline: deliveryDeadline
                )
            }
            await self.finishDeliveryPreparation(preparationFinished)
            await self.finishSharedDelivery(identifier: identifier)
            return result
        }
        let shared = SharedDelivery(identifier: identifier, route: route, deadline: deliveryDeadline, task: task)
        sharedDeliveries.append(shared)
        return await result(of: shared, callerDeadline: callerDeadline)
    }

    private func result(of delivery: SharedDelivery, callerDeadline: UInt64) async -> ReconciliationResult {
        if callerDeadline < delivery.deadline {
            return await bounded(deadline: callerDeadline, timeoutValue: ReconciliationResult.unavailable) {
                await delivery.task.value
            }
        }
        return await delivery.task.value
    }

    private func finishSharedDelivery(identifier: UUID) {
        sharedDeliveries.removeAll { $0.identifier == identifier }
    }

    private func finishDeliveryPreparation(_ completion: ApprovalResolution<Void>) async {
        if preparationTail === completion {
            preparationTail = nil
        }
        await completion.resolve(())
    }

    private func deliver(
        _ route: NativeAgentRoute,
        reference: RequestReference?,
        preparationFinished: ApprovalResolution<Void>,
        deadline: UInt64
    ) async -> ReconciliationResult {
        guard isPending(until: deadline) else { return .unavailable }
        if let reference {
            switch await reconcileOwnership(reference, deadline: deadline) {
            case .owned: return .pending
            case .finished(let result): return result
            case .needsDelivery: break
            }
        }
        guard isPending(until: deadline), let initialExpected = await dependencies.launcher.expectedRuntime(),
              let target = await dependencies.launcher.resolveTarget(expected: initialExpected, deadline: deadline),
              isPending(until: deadline) else { return .unavailable }
        if case .running = target {
            await finishDeliveryPreparation(preparationFinished)
        }
        let sent = await dependencies.launcher.send(route, to: target, deadline: deadline)
        if case .launch = target {
            await finishDeliveryPreparation(preparationFinished)
        }
        guard sent, let expected = await dependencies.launcher.expectedRuntime(at: target.url),
              isPending(until: deadline) else { return .unavailable }
        while isPending(until: deadline) {
            if let reference {
                switch await reconcileOwnership(reference, deadline: deadline) {
                case .owned: return isPending(until: deadline) ? .pending : .unavailable
                case .finished(.unavailable), .needsDelivery: break
                case .finished(let result): return result
                }
            } else if await dependencies.launcher.isConfirmed(expected, deadline: deadline) {
                return .opened
            }
            let now = dependencies.uptime()
            guard isPending(until: deadline), now < deadline else { return .unavailable }
            await dependencies.wait(min(NativeApprovalTiming.launchPollIntervalNanoseconds, deadline - now))
        }
        return .unavailable
    }

    private func bounded<Value: Sendable>(
        deadline: UInt64,
        timeoutValue: Value,
        operation: @escaping @Sendable () async -> Value
    ) async -> Value {
        guard isPending(until: deadline) else { return timeoutValue }
        let sleepUntil = dependencies.sleepUntil
        return await ApprovalResolution<Value>().value(
            timeoutValue: timeoutValue,
            callerCancellation: .resolveTimeout,
            waitForTimeout: { await sleepUntil(deadline) },
            operation: operation
        )
    }
}
