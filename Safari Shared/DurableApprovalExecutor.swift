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
        guard case .ordinary = claim.authority else {
            claim.lease.releaseIfUnconsumed()
            return .ownershipLost
        }
        return await execute(claim: claim, operation: operation)
    }

    func executeSigning(
        claim: ExtensionBridge.ApprovalClaim,
        session: WalletSigningSession,
        operation: @escaping () async -> DappExecutionResult
    ) async -> Result {
        defer { session.invalidate() }
        guard case .ordinary = claim.authority,
              session.authorization.handle == claim.handle,
              session.authorization.signingDeadline == claim.executionDeadline,
              session.requiresCommitLease else {
            claim.lease.releaseIfUnconsumed()
            return .ownershipLost
        }
        return await execute(
            claim: claim,
            acquireWalletLease: { await session.takeCommitLease() },
            operation: operation
        )
    }

    func executeNative(
        claim: ExtensionBridge.ApprovalClaim,
        operation: @escaping () async -> DappExecutionResult
    ) async -> Result {
        guard case .native = claim.authority else {
            claim.lease.releaseIfUnconsumed()
            return .ownershipLost
        }
        return await execute(claim: claim, operation: operation)
    }

    private func execute(
        claim: ExtensionBridge.ApprovalClaim,
        acquireWalletLease: (() async -> WalletExecutionLease?)? = nil,
        operation: @escaping () async -> DappExecutionResult
    ) async -> Result {
        let deadline = claim.executionDeadline
        defer { claim.lease.releaseIfUnconsumed() }
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
        if case .native = permit.authority, Task.isCancelled {
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
                permit: permit
            ) {
                return expired
            }
            return await complete(
                permit: permit,
                response: response,
                rollbackOnOwnershipLoss: acquireWalletLease != nil
            )
        case .broadcast(let prepared):
            let recoveryResponse = prepared.recoveryResponse.markingApprovalCommitted()
            if let expired = await rollbackIfExpired(
                permit: permit
            ) {
                return expired
            }
            let checkpointResult = await prepareBroadcast(
                permit: permit,
                recoveryResponse: recoveryResponse,
                rollbackOnOwnershipLoss: acquireWalletLease != nil
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
                rollbackOnOwnershipLoss: false
            )
        case .rollback:
            return await rollback(permit: permit)
        }
    }

    private func rollbackIfExpired(
        permit: ExtensionBridge.ExecutionPermit
    ) async -> Result? {
        if case .native = permit.authority, Task.isCancelled {
            return await rollback(permit: permit)
        }
        guard clock() >= permit.executionDeadline else { return nil }
        return await rollback(permit: permit)
    }

    private func complete(
        permit: ExtensionBridge.ExecutionPermit,
        response: ResponseToExtension,
        rollbackOnOwnershipLoss: Bool
    ) async -> Result {
        switch await store.complete(
            permit: permit,
            response: response
        ) {
        case .persisted:
            return .persisted
        case .ownershipLost:
            guard rollbackOnOwnershipLoss else { return .ownershipLost }
            return await rollback(permit: permit)
        case .retryablePersistenceFailure:
            return .retryablePersistenceFailure
        }
    }

    private func prepareBroadcast(
        permit: ExtensionBridge.ExecutionPermit,
        recoveryResponse: ResponseToExtension,
        rollbackOnOwnershipLoss: Bool
    ) async -> Result {
        switch await store.prepareBroadcast(
            permit: permit,
            recoveryResponse: recoveryResponse
        ) {
        case .persisted:
            return .persisted
        case .ownershipLost:
            guard rollbackOnOwnershipLoss else { return .ownershipLost }
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
