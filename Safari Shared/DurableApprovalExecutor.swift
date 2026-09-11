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

    private final class BroadcastResolution {
        private var continuation: CheckedContinuation<ResponseToExtension, Never>?
        var sendTask: Task<Void, Never>?
        var timeoutTask: Task<Void, Never>?

        init(_ continuation: CheckedContinuation<ResponseToExtension, Never>) {
            self.continuation = continuation
        }

        func finish(
            with response: ResponseToExtension,
            cancelSend: Bool = false
        ) {
            guard let continuation else { return }
            self.continuation = nil
            if cancelSend {
                sendTask?.cancel()
            } else {
                timeoutTask?.cancel()
            }
            sendTask = nil
            timeoutTask = nil
            continuation.resume(returning: response)
        }
    }

    private final class OperationResolution {
        private var continuation: CheckedContinuation<
            DappExecutionResult?,
            Never
        >?
        var operationTask: Task<Void, Never>?
        var timeoutTask: Task<Void, Never>?

        init(
            _ continuation: CheckedContinuation<DappExecutionResult?, Never>
        ) {
            self.continuation = continuation
        }

        func finish(
            with result: DappExecutionResult?,
            cancelOperation: Bool = false
        ) {
            guard let continuation else { return }
            self.continuation = nil
            if cancelOperation {
                operationTask?.cancel()
            } else {
                timeoutTask?.cancel()
            }
            operationTask = nil
            timeoutTask = nil
            continuation.resume(returning: result)
        }
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
        markingApprovalCommitted: Bool = true,
        preExecutionValidation: (() -> ResponseToExtension?)? = nil,
        operation: @escaping () async -> DappExecutionResult
    ) async -> Result {
        await execute(
            claim: claim,
            plan: .ordinary,
            markingApprovalCommitted: markingApprovalCommitted,
            preExecutionValidation: preExecutionValidation,
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
            markingApprovalCommitted: true,
            preExecutionValidation: nil,
            operation: operation
        )
    }

    func executeNative(
        claim: ExtensionBridge.ApprovalClaim,
        context: ExtensionBridge.NativeExecutionContext,
        markingApprovalCommitted: Bool = true,
        preExecutionValidation: (() -> ResponseToExtension?)? = nil,
        operation: @escaping () async -> DappExecutionResult
    ) async -> Result {
        await execute(
            claim: claim,
            plan: .native(context: context),
            markingApprovalCommitted: markingApprovalCommitted,
            preExecutionValidation: preExecutionValidation,
            operation: operation
        )
    }

    private func execute(
        claim: ExtensionBridge.ApprovalClaim,
        plan: ExecutionPlan,
        markingApprovalCommitted: Bool,
        preExecutionValidation: (() -> ResponseToExtension?)?,
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
        if let response = preExecutionValidation?() {
            if let expired = await rollbackIfExpired(
                permit: permit,
                deadline: plan.deadline
            ) {
                return expired
            }
            return await complete(
                permit: permit,
                response: response,
                plan: plan
            )
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
        var acquiredExecutionLease: WalletExecutionLease?
        if let acquireWalletLease = plan.acquireWalletLease {
            guard let lease = await acquireWalletLease() else {
                return await rollback(permit: permit)
            }
            acquiredExecutionLease = lease
        }
        defer { acquiredExecutionLease?.release() }
        switch operationResult {
        case .response(let response):
            let response = markingApprovalCommitted
                ? response.markingApprovalCommitted()
                : response
            if let expired = await rollbackIfExpired(
                permit: permit,
                deadline: plan.deadline
            ) {
                return expired
            }
            return await complete(
                permit: permit,
                response: response,
                plan: plan
            )
        case .broadcast(let prepared):
            let recoveryResponse = markingApprovalCommitted
                ? prepared.recoveryResponse.markingApprovalCommitted()
                : prepared.recoveryResponse
            if let expired = await rollbackIfExpired(
                permit: permit,
                deadline: plan.deadline
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
                response: markingApprovalCommitted
                    ? delivered.markingApprovalCommitted()
                    : delivered,
                plan: .ordinary
            )
        }
    }

    private func rollbackIfExpired(
        permit: ExtensionBridge.ExecutionPermit,
        deadline: Date?
    ) async -> Result? {
        guard let deadline,
              clock() >= deadline else { return nil }
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
        return await withCheckedContinuation { continuation in
            let resolution = OperationResolution(continuation)
            resolution.operationTask = Task { @MainActor in
                resolution.finish(with: await operation())
            }
            resolution.timeoutTask = Task { @MainActor in
                do {
                    try await Task.sleep(nanoseconds: timeout)
                } catch {
                    return
                }
                resolution.finish(with: nil, cancelOperation: true)
            }
        }
    }

    private func boundedBroadcast(
        _ prepared: PreparedBroadcast
    ) async -> ResponseToExtension {
        return await withCheckedContinuation { continuation in
            let resolution = BroadcastResolution(continuation)
            resolution.sendTask = Task { @MainActor in
                resolution.finish(with: await prepared.send())
            }
            resolution.timeoutTask = Task { @MainActor in
                do {
                    try await Task.sleep(
                        nanoseconds: broadcastTimeoutNanoseconds
                    )
                } catch {
                    return
                }
                resolution.finish(
                    with: prepared.recoveryResponse,
                    cancelSend: true
                )
            }
        }
    }
}
