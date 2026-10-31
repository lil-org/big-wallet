import WalletDomain
import WalletStorageSupport
// ∅ 2026 lil org

import Foundation

@MainActor
final class DurableApprovalExecutor {

    @MainActor
    struct ClaimContext {
        enum DeadlineResult<Value: Sendable>: Sendable {
            case value(Value)
            case stopped
        }

        let handle: RequestHandle
        let executionDeadline: Date
        private let clock: @MainActor @Sendable () -> Date
        private let waitForDeadline: (@MainActor @Sendable (Date) async -> Void)?

        fileprivate init(
            handle: RequestHandle,
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
            onStop: @MainActor () -> Void = {},
            discardValue: @escaping @Sendable (Value) -> Void = { _ in },
            operation: @escaping @MainActor () async -> Value
        ) async -> DeadlineResult<Value> {
            guard !Task.isCancelled, clock() < executionDeadline else {
                onStop()
                return .stopped
            }
            let executionDeadline = self.executionDeadline
            let customWait = waitForDeadline
            let monotonicDeadline = ContinuousClock.now + .seconds(max(0, executionDeadline.timeIntervalSince(clock())))
            let result = await ApprovalResolution<DeadlineResult<Value>>().value(
                timeoutValue: .stopped,
                callerCancellation: .resolveTimeout,
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
                    guard !Task.isCancelled, clock() < executionDeadline else { return .stopped }
                    return .value(await operation())
                }
            )
            if case .value(let value) = result {
                guard !Task.isCancelled, clock() < executionDeadline else {
                    discardValue(value)
                    onStop()
                    return .stopped
                }
                return .value(value)
            }
            onStop()
            return .stopped
        }
    }

    enum Preparation<Stop: Sendable> {
        case ready(consent: ReviewConsent, signing: WalletSigningPreparation?)
        case rejected(ImmediateResolution)
        case abandon
        case stopped(Stop)
    }

    enum Resolution: Sendable {
        case approved(ResolvedDappApproval)
        case immediate(ImmediateResolution)
        case reviewRequired
        case abandon
    }

    enum Result: Equatable, Sendable {
        case persisted
        case ownershipLost
        case retryablePersistenceFailure
        case reviewRequired
        case abandoned
    }

    enum ExecutionOutcome<Stop: Sendable>: Sendable {
        case finished(Result)
        case preparationStopped(reason: Stop, release: ExtensionBridge.StoreMutationResult)
    }

    nonisolated static let defaultBroadcastTimeoutNanoseconds: UInt64 =
        120 * 1_000_000_000

    @MainActor
    struct Environment {
        let requestProcessor: any DappRequestProcessing
        let broadcaster: any SignedTransactionBroadcasting
        let hooks: AuthorityExecutionHooks
        let broadcastTimeoutNanoseconds: UInt64
        let clock: @MainActor @Sendable () -> Date
        let waitForExecutionDeadline: (@MainActor @Sendable (Date) async -> Void)?
        let waitForBroadcastTimeout: @Sendable (UInt64) async -> Void

        init(
            requestProcessor: any DappRequestProcessing,
            broadcaster: any SignedTransactionBroadcasting,
            hooks: AuthorityExecutionHooks = .none,
            broadcastTimeoutNanoseconds: UInt64 =
                DurableApprovalExecutor.defaultBroadcastTimeoutNanoseconds,
            clock: @escaping @MainActor @Sendable () -> Date = Date.init,
            waitForExecutionDeadline: (@MainActor @Sendable (Date) async -> Void)? = nil,
            waitForBroadcastTimeout: @escaping @Sendable (UInt64) async -> Void = {
                try? await Task.sleep(nanoseconds: $0)
            }
        ) {
            self.requestProcessor = requestProcessor
            self.broadcaster = broadcaster
            self.hooks = hooks
            self.broadcastTimeoutNanoseconds = broadcastTimeoutNanoseconds
            self.clock = clock
            self.waitForExecutionDeadline = waitForExecutionDeadline
            self.waitForBroadcastTimeout = waitForBroadcastTimeout
        }
    }

    private let store: PopupRequestStore
    private let requestProcessor: DappRequestProcessing
    private let broadcaster: any SignedTransactionBroadcasting
    private let hooks: AuthorityExecutionHooks
    private let broadcastTimeoutNanoseconds: UInt64
    private let clock: @MainActor @Sendable () -> Date
    private let waitForExecutionDeadline: (@MainActor @Sendable (Date) async -> Void)?
    private let waitForBroadcastTimeout: @Sendable (UInt64) async -> Void

    init(
        store: PopupRequestStore,
        environment: Environment
    ) {
        self.store = store
        requestProcessor = environment.requestProcessor
        broadcaster = environment.broadcaster
        hooks = environment.hooks
        broadcastTimeoutNanoseconds = environment.broadcastTimeoutNanoseconds
        clock = environment.clock
        waitForExecutionDeadline = environment.waitForExecutionDeadline
        waitForBroadcastTimeout = environment.waitForBroadcastTimeout
    }

    func execute<Stop: Sendable>(
        claim: ExtensionBridge.ApprovalClaim,
        prepare: @MainActor (ClaimContext) async -> Preparation<Stop>,
        resolve: @escaping @MainActor @Sendable (ReviewConsent) async -> Resolution
    ) async -> ExecutionOutcome<Stop> {
        await AuthorityExecutionHooks.$current.withValue(hooks) {
            await AuthorityExecutionContext.$current.withValue(.init(claim: claim)) {
                await executeScoped(claim: claim, prepare: prepare, resolve: resolve)
            }
        }
    }

    private func executeScoped<Stop: Sendable>(
        claim: ExtensionBridge.ApprovalClaim,
        prepare: @MainActor (ClaimContext) async -> Preparation<Stop>,
        resolve: @escaping @MainActor @Sendable (ReviewConsent) async -> Resolution
    ) async -> ExecutionOutcome<Stop> {
        guard claim.adoptForExecution() else { return .finished(.ownershipLost) }
        defer { claim.releaseUnapproved() }
        guard !Task.isCancelled else { return .finished(await abandon(claim: claim)) }
        let context = ClaimContext(
            handle: claim.handle,
            executionDeadline: claim.executionDeadline,
            clock: clock,
            waitForDeadline: waitForExecutionDeadline
        )
        let consent: ReviewConsent
        let signing: WalletSigningPreparation?
        switch await prepare(context) {
        case .ready(let preparedConsent, let preparedSigning):
            consent = preparedConsent
            signing = preparedSigning
        case .rejected(let resolution):
            return .finished(await complete(claim: claim, resolution: resolution))
        case .abandon:
            return .finished(await abandon(claim: claim))
        case .stopped(let reason):
            return .preparationStopped(reason: reason, release: await store.abandon(claim: claim))
        }
        defer { signing?.invalidate() }
        guard claim.matchesConsent(consent) else {
            return .finished(await abandon(claim: claim))
        }
        defer { consent.invalidateAuthorization() }
        guard await signingPreparationMatches(signing, consent: consent, claim: claim),
              claim.authority.allowsExecution(at: clock(), isCancelled: Task.isCancelled) else {
            return .finished(await abandon(claim: claim))
        }
        guard claim.authority.isDecisionFresh(for: claim.request, at: clock()) else {
            return .finished(await complete(claim: claim, resolution: Self.staleResolution))
        }
        guard case .value(let resolution) = await context.runBeforeDeadline(operation: {
            await resolve(consent)
        }) else {
            return .finished(await abandon(claim: claim))
        }
        switch resolution {
        case .approved(let approval):
            guard claim.authority.isDecisionFresh(for: claim.request, at: clock()) else {
                return .finished(await complete(claim: claim, resolution: Self.staleResolution))
            }
            return .finished(await executeApproved(claim: claim, approval: approval, signing: signing, context: context))
        case .immediate(let resolution):
            return .finished(await complete(claim: claim, resolution: resolution))
        case .reviewRequired:
            signing?.invalidate()
            switch await store.returnToReview(claim: claim, consent: consent) {
            case .persisted: return .finished(.reviewRequired)
            case .ownershipLost: return .finished(.ownershipLost)
            case .retryablePersistenceFailure: return .finished(.retryablePersistenceFailure)
            }
        case .abandon:
            return .finished(await abandon(claim: claim))
        }
    }

    private func signingPreparationMatches(
        _ preparation: WalletSigningPreparation?,
        consent: ReviewConsent,
        claim: ExtensionBridge.ApprovalClaim
    ) async -> Bool {
        guard let account = consent.intent.action.signingAccount else { return preparation == nil }
        let expected = WalletSigningScope(
            handle: claim.handle, approvedAccount: account,
            signingDeadline: claim.authority.signingDeadline(for: claim.request)
        )
        guard let preparation, preparation.scope == expected else { return false }
        if case .ordinary = claim.authority {
            guard preparation.requiresCommitLease else { return false }
        }
        return await awaitBackgroundOperation({ preparation.validateCurrent() }) == true
    }

    private func executeApproved(
        claim: ExtensionBridge.ApprovalClaim,
        approval: ResolvedDappApproval,
        signing preparation: WalletSigningPreparation?,
        context: ClaimContext
    ) async -> Result {
        return await performApproved(claim: claim, approval: approval, signing: preparation, context: context)
    }

    private func performApproved(
        claim: ExtensionBridge.ApprovalClaim,
        approval: ResolvedDappApproval,
        signing preparation: WalletSigningPreparation?,
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
        return await AuthorityExecutionContext.$current.withValue(.init(permit: permit)) {
            await executeAuthorized(permit: permit, claim: claim, preparation: preparation, context: context)
        }
    }

    private func executeAuthorized(
        permit: ExtensionBridge.ApprovedExecutionPermit,
        claim: ExtensionBridge.ApprovalClaim,
        preparation: WalletSigningPreparation?,
        context: ClaimContext
    ) async -> Result {
        AuthorityExecutionHooks.emit(.init(.authorization))
        let signing: WalletSigningSession?
        if let preparation {
            guard let session = await preparation.consume(permit: permit) else {
                return await abandon(permit: permit)
            }
            signing = session
        } else {
            guard permit.approval.signingAccount == nil else { return await abandon(permit: permit) }
            signing = nil
        }
        defer { signing?.invalidate() }
        guard case .value(let operationResult) = await context.runBeforeDeadline(operation: {
            await self.requestProcessor.execute(permit: permit, signer: signing)
        }) else {
            return await abandon(permit: permit)
        }
        if case .rollback = operationResult {
            return await abandon(permit: permit)
        }
        var acquiredExecutionLease: WalletExecutionLease?
        if let signing {
            let acquisition = await context.runBeforeDeadline(
                onStop: { signing.invalidate() },
                discardValue: { $0.releaseLease() }
            ) {
                await signing.takeCommit()
            }
            guard case .value(let outcome) = acquisition else {
                return await abandon(permit: permit)
            }
            switch outcome {
            case .readyWithoutLease:
                break
            case .lease(let lease):
                acquiredExecutionLease = lease
            case .unavailable:
                return await abandon(permit: permit)
            }
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
            do { try await AuthorityExecutionHooks.reach(.beforeBroadcastCheckpoint) }
            catch { return await abandon(permit: permit) }
            switch await store.prepareBroadcast(permit: permit, broadcast: prepared) {
            case .prepared(let value):
                dispatch = value
            case .ownershipLost:
                return await abandon(permit: permit)
            case .retryablePersistenceFailure:
                return .retryablePersistenceFailure
            }
            AuthorityExecutionHooks.emit(.init(.broadcastCheckpoint))
            do { try await AuthorityExecutionHooks.reach(.afterBroadcastCheckpoint) }
            catch { return .retryablePersistenceFailure }
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
        do { try await AuthorityExecutionHooks.reach(.beforeCompletion) }
        catch { return .retryablePersistenceFailure }
        switch await store.complete(permit: permit, result: result) {
        case .persisted:
            AuthorityExecutionHooks.emit(.init(.completion))
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
        .failure(ProviderResponseError(message: AuthorityStrings.providerNotReady, code: 4100))
    }

    private func boundedBroadcast(
        _ dispatch: ExtensionBridge.BroadcastDispatchPermit,
        recovery: ApprovedCompletion
    ) async -> ApprovedCompletion {
        do { try await AuthorityExecutionHooks.reach(.beforeDispatch) }
        catch { return recovery }
        return await bounded(
            timeoutNanoseconds: broadcastTimeoutNanoseconds,
            timeoutValue: recovery
        ) {
            await dispatch.broadcast.dispatch(using: dispatch, broadcaster: self.broadcaster) ?? recovery
        }
    }

    private func bounded<Value: Sendable>(
        timeoutNanoseconds: UInt64,
        timeoutValue: Value,
        operation: @escaping @MainActor () async -> Value
    ) async -> Value {
        let wait = waitForBroadcastTimeout
        return await ApprovalResolution<Value>().value(
            timeoutValue: timeoutValue,
            callerCancellation: .ignore,
            waitForTimeout: { await wait(timeoutNanoseconds) },
            operation: { await operation() }
        )
    }
}

extension DurableApprovalExecutor.ExecutionOutcome: Equatable where Stop: Equatable {}

