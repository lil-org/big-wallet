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
    private let requestProcessor: DappRequestProcessing
    private let broadcastSender: any ApprovedBroadcastSending
    private let broadcastTimeoutNanoseconds: UInt64
    private let clock: () -> Date

    init(
        store: PopupRequestStore,
        requestProcessor: DappRequestProcessing? = nil,
        broadcastSender: (any ApprovedBroadcastSending)? = nil,
        broadcastTimeoutNanoseconds: UInt64 =
            DurableApprovalExecutor.defaultBroadcastTimeoutNanoseconds,
        clock: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.requestProcessor = requestProcessor ?? DappRequestProcessor()
        self.broadcastSender = broadcastSender ?? DappBroadcastSender()
        self.broadcastTimeoutNanoseconds = broadcastTimeoutNanoseconds
        self.clock = clock
    }

    func executeOrdinary(
        reservation: ExtensionBridge.ExecutionReservation,
        approval: ResolvedDappApproval
    ) async -> Result {
        defer { reservation.releaseLease() }
        guard case .ordinary = reservation.authority else { return .ownershipLost }
        return await execute(
            reservation: reservation,
            approval: approval,
            makeSigner: { _ in nil }
        )
    }

    func executeSigning(
        reservation: ExtensionBridge.ExecutionReservation,
        approval: ResolvedDappApproval,
        session: WalletSigningSession
    ) async -> Result {
        defer { reservation.releaseLease() }
        guard case .ordinary = reservation.authority,
              session.authorization.handle == reservation.handle,
              session.authorization.signingDeadline == reservation.executionDeadline,
              session.requiresCommitLease else { return .ownershipLost }
        return await execute(
            reservation: reservation,
            approval: approval,
            signingSession: session,
            makeSigner: { permit in
                guard let operation = ApprovedWalletSigningOperation(permit: permit),
                      session.bind(
                        operation: operation,
                        authorityIsCurrent: { await self.store.authorityIsCurrent(handle: $0) }
                      ) else { return nil }
                return session
            }
        )
    }

    func executeNative(
        reservation: ExtensionBridge.ExecutionReservation,
        approval: ResolvedDappApproval,
        makeSigner: (ExtensionBridge.ApprovedExecutionPermit) -> (any WalletSigning)?
    ) async -> Result {
        defer { reservation.releaseLease() }
        guard case .native = reservation.authority else { return .ownershipLost }
        return await execute(
            reservation: reservation,
            approval: approval,
            makeSigner: makeSigner
        )
    }

    private func execute(
        reservation: ExtensionBridge.ExecutionReservation,
        approval: ResolvedDappApproval,
        signingSession: WalletSigningSession? = nil,
        makeSigner: (ExtensionBridge.ApprovedExecutionPermit) -> (any WalletSigning)?
    ) async -> Result {
        if let expired = await rollbackIfExpired(reservation: reservation) {
            return expired
        }
        let permit: ExtensionBridge.ApprovedExecutionPermit
        switch await store.authorize(reservation: reservation, approval: approval) {
        case .authorized(let value):
            permit = value
        case .ownershipLost:
            return .ownershipLost
        case .retryablePersistenceFailure:
            return await rollback(reservation: reservation)
        }
        defer { signingSession?.invalidate(); permit.releaseLease() }
        let signer = makeSigner(permit)
        defer { signer?.invalidate() }
        guard approval.approval.signingAccount == nil || signer != nil else {
            return await rollback(permit: permit)
        }
        guard let operationResult = await boundedOperation(
            deadline: reservation.executionDeadline,
            permit: permit,
            signer: signer
        ) else {
            return await rollback(permit: permit)
        }
        if case .rollback = operationResult {
            return await rollback(permit: permit)
        }
        var acquiredExecutionLease: WalletExecutionLease?
        if let signingSession {
            let lease = await Task { await signingSession.takeCommitLease() }.value
            guard let lease else {
                return await rollback(permit: permit)
            }
            acquiredExecutionLease = lease
        }
        defer { acquiredExecutionLease?.release() }
        switch operationResult {
        case .completed(let completion):
            if let expired = await rollbackIfExpired(reservation: reservation, permit: permit) {
                return expired
            }
            return await complete(
                permit: permit,
                result: completion,
                rollbackOnOwnershipLoss: signingSession != nil
            )
        case .broadcast(let prepared):
            guard let recovery = prepared.recoveryCompletion(for: permit) else {
                return await rollback(permit: permit)
            }
            if let expired = await rollbackIfExpired(reservation: reservation, permit: permit) {
                return expired
            }
            let dispatch: ExtensionBridge.BroadcastDispatchPermit
            switch await store.prepareBroadcast(permit: permit, broadcast: prepared) {
            case .prepared(let value):
                dispatch = value
            case .ownershipLost:
                if signingSession != nil {
                    return await rollback(permit: permit)
                }
                return .ownershipLost
            case .retryablePersistenceFailure:
                return .retryablePersistenceFailure
            }
            acquiredExecutionLease?.release()
            acquiredExecutionLease = nil
            let delivered = await boundedBroadcast(dispatch, recovery: recovery)
            return await complete(
                permit: permit,
                result: delivered,
                rollbackOnOwnershipLoss: false
            )
        case .rollback:
            return await rollback(permit: permit)
        }
    }

    private func rollbackIfExpired(
        reservation: ExtensionBridge.ExecutionReservation,
        permit: ExtensionBridge.ApprovedExecutionPermit? = nil
    ) async -> Result? {
        if case .native = reservation.authority, Task.isCancelled {
            if let permit { return await rollback(permit: permit) }
            return await rollback(reservation: reservation)
        }
        guard clock() >= reservation.executionDeadline else { return nil }
        if let permit { return await rollback(permit: permit) }
        return await rollback(reservation: reservation)
    }

    private func complete(
        permit: ExtensionBridge.ApprovedExecutionPermit,
        result: ApprovedCompletion,
        rollbackOnOwnershipLoss: Bool
    ) async -> Result {
        switch await store.complete(permit: permit, result: result) {
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
        reservation: ExtensionBridge.ExecutionReservation
    ) async -> Result {
        switch await store.rollback(reservation: reservation) {
        case .persisted:
            return .released
        case .ownershipLost:
            return .ownershipLost
        case .retryablePersistenceFailure:
            return .retryablePersistenceFailure
        }
    }

    private func rollback(permit: ExtensionBridge.ApprovedExecutionPermit) async -> Result {
        switch await store.rollback(permit: permit) {
        case .persisted: return .released
        case .ownershipLost: return .ownershipLost
        case .retryablePersistenceFailure: return .retryablePersistenceFailure
        }
    }

    private func boundedOperation(
        deadline: Date,
        permit: ExtensionBridge.ApprovedExecutionPermit,
        signer: (any WalletSigning)?
    ) async -> ApprovedExecutionResult? {
        let remaining = deadline.timeIntervalSince(clock())
        guard remaining > 0 else { return nil }
        let timeout = UInt64(min(
            remaining * 1_000_000_000,
            Double(UInt64.max)
        ))
        return await bounded(timeoutNanoseconds: timeout, timeoutValue: nil) {
            await self.requestProcessor.execute(permit: permit, signer: signer)
        }
    }

    private func boundedBroadcast(
        _ dispatch: ExtensionBridge.BroadcastDispatchPermit,
        recovery: ApprovedCompletion
    ) async -> ApprovedCompletion {
        await bounded(
            timeoutNanoseconds: broadcastTimeoutNanoseconds,
            timeoutValue: recovery
        ) {
            await dispatch.broadcast.dispatch(using: dispatch, sender: self.broadcastSender) ?? recovery
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
