import WalletDomain
import WalletStorageSupport
// ∅ 2026 lil org

import Foundation

public actor NativeApprovalService {
    public enum ReconciliationIntent: Equatable, Sendable {
        case admission
        case maintenance(allowDelivery: Bool)
        case focus
    }

    public struct RequestReference: Sendable {
        public let handle: RequestHandle
        public let configurationKey: String
        public let expectedNonce: NativeDeliveryNonce?
        public let isToolbarAction: Bool

        public init(
            handle: RequestHandle,
            configurationKey: String,
            expectedNonce: NativeDeliveryNonce? = nil,
            isToolbarAction: Bool = false
        ) {
            self.handle = handle
            self.configurationKey = configurationKey
            self.expectedNonce = expectedNonce
            self.isToolbarAction = isToolbarAction
        }

        public init(_ snapshot: ExtensionBridge.Snapshot, isToolbarAction: Bool = false) {
            self.init(
                handle: snapshot.handle,
                configurationKey: snapshot.configurationKey,
                expectedNonce: snapshot.nativeDeliveryNonce,
                isToolbarAction: isToolbarAction
            )
        }

        public var route: NativeAgentRoute? {
            guard let expectedNonce else { return nil }
            if isToolbarAction {
                return .toolbarApproval(workflowVersion: ExtensionBridge.workflowVersion, handle: handle,
                    nativeDeliveryNonce: expectedNonce)
            }
            return .approval(
                workflowVersion: ExtensionBridge.workflowVersion,
                handle: handle,
                nativeDeliveryNonce: expectedNonce
            )
        }
    }

    private enum Ownership: Sendable {
        case owned(
            receipt: NativeDeliveryReceipt,
            runtime: NativeAgentLauncher.IdentifiedRuntime
        )
        case needsDelivery
        case finished(NativeApprovalReconciliationResult)

        var result: NativeApprovalReconciliationResult {
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

    public struct Dependencies: Sendable {
        public let launcher: NativeAgentLauncher
        public let load: @Sendable (RequestHandle) async -> ExtensionBridge.SnapshotResult
        public let responseStatus: @Sendable (
            RequestHandle, String
        ) async -> ExtensionBridge.ResponseStatusResult
        public let maintainProfile: @Sendable (UUID?) async -> Void
        public let clearReceipt: @Sendable (
            RequestHandle,
            NativeDeliveryReceipt
        ) async -> ExtensionBridge.StoreMutationResult
        public let uptime: @Sendable () -> UInt64
        public let sleepUntil: @Sendable (UInt64) async -> Void

        public func deadline(after interval: UInt64) -> UInt64 {
            let result = uptime().addingReportingOverflow(interval)
            return result.overflow ? UInt64.max : result.partialValue
        }

        public func wait(_ interval: UInt64) async {
            await sleepUntil(deadline(after: interval))
        }

        public init(
            launcher: NativeAgentLauncher,
            load: @escaping @Sendable (RequestHandle) async -> ExtensionBridge.SnapshotResult,
            responseStatus: @escaping @Sendable (RequestHandle, String) async -> ExtensionBridge.ResponseStatusResult,
            maintainProfile: @escaping @Sendable (UUID?) async -> Void,
            clearReceipt: @escaping @Sendable (RequestHandle, NativeDeliveryReceipt) async -> ExtensionBridge.StoreMutationResult,
            uptime: @escaping @Sendable () -> UInt64,
            sleepUntil: @escaping @Sendable (UInt64) async -> Void
        ) {
            self.launcher = launcher
            self.load = load
            self.responseStatus = responseStatus
            self.maintainProfile = maintainProfile
            self.clearReceipt = clearReceipt
            self.uptime = uptime
            self.sleepUntil = sleepUntil
        }
    }

    private struct DeliveryJob: Sendable {
        let route: NativeAgentRoute
        let deadline: UInt64
        let preparationFinished: ApprovalResolution<Void>
        let task: Task<NativeApprovalReconciliationResult, Never>
    }


    private let dependencies: Dependencies
    private let launchTimeoutNanoseconds: UInt64
    private var deliveries = [DeliveryJob]()
    private var preparationTail: ApprovalResolution<Void>?

    public init(
        dependencies: Dependencies,
        launchTimeoutNanoseconds: UInt64 = NativeApprovalTiming.launchTimeoutNanoseconds
    ) {
        self.dependencies = dependencies
        self.launchTimeoutNanoseconds = launchTimeoutNanoseconds
    }

    public func reconcile(
        _ reference: RequestReference,
        intent: ReconciliationIntent,
        waitDeadline: UInt64? = nil
    ) async -> NativeApprovalReconciliationResult {
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
        if reference.isToolbarAction, intent == .admission || intent == .focus {
            guard let route = reference.route else { return .missing }
            let delivery = getOrStartDelivery(route, reference: reference,
                deadline: dependencies.deadline(after: launchTimeoutNanoseconds))
            return await awaitDelivery(delivery, callerDeadline: deadline)
        }
        if intent == .admission {
            return await reconcileRequest(
                reference, intent: intent, deadline: deadline, waitDeadline: waitDeadline
            )
        }
        let result = await bounded(deadline: deadline, timeoutValue: NativeApprovalReconciliationResult.unavailable) {
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

    public func openWallet(waitDeadline: UInt64? = nil) async -> Bool {
        let deliveryDeadline = dependencies.deadline(after: launchTimeoutNanoseconds)
        let callerDeadline = min(deliveryDeadline, waitDeadline ?? UInt64.max)
        guard dependencies.uptime() < callerDeadline else { return false }
        let delivery = getOrStartDelivery(
            .showWallet(workflowVersion: ExtensionBridge.workflowVersion),
            reference: nil,
            deadline: deliveryDeadline
        )
        return await awaitDelivery(delivery, callerDeadline: callerDeadline) == .opened
    }

    private func reconcileRequest(
        _ reference: RequestReference,
        intent: ReconciliationIntent,
        deadline: UInt64,
        waitDeadline: UInt64? = nil
    ) async -> NativeApprovalReconciliationResult {
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
    ) async -> NativeApprovalReconciliationResult {
        let reference = RequestReference(snapshot)
        let inspectionDeadline: UInt64
        if snapshot.hasActiveExecution {
            inspectionDeadline = deadline
        } else {
            guard let route = reference.route else { return .missing }
            guard dependencies.uptime() < deadline else { return .unavailable }
            let delivery = getOrStartDelivery(
                route, reference: reference,
                deadline: dependencies.deadline(after: launchTimeoutNanoseconds)
            )
            let delivered = await awaitDelivery(delivery, callerDeadline: deadline)
            guard !Task.isCancelled else { return .unavailable }
            guard delivered == .unavailable else { return delivered }
            inspectionDeadline = min(
                dependencies.deadline(after: NativeApprovalTiming.receiptWaitTimeoutNanoseconds),
                waitDeadline ?? UInt64.max
            )
        }
        return await bounded(deadline: inspectionDeadline, timeoutValue: NativeApprovalReconciliationResult.unavailable)
        {
            await self.reconcileOwnership(reference, deadline: inspectionDeadline).result
        }
    }

    private func reconcileMaintenance(
        _ snapshot: ExtensionBridge.Snapshot,
        allowDelivery: Bool,
        deadline: UInt64
    ) async -> NativeApprovalReconciliationResult {
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
            guard let route = reference.route else { return .missing }
            let delivery = getOrStartDelivery(
                route, reference: reference,
                deadline: dependencies.deadline(after: launchTimeoutNanoseconds)
            )
            return await delivery.task.value
        case .owned:
            return .pending
        }
    }

    private func reconcileFocus(
        _ snapshot: ExtensionBridge.Snapshot,
        deadline: UInt64
    ) async -> NativeApprovalReconciliationResult {
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
                guard let route = reference.route else { return .missing }
                let delivery = getOrStartDelivery(
                    route, reference: reference,
                    deadline: dependencies.deadline(after: launchTimeoutNanoseconds)
                )
                let result = await delivery.task.value
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
                guard case .compatible(let currentRuntime) = await dependencies.launcher.observe(
                          owner: receipt.owner
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
            let status = await dependencies.launcher.observe(owner: receipt.owner)
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

    private func getOrStartDelivery(
        _ route: NativeAgentRoute,
        reference: RequestReference?,
        deadline: UInt64
    ) -> DeliveryJob {
        if let delivery = deliveries.first(where: {
            $0.route == route && dependencies.uptime() < $0.deadline
        }) {
            return delivery
        }
        let precedingPreparation = preparationTail
        let preparationFinished = ApprovalResolution<Void>()
        preparationTail = preparationFinished
        let task = Task { [weak self] in
            guard let self else {
                await preparationFinished.resolve(())
                return NativeApprovalReconciliationResult.unavailable
            }
            let result = await self.bounded(
                deadline: deadline, timeoutValue: NativeApprovalReconciliationResult.unavailable
            ) {
                await precedingPreparation?.value()
                return await self.deliver(
                    route, reference: reference,
                    preparationFinished: preparationFinished, deadline: deadline
                )
            }
            await self.retireDelivery(preparationFinished)
            return result
        }
        let delivery = DeliveryJob(
            route: route, deadline: deadline,
            preparationFinished: preparationFinished, task: task
        )
        deliveries.append(delivery)
        return delivery
    }

    private func awaitDelivery(_ delivery: DeliveryJob, callerDeadline: UInt64) async
        -> NativeApprovalReconciliationResult
    {
        if callerDeadline < delivery.deadline {
            return await bounded(deadline: callerDeadline, timeoutValue: NativeApprovalReconciliationResult.unavailable)
            {
                await delivery.task.value
            }
        }
        return await delivery.task.value
    }

    private func retireDelivery(_ completion: ApprovalResolution<Void>) async {
        deliveries.removeAll { $0.preparationFinished === completion }
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
    ) async -> NativeApprovalReconciliationResult {
        guard isPending(until: deadline) else { return .unavailable }
        var target: NativeAgentLauncher.HelperTarget?
        if let reference {
            switch await reconcileOwnership(reference, deadline: deadline) {
            case .owned(_, let runtime):
                guard reference.isToolbarAction else { return .pending }
                target = runtime.target
            case .finished(let result) where !reference.isToolbarAction || result == .unavailable: return result
            default: break
            }
        }
        if target == nil {
            guard isPending(until: deadline), let expected = await dependencies.launcher.expectedRuntime()
            else { return .unavailable }
            target = await dependencies.launcher.resolveTarget(expected: expected, deadline: deadline)
        }
        guard let target, isPending(until: deadline) else { return .unavailable }
        if case .running = target {
            await preparationFinished.resolve(())
        }
        let sent = await dependencies.launcher.send(route, to: target, deadline: deadline)
        if case .launch = target {
            await preparationFinished.resolve(())
        }
        guard sent, let expected = await dependencies.launcher.expectedRuntime(at: target.url),
              isPending(until: deadline) else { return .unavailable }
        while isPending(until: deadline) {
            if let reference, !reference.isToolbarAction {
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
