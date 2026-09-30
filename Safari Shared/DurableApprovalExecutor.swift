// ∅ 2026 lil org

import Foundation

@MainActor
final class DurableApprovalExecutor {

    struct ClaimContext {
        let handle: ExtensionBridge.Handle
        let executionDeadline: Date
    }

    enum ReviewDisposition: Equatable {
        case resume, refresh
    }

    typealias SourceSignerFactory = (
        ApprovedWalletSigningOperation,
        @escaping @MainActor (ExtensionBridge.Handle) async -> Bool
    ) -> any WalletSigning

    enum SigningAccess {
        case none
        case unlocked(WalletSigningSession)
        case source(SourceSignerFactory)

        var session: WalletSigningSession? {
            guard case .unlocked(let session) = self else { return nil }
            return session
        }
    }

    enum Preparation {
        case ready(consent: ReviewConsent, signing: SigningAccess)
        case release(ReviewDisposition)
    }

    enum Resolution {
        case approved(ResolvedDappApproval)
        case immediate(ImmediateResolution)
        case release(ReviewDisposition)
    }

    enum Result: Equatable {
        case persisted
        case ownershipLost
        case retryablePersistenceFailure
        case released(ReviewDisposition)
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

    func execute(
        claim: ExtensionBridge.ApprovalClaim,
        prepare: @MainActor (ClaimContext) async -> Preparation,
        resolve: @MainActor (ReviewConsent) -> Resolution
    ) async -> Result {
        guard claim.adoptForExecution() else { return .ownershipLost }
        defer { claim.releaseIfUnconsumed() }
        let consent: ReviewConsent
        let signing: SigningAccess
        switch await prepare(ClaimContext(handle: claim.handle, executionDeadline: claim.executionDeadline)) {
        case .ready(let preparedConsent, let preparedSigning):
            consent = preparedConsent
            signing = preparedSigning
        case .release(let disposition):
            return await release(claim: claim, disposition: disposition)
        }
        defer { signing.session?.invalidate() }
        guard signingAccessMatches(signing, claim: claim) else {
            return await release(claim: claim, disposition: .refresh)
        }
        let reservation: ExtensionBridge.ExecutionReservation
        switch await store.begin(claim: claim) {
        case .began(let value):
            reservation = value
        case .ownershipLost:
            return .ownershipLost
        case .retryablePersistenceFailure:
            return await release(claim: claim, disposition: .refresh)
        }
        defer { reservation.releaseLease() }
        if let expired = await rollbackIfExpired(reservation: reservation) { return expired }
        guard nativeDecisionIsFresh(reservation) else {
            return await complete(reservation: reservation, resolution: Self.staleResolution)
        }
        switch resolve(consent) {
        case .approved(let approval):
            guard nativeDecisionIsFresh(reservation) else {
                return await complete(reservation: reservation, resolution: Self.staleResolution)
            }
            return await executeApproved(reservation: reservation, approval: approval, signing: signing)
        case .immediate(let resolution):
            return await complete(reservation: reservation, resolution: resolution)
        case .release(let disposition):
            return await rollback(reservation: reservation, disposition: disposition)
        }
    }

    private func signingAccessMatches(_ signing: SigningAccess, claim: ExtensionBridge.ApprovalClaim) -> Bool {
        switch (claim.authority, signing) {
        case (.ordinary, .none), (.native, .source):
            return true
        case (.ordinary, .unlocked(let session)):
            return session.authorization.handle == claim.handle &&
                session.authorization.signingDeadline == claim.executionDeadline && session.requiresCommitLease
        default:
            return false
        }
    }

    private func executeApproved(
        reservation: ExtensionBridge.ExecutionReservation,
        approval: ResolvedDappApproval,
        signing: SigningAccess
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
        defer { permit.releaseLease() }
        let signingSession = signing.session
        let signer = makeSigner(signing, permit: permit)
        defer { if signingSession == nil { signer?.invalidate() } }
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
        if case .native(_, let context) = reservation.authority,
           Task.isCancelled || clock() < context.observedAt {
            if let permit { return await rollback(permit: permit) }
            return await rollback(reservation: reservation)
        }
        guard clock() >= reservation.executionDeadline else { return nil }
        if let permit { return await rollback(permit: permit) }
        return await rollback(reservation: reservation)
    }

    private func makeSigner(
        _ signing: SigningAccess,
        permit: ExtensionBridge.ApprovedExecutionPermit
    ) -> (any WalletSigning)? {
        guard permit.approval.signingAccount != nil else { return nil }
        switch signing {
        case .none:
            return nil
        case .unlocked(let session):
            guard let operation = ApprovedWalletSigningOperation(permit: permit),
                  session.bind(operation: operation, authorityIsCurrent: {
                      await self.store.authorityIsCurrent(handle: $0)
                  }) else { return nil }
            return session
        case .source(let factory):
            guard let operation = ApprovedWalletSigningOperation(permit: permit) else { return nil }
            return factory(operation) { await self.store.authorityIsCurrent(handle: $0) }
        }
    }

    private func complete(
        reservation: ExtensionBridge.ExecutionReservation,
        resolution: ImmediateResolution
    ) async -> Result {
        if let expired = await rollbackIfExpired(reservation: reservation) { return expired }
        switch await store.complete(reservation: reservation, resolution: resolution) {
        case .persisted: return .persisted
        case .ownershipLost: return .ownershipLost
        case .retryablePersistenceFailure: return .retryablePersistenceFailure
        }
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
        reservation: ExtensionBridge.ExecutionReservation,
        disposition: ReviewDisposition = .refresh
    ) async -> Result {
        switch await store.rollback(reservation: reservation) {
        case .persisted:
            return .released(disposition)
        case .ownershipLost:
            return .ownershipLost
        case .retryablePersistenceFailure:
            return .retryablePersistenceFailure
        }
    }

    private func rollback(permit: ExtensionBridge.ApprovedExecutionPermit) async -> Result {
        switch await store.rollback(permit: permit) {
        case .persisted: return .released(.refresh)
        case .ownershipLost: return .ownershipLost
        case .retryablePersistenceFailure: return .retryablePersistenceFailure
        }
    }

    private func release(claim: ExtensionBridge.ApprovalClaim, disposition: ReviewDisposition) async -> Result {
        switch await store.release(claim: claim) {
        case .persisted: return .released(disposition)
        case .ownershipLost: return .ownershipLost
        case .retryablePersistenceFailure: return .retryablePersistenceFailure
        }
    }

    private func nativeDecisionIsFresh(_ reservation: ExtensionBridge.ExecutionReservation) -> Bool {
        guard case .native(let approvedAt, _) = reservation.authority else { return true }
        let requiresFreshDecision: Bool
        switch reservation.request.body {
        case .ethereum(let body):
            requiresFreshDecision = body.method == .signTransaction
        case .solana(let body):
            requiresFreshDecision = body.method == .signTransaction || body.method == .signAllTransactions ||
                body.method == .signAndSendTransaction
        case .unknown:
            requiresFreshDecision = false
        }
        guard requiresFreshDecision else { return true }
        let age = clock().timeIntervalSince(approvedAt)
        return age >= 0 && age <= ExtensionBridge.maximumTransactionDecisionAge
    }

    private static var staleResolution: ImmediateResolution {
        .failure(ProviderResponseError(message: Strings.providerNotReady, code: 4100))
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
