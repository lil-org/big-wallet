// ∅ 2026 lil org

import Foundation

@MainActor
final class DurableApprovalExecutor {

    struct ClaimContext {
        let handle: ExtensionBridge.Handle
        let executionDeadline: Date
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
        case abandon
    }

    enum Resolution {
        case approved(ResolvedDappApproval)
        case immediate(ImmediateResolution)
        case abandon
    }

    enum Result: Equatable {
        case persisted
        case ownershipLost
        case retryablePersistenceFailure
        case abandoned
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
        defer { claim.releaseUnapproved() }
        let consent: ReviewConsent
        let signing: SigningAccess
        switch await prepare(ClaimContext(handle: claim.handle, executionDeadline: claim.executionDeadline)) {
        case .ready(let preparedConsent, let preparedSigning):
            consent = preparedConsent
            signing = preparedSigning
        case .abandon:
            return await abandon(claim: claim)
        }
        defer { signing.session?.invalidate() }
        guard claim.matchesConsent(consent) else {
            return await abandon(claim: claim)
        }
        defer { consent.invalidateAuthorization() }
        guard signingAccessMatches(signing, claim: claim), !hasExpired(claim) else {
            return await abandon(claim: claim)
        }
        guard nativeDecisionIsFresh(claim) else {
            return await complete(claim: claim, resolution: Self.staleResolution)
        }
        switch resolve(consent) {
        case .approved(let approval):
            guard nativeDecisionIsFresh(claim) else {
                return await complete(claim: claim, resolution: Self.staleResolution)
            }
            return await executeApproved(claim: claim, approval: approval, signing: signing)
        case .immediate(let resolution):
            return await complete(claim: claim, resolution: resolution)
        case .abandon:
            return await abandon(claim: claim)
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
        claim: ExtensionBridge.ApprovalClaim,
        approval: ResolvedDappApproval,
        signing: SigningAccess
    ) async -> Result {
        guard !hasExpired(claim) else {
            return await abandon(claim: claim)
        }
        let permit: ExtensionBridge.ApprovedExecutionPermit
        switch await store.authorize(claim: claim, approval: approval) {
        case .authorized(let value):
            permit = value
        case .ownershipLost:
            return await abandon(claim: claim)
        case .retryablePersistenceFailure:
            return await abandon(claim: claim)
        }
        defer { permit.releaseLease() }
        let signingSession = signing.session
        let signer = makeSigner(signing, permit: permit)
        defer { if signingSession == nil { signer?.invalidate() } }
        guard approval.approval.signingAccount == nil || signer != nil else {
            return await abandon(permit: permit)
        }
        guard let operationResult = await boundedOperation(
            deadline: claim.executionDeadline,
            permit: permit,
            signer: signer
        ) else {
            return await abandon(permit: permit)
        }
        if case .rollback = operationResult {
            return await abandon(permit: permit)
        }
        var acquiredExecutionLease: WalletExecutionLease?
        if let signingSession {
            let lease = await Task { await signingSession.takeCommitLease() }.value
            guard let lease else {
                return await abandon(permit: permit)
            }
            acquiredExecutionLease = lease
        }
        defer { acquiredExecutionLease?.release() }
        switch operationResult {
        case .completed(let completion):
            guard !hasExpired(claim) else {
                return await abandon(permit: permit)
            }
            return await complete(
                permit: permit,
                result: completion
            )
        case .broadcast(let prepared):
            guard let recovery = prepared.recoveryCompletion(for: permit) else {
                return await abandon(permit: permit)
            }
            guard !hasExpired(claim) else {
                return await abandon(permit: permit)
            }
            let dispatch: ExtensionBridge.BroadcastDispatchPermit
            switch await store.prepareBroadcast(permit: permit, broadcast: prepared) {
            case .prepared(let value):
                dispatch = value
            case .ownershipLost:
                return await abandon(permit: permit)
            case .retryablePersistenceFailure:
                return .retryablePersistenceFailure
            }
            acquiredExecutionLease?.release()
            acquiredExecutionLease = nil
            let delivered = await boundedBroadcast(dispatch, recovery: recovery)
            return await complete(
                permit: permit,
                result: delivered
            )
        case .rollback:
            return await abandon(permit: permit)
        }
    }

    private func hasExpired(_ claim: ExtensionBridge.ApprovalClaim) -> Bool {
        if case .native(_, let context) = claim.authority,
           Task.isCancelled || clock() < context.observedAt {
            return true
        }
        return clock() >= claim.executionDeadline
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
        claim: ExtensionBridge.ApprovalClaim,
        resolution: ImmediateResolution
    ) async -> Result {
        guard !hasExpired(claim) else { return await abandon(claim: claim) }
        switch await store.complete(claim: claim, resolution: resolution) {
        case .persisted: return .persisted
        case .ownershipLost: return .ownershipLost
        case .retryablePersistenceFailure: return .retryablePersistenceFailure
        }
    }

    private func complete(
        permit: ExtensionBridge.ApprovedExecutionPermit,
        result: ApprovedCompletion
    ) async -> Result {
        switch await store.complete(permit: permit, result: result) {
        case .persisted:
            return .persisted
        case .ownershipLost:
            return .ownershipLost
        case .retryablePersistenceFailure:
            return .retryablePersistenceFailure
        }
    }

    private func abandon(permit: ExtensionBridge.ApprovedExecutionPermit) async -> Result {
        switch await store.abandon(permit: permit) {
        case .persisted: return .abandoned
        case .ownershipLost: return .ownershipLost
        case .retryablePersistenceFailure: return .retryablePersistenceFailure
        }
    }

    private func abandon(claim: ExtensionBridge.ApprovalClaim) async -> Result {
        switch await store.abandon(claim: claim) {
        case .persisted: return .abandoned
        case .ownershipLost: return .ownershipLost
        case .retryablePersistenceFailure: return .retryablePersistenceFailure
        }
    }

    private func nativeDecisionIsFresh(_ claim: ExtensionBridge.ApprovalClaim) -> Bool {
        guard case .native(let approvedAt, _) = claim.authority else { return true }
        let requiresFreshDecision: Bool
        switch claim.request.body {
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
