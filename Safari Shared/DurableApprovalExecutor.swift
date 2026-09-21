// ∅ 2026 lil org

import Foundation

@MainActor
final class DurableApprovalExecutor {

    enum Result: Equatable {
        case persisted
        case ownershipLost
        case beginRetryablePersistenceFailure
        case retryablePersistenceFailure
        case rolledBack
    }

    private struct ExecutionPlan {
        let authority: ExtensionBridge.ExecutionAuthority
        let deadline: Date?
        let acquireWalletLease: (() async -> WalletExecutionLease?)?

        var rollsBackRejectedCommit: Bool {
            if case .mobileSigning = authority { return true }
            return false
        }

        static let ordinary = ExecutionPlan(
            authority: .ordinary,
            deadline: nil,
            acquireWalletLease: nil
        )

        static func signing(
            deadline: Date,
            acquireWalletLease: @escaping () async -> WalletExecutionLease?
        ) -> ExecutionPlan {
            return ExecutionPlan(
                authority: .mobileSigning(deadline: deadline),
                deadline: deadline,
                acquireWalletLease: acquireWalletLease
            )
        }

        static func native(
            context: ExtensionBridge.NativeExecutionContext
        ) -> ExecutionPlan {
            ExecutionPlan(
                authority: .native(context),
                deadline: context.executionDeadline,
                acquireWalletLease: nil
            )
        }
    }

    nonisolated static let defaultBroadcastTimeoutNanoseconds: UInt64 =
        120 * 1_000_000_000

    private let store: PopupRequestStore
    private let broadcastTimeoutNanoseconds: UInt64
    private let clock: () -> Date

    init(
        store: PopupRequestStore,
        broadcastTimeoutNanoseconds: UInt64 =
            DurableApprovalExecutor.defaultBroadcastTimeoutNanoseconds,
        clock: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.broadcastTimeoutNanoseconds = broadcastTimeoutNanoseconds
        self.clock = clock
    }

    func executeOrdinary(
        claim: ExtensionBridge.ApprovalClaim,
        operation: @escaping () async -> DappExecutionResult
    ) async -> Result {
        await execute(
            claim: claim,
            plan: .ordinary,
            operation: operation
        )
    }

    func executeSigning(
        claim: ExtensionBridge.ApprovalClaim,
        deadline: Date,
        acquireWalletLease: @escaping () async -> WalletExecutionLease?,
        operation: @escaping () async -> DappExecutionResult
    ) async -> Result {
        await execute(
            claim: claim,
            plan: .signing(
                deadline: deadline,
                acquireWalletLease: acquireWalletLease
            ),
            operation: operation
        )
    }

    func executeNative(
        claim: ExtensionBridge.ApprovalClaim,
        context: ExtensionBridge.NativeExecutionContext,
        operation: @escaping () async -> DappExecutionResult
    ) async -> Result {
        await execute(
            claim: claim,
            plan: .native(context: context),
            operation: operation
        )
    }

    private func execute(
        claim: ExtensionBridge.ApprovalClaim,
        plan: ExecutionPlan,
        operation: @escaping () async -> DappExecutionResult
    ) async -> Result {
        let permit: ExtensionBridge.ExecutionPermit
        switch await store.begin(claim: claim) {
        case .began(let value):
            permit = value
        case .ownershipLost:
            return .ownershipLost
        case .retryablePersistenceFailure:
            return .beginRetryablePersistenceFailure
        }
        if case .native = plan.authority, Task.isCancelled {
            return await rollback(permit: permit)
        }
        let operationResult: DappExecutionResult
        if let deadline = plan.deadline {
            guard let result = await boundedOperation(
                deadline: deadline,
                operation: operation
            ) else {
                return await rollback(permit: permit)
            }
            operationResult = result
        } else {
            operationResult = await operation()
        }
        if case .rollback = operationResult {
            return await rollback(permit: permit)
        }
        var acquiredExecutionLease: WalletExecutionLease?
        if let acquireWalletLease = plan.acquireWalletLease {
            let lease = await Task { await acquireWalletLease() }.value
            guard let lease else {
                return await rollback(permit: permit)
            }
            acquiredExecutionLease = lease
        }
        defer { acquiredExecutionLease?.release() }
        switch operationResult {
        case .response(let response, let approvalCommitted):
            let response = approvalCommitted
                ? response.markingApprovalCommitted()
                : response
            if let expired = await rollbackIfExpired(
                permit: permit,
                plan: plan
            ) {
                return expired
            }
            return await complete(
                permit: permit,
                response: response,
                plan: plan
            )
        case .broadcast(let prepared):
            let recoveryResponse = prepared.recoveryResponse.markingApprovalCommitted()
            if let expired = await rollbackIfExpired(
                permit: permit,
                plan: plan
            ) {
                return expired
            }
            let checkpointResult = await prepareBroadcast(
                permit: permit,
                recoveryResponse: recoveryResponse,
                plan: plan
            )
            switch checkpointResult {
            case .persisted:
                break
            case .ownershipLost, .beginRetryablePersistenceFailure,
                 .retryablePersistenceFailure, .rolledBack:
                return checkpointResult
            }
            acquiredExecutionLease?.release()
            acquiredExecutionLease = nil
            let delivered = await boundedBroadcast(prepared)
            return await complete(
                permit: permit,
                response: delivered.markingApprovalCommitted(),
                plan: .ordinary
            )
        case .rollback:
            return await rollback(permit: permit)
        }
    }

