// ∅ 2026 lil org

import Foundation

@MainActor
final class DurableApprovalExecutor {

    enum Result: Equatable {
        case persisted
        case ownershipLost
        case retryablePersistenceFailure
        case released
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
            authority: .ordinary,
            operation: operation
        )
    }

    func executeSigning(
        claim: ExtensionBridge.ApprovalClaim,
        session: WalletSigningSession,
        operation: @escaping () async -> DappExecutionResult
    ) async -> Result {
        defer { session.invalidate() }
        guard session.authorization.handle == claim.handle,
              session.authorization.signingDeadline == claim.executionDeadline,
              session.requiresCommitLease else {
            claim.lease?.releaseIfUnconsumed()
            return .ownershipLost
        }
        return await execute(
            claim: claim,
            authority: .mobileSigning(deadline: claim.executionDeadline),
            acquireWalletLease: { await session.takeCommitLease() },
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
            authority: .native(context),
            operation: operation
        )
    }

    private func execute(
        claim: ExtensionBridge.ApprovalClaim,
        authority: ExtensionBridge.ExecutionAuthority,
        acquireWalletLease: (() async -> WalletExecutionLease?)? = nil,
        operation: @escaping () async -> DappExecutionResult
    ) async -> Result {
        let deadline: Date
        switch authority {
        case .ordinary: deadline = claim.executionDeadline
        case .mobileSigning(let signingDeadline): deadline = signingDeadline
        case .native(let context): deadline = context.executionDeadline
        }
        defer { claim.lease?.releaseIfUnconsumed() }
        let permit: ExtensionBridge.ExecutionPermit
        switch await store.begin(claim: claim) {
        case .began(let value):
            permit = value
        case .ownershipLost:
            return .ownershipLost
        case .retryablePersistenceFailure:
            switch await store.release(claim: claim) {
            case .persisted: return .released
            case .ownershipLost: return .ownershipLost
            case .retryablePersistenceFailure: return .retryablePersistenceFailure
            }
        }
        defer { permit.releaseLease() }
        if case .native = authority, Task.isCancelled {
            return await rollback(permit: permit)
        }
        guard let operationResult = await boundedOperation(
            deadline: deadline,
            operation: operation
        ) else {
            return await rollback(permit: permit)
        }
        if case .rollback = operationResult {
            return await rollback(permit: permit)
        }
        var acquiredExecutionLease: WalletExecutionLease?
        if let acquireWalletLease {
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
                authority: authority,
                deadline: deadline
            ) {
                return expired
            }
            return await complete(
                permit: permit,
                response: response,
                authority: authority
            )
        case .broadcast(let prepared):
            let recoveryResponse = prepared.recoveryResponse.markingApprovalCommitted()
            if let expired = await rollbackIfExpired(
                permit: permit,
                authority: authority,
                deadline: deadline
            ) {
                return expired
            }
            let checkpointResult = await prepareBroadcast(
                permit: permit,
                recoveryResponse: recoveryResponse,
                authority: authority
            )
            switch checkpointResult {
            case .persisted:
                break
            case .ownershipLost, .retryablePersistenceFailure, .released:
                return checkpointResult
            }
            acquiredExecutionLease?.release()
            acquiredExecutionLease = nil
            let delivered = await boundedBroadcast(prepared)
            return await complete(
                permit: permit,
                response: delivered.markingApprovalCommitted(),
                authority: .ordinary
            )
        case .rollback:
            return await rollback(permit: permit)
        }
    }

    private func rollbackIfExpired(
        permit: ExtensionBridge.ExecutionPermit,
        authority: ExtensionBridge.ExecutionAuthority,
        deadline: Date
    ) async -> Result? {
        if case .native = authority, Task.isCancelled {
            return await rollback(permit: permit)
        }
        guard clock() >= deadline else { return nil }
        return await rollback(permit: permit)
    }

    private func complete(
        permit: ExtensionBridge.ExecutionPermit,
        response: ResponseToExtension,
        authority: ExtensionBridge.ExecutionAuthority
    ) async -> Result {
        switch await store.complete(
            permit: permit,
            response: response,
            authority: authority
        ) {
        case .persisted:
            return .persisted
        case .ownershipLost:
            guard case .mobileSigning = authority else { return .ownershipLost }
            return await rollback(permit: permit)
        case .retryablePersistenceFailure:
            return .retryablePersistenceFailure
        }
    }

    private func prepareBroadcast(
        permit: ExtensionBridge.ExecutionPermit,
        recoveryResponse: ResponseToExtension,
        authority: ExtensionBridge.ExecutionAuthority
    ) async -> Result {
        switch await store.prepareBroadcast(
            permit: permit,
            recoveryResponse: recoveryResponse,
            authority: authority
        ) {
        case .persisted:
            return .persisted
        case .ownershipLost:
            guard case .mobileSigning = authority else { return .ownershipLost }
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
            return .released
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

    private func bounded<Value: Sendable>(
        timeoutNanoseconds: UInt64,
        timeoutValue: Value,
        operation: @escaping @MainActor () async -> Value
    ) async -> Value {
        await ApprovalResolution<Value>().value(
            timeoutValue: timeoutValue,
            callerCancellation: .ignore,
            waitForTimeout: { try? await Task.sleep(nanoseconds: timeoutNanoseconds) },
            operation: { await operation() }
        )
    }
}
