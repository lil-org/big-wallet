// ∅ 2026 lil org

import Foundation

@MainActor
final class DurableApprovalExecutor {

    @MainActor
    struct ClaimContext {
        enum DeadlineResult<Value: Sendable>: Sendable {
            case value(Value)
            case expired
        }

        let handle: ExtensionBridge.Handle
        let executionDeadline: Date
        private let clock: @MainActor @Sendable () -> Date
        private let waitForDeadline: (@MainActor @Sendable (Date) async -> Void)?

        fileprivate init(
            handle: ExtensionBridge.Handle,
            executionDeadline: Date,
            clock: @escaping @MainActor @Sendable () -> Date,
            waitForDeadline: (@MainActor @Sendable (Date) async -> Void)?
        ) {
            self.handle = handle
            self.executionDeadline = executionDeadline
            self.clock = clock
            self.waitForDeadline = waitForDeadline
        }

        func runBeforeDeadline<Value: Sendable>(
            onTimeout: @MainActor () -> Void = {},
            discardValue: @escaping @Sendable (Value) -> Void = { _ in },
            operation: @escaping @MainActor () async -> Value
        ) async -> DeadlineResult<Value> {
            guard clock() < executionDeadline else {
                onTimeout()
                return .expired
            }
            let executionDeadline = self.executionDeadline
            let customWait = waitForDeadline
            let monotonicDeadline = ContinuousClock.now + .seconds(max(0, executionDeadline.timeIntervalSince(clock())))
            let result = await ApprovalResolution<DeadlineResult<Value>>().value(
                timeoutValue: .expired,
                callerCancellation: .ignore,
                waitForTimeout: {
                    if let customWait {
                        await customWait(executionDeadline)
                    } else {
                        try? await ContinuousClock().sleep(until: monotonicDeadline, tolerance: nil)
                    }
                },
                onDiscardedValue: { result in
                    if case .value(let value) = result { discardValue(value) }
                },
                operation: { @MainActor in
                    guard !Task.isCancelled, clock() < executionDeadline else { return .expired }
                    return .value(await operation())
                }
            )
            if case .value(let value) = result {
                guard clock() < executionDeadline else {
                    discardValue(value)
                    onTimeout()
                    return .expired
                }
                return .value(value)
            }
            onTimeout()
            return .expired
        }
    }