    private func rollbackIfExpired(
        permit: ExtensionBridge.ExecutionPermit,
        plan: ExecutionPlan
    ) async -> Result? {
        if case .native = plan.authority, Task.isCancelled {
            return await rollback(permit: permit)
        }
        guard let deadline = plan.deadline, clock() >= deadline else { return nil }
        return await rollback(permit: permit)
    }

    static func approvalRevisionsMatch(
        action: DappRequestAction? = nil,
        request: SafariRequest,
        stored: ExtensionBridge.ProviderRevisions,
        current: ExtensionBridge.ProviderRevisions?
    ) -> Bool {
        if let action, case .addEthereumChain = action { return true }
        if case .ethereum(let body) = request.body,
           body.method == .addEthereumChain {
            return true
        }
        guard let current else { return false }
        switch request.provider {
        case .ethereum:
            return stored.ethereum == current.ethereum
        case .solana:
            return stored.solana == current.solana
        case .unknown, .multiple:
            return stored == current
        }
    }

    private func complete(
        permit: ExtensionBridge.ExecutionPermit,
        response: ResponseToExtension,
        plan: ExecutionPlan
    ) async -> Result {
        switch await store.complete(
            permit: permit,
            response: response,
            authority: plan.authority
        ) {
        case .persisted:
            return .persisted
        case .ownershipLost:
            guard plan.rollsBackRejectedCommit else { return .ownershipLost }
            return await rollback(permit: permit)
        case .retryablePersistenceFailure:
            return .retryablePersistenceFailure
        }
    }

    private func prepareBroadcast(
        permit: ExtensionBridge.ExecutionPermit,
        recoveryResponse: ResponseToExtension,
        plan: ExecutionPlan
    ) async -> Result {
        switch await store.prepareBroadcast(
            permit: permit,
            recoveryResponse: recoveryResponse,
            authority: plan.authority
        ) {
        case .persisted:
            return .persisted
        case .ownershipLost:
            guard plan.rollsBackRejectedCommit else { return .ownershipLost }
            return await rollback(permit: permit)
        case .retryablePersistenceFailure:
            return .retryablePersistenceFailure
        }
    }

    private func rollback(
        permit: ExtensionBridge.ExecutionPermit
    ) async -> Result {
        switch await store.rollback(permit: permit) {
        case .persisted:
            return .rolledBack
        case .ownershipLost:
            return .ownershipLost
        case .retryablePersistenceFailure:
            return .retryablePersistenceFailure
        }
    }

    private func boundedOperation(
        deadline: Date,
        operation: @escaping () async -> DappExecutionResult
    ) async -> DappExecutionResult? {
        let remaining = deadline.timeIntervalSince(clock())
        guard remaining > 0 else { return nil }
        let timeout = UInt64(min(
            remaining * 1_000_000_000,
            Double(UInt64.max)
        ))
        return await bounded(timeoutNanoseconds: timeout, timeoutValue: nil) {
            await operation()
        }
    }

    private func boundedBroadcast(
        _ prepared: PreparedBroadcast
    ) async -> ResponseToExtension {
        await bounded(
            timeoutNanoseconds: broadcastTimeoutNanoseconds,
            timeoutValue: prepared.recoveryResponse
        ) {
            await prepared.send()
        }
    }

    private func bounded<Value>(
        timeoutNanoseconds: UInt64,
        timeoutValue: Value,
        operation: @escaping @MainActor () async -> Value
    ) async -> Value {
        let resolution = ApprovalResolution<Value>()
        let operationTask = Task { @MainActor in
            let value = await operation()
            resolution.resolve(value)
        }
        let timeoutTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
            } catch {
                return
            }
            resolution.resolve(timeoutValue) {
                operationTask.cancel()
            }
        }
        let value = await resolution.value()
        timeoutTask.cancel()
        return value
    }
}