    typealias SourceSignerFactory = @MainActor @Sendable (
        WalletSigningAuthorization
    ) -> WalletSigningSession

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
        case rejected(ImmediateResolution)
        case abandon
    }

    enum Resolution: Sendable {
        case approved(ResolvedDappApproval)
        case immediate(ImmediateResolution)
        case reviewRequired
        case abandon
    }

    enum Result: Equatable {
        case persisted
        case ownershipLost
        case retryablePersistenceFailure
        case reviewRequired
        case abandoned
    }

    nonisolated static let defaultBroadcastTimeoutNanoseconds: UInt64 =
        120 * 1_000_000_000

    @MainActor
    struct Environment {
        let requestProcessor: any DappRequestProcessing
        let broadcastSender: any ApprovedBroadcastSending
        let broadcastTimeoutNanoseconds: UInt64
        let clock: @MainActor @Sendable () -> Date
        let waitForExecutionDeadline: (@MainActor @Sendable (Date) async -> Void)?

        static var live: Self { Self() }

        init(
            requestProcessor: (any DappRequestProcessing)? = nil,
            broadcastSender: (any ApprovedBroadcastSending)? = nil,
            broadcastTimeoutNanoseconds: UInt64 =
                DurableApprovalExecutor.defaultBroadcastTimeoutNanoseconds,
            clock: @escaping @MainActor @Sendable () -> Date = Date.init,
            waitForExecutionDeadline: (@MainActor @Sendable (Date) async -> Void)? = nil
        ) {
            self.requestProcessor = requestProcessor ?? DappRequestProcessor()
            self.broadcastSender = broadcastSender ?? DappBroadcastSender()
            self.broadcastTimeoutNanoseconds = broadcastTimeoutNanoseconds
            self.clock = clock
            self.waitForExecutionDeadline = waitForExecutionDeadline
        }
    }

    private let store: PopupRequestStore
    private let requestProcessor: DappRequestProcessing
    private let broadcastSender: any ApprovedBroadcastSending
    private let broadcastTimeoutNanoseconds: UInt64
    private let clock: @MainActor @Sendable () -> Date
    private let waitForExecutionDeadline: (@MainActor @Sendable (Date) async -> Void)?

    init(
        store: PopupRequestStore,
        environment: Environment = .live
    ) {
        self.store = store
        requestProcessor = environment.requestProcessor
        broadcastSender = environment.broadcastSender
        broadcastTimeoutNanoseconds = environment.broadcastTimeoutNanoseconds
        clock = environment.clock
        waitForExecutionDeadline = environment.waitForExecutionDeadline
    }

    func execute(
        claim: ExtensionBridge.ApprovalClaim,
        prepare: @MainActor (ClaimContext) async -> Preparation,
        resolve: @escaping @MainActor @Sendable (ReviewConsent) async -> Resolution
    ) async -> Result {
        guard claim.adoptForExecution() else { return .ownershipLost }
        defer { claim.releaseUnapproved() }
        let context = ClaimContext(
            handle: claim.handle,
            executionDeadline: claim.executionDeadline,
            clock: clock,
            waitForDeadline: waitForExecutionDeadline
        )
        let consent: ReviewConsent
        let signing: SigningAccess
        switch await prepare(context) {
        case .ready(let preparedConsent, let preparedSigning):
            consent = preparedConsent
            signing = preparedSigning
        case .rejected(let resolution):
            return await complete(claim: claim, resolution: resolution)
        case .abandon:
            return await abandon(claim: claim)
        }
        defer { signing.session?.invalidate() }
        guard claim.matchesConsent(consent) else {
            return await abandon(claim: claim)
        }
        defer { consent.invalidateAuthorization() }
        guard signingAccessMatches(signing, claim: claim),
              claim.authority.allowsExecution(at: clock(), isCancelled: Task.isCancelled) else {
            return await abandon(claim: claim)
        }
        guard claim.authority.isDecisionFresh(for: claim.request, at: clock()) else {
            return await complete(claim: claim, resolution: Self.staleResolution)
        }
        guard case .value(let resolution) = await context.runBeforeDeadline(operation: {
            await resolve(consent)
        }) else {
            return await abandon(claim: claim)
        }
        switch resolution {
        case .approved(let approval):
            guard claim.authority.isDecisionFresh(for: claim.request, at: clock()) else {
                return await complete(claim: claim, resolution: Self.staleResolution)
            }
            return await executeApproved(claim: claim, approval: approval, signing: signing, context: context)
        case .immediate(let resolution):
            return await complete(claim: claim, resolution: resolution)
        case .reviewRequired:
            signing.session?.invalidate()
            switch await store.returnToReview(claim: claim, consent: consent) {
            case .persisted: return .reviewRequired
            case .ownershipLost: return .ownershipLost
            case .retryablePersistenceFailure: return .retryablePersistenceFailure
            }
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
        signing: SigningAccess,
        context: ClaimContext
    ) async -> Result {
        guard claim.authority.allowsExecution(at: clock(), isCancelled: Task.isCancelled) else {
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
        guard case .value(let operationResult) = await context.runBeforeDeadline(operation: {
            await self.requestProcessor.execute(permit: permit, signer: signer)
        }) else {
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
            guard claim.authority.allowsExecution(at: clock(), isCancelled: Task.isCancelled) else {
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
            guard claim.authority.allowsExecution(at: clock(), isCancelled: Task.isCancelled) else {
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

    private func makeSigner(
        _ signing: SigningAccess,
        permit: ExtensionBridge.ApprovedExecutionPermit
    ) -> (any WalletSigning)? {
        guard let authorization = WalletSigningAuthorization(permit: permit) else { return nil }
        let session: WalletSigningSession
        switch signing {
        case .none:
            return nil
        case .unlocked(let unlocked):
            session = unlocked
        case .source(let factory):
            session = factory(authorization)
        }
        guard session.attach(permit: permit) else {
            session.invalidate()
            return nil
        }
        return session
    }

    private func complete(
        claim: ExtensionBridge.ApprovalClaim,
        resolution: ImmediateResolution
    ) async -> Result {
        guard claim.authority.allowsExecution(at: clock(), isCancelled: Task.isCancelled) else {
            return await abandon(claim: claim)
        }
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

    private static var staleResolution: ImmediateResolution {
        .failure(ProviderResponseError(message: Strings.providerNotReady, code: 4100))
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
