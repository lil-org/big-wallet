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
        case ready(consent: ReviewConsent, signing: WalletSigningSession?)
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

    typealias BroadcastSenderFactory = @MainActor @Sendable (
        ExtensionBridge.ApprovedExecutionPermit
    ) -> any ApprovedBroadcastSending

    @MainActor
    struct Environment {
        let requestProcessor: any DappRequestProcessing
        let makeBroadcastSender: BroadcastSenderFactory
        let broadcastTimeoutNanoseconds: UInt64
        let clock: @MainActor @Sendable () -> Date
        let waitForExecutionDeadline: (@MainActor @Sendable (Date) async -> Void)?
        let waitForBroadcastTimeout: @Sendable (UInt64) async -> Void

        static var live: Self { Self() }

        init(
            requestProcessor: (any DappRequestProcessing)? = nil,
            makeBroadcastSender: @escaping BroadcastSenderFactory = { _ in DappBroadcastSender() },
            broadcastTimeoutNanoseconds: UInt64 =
                DurableApprovalExecutor.defaultBroadcastTimeoutNanoseconds,
            clock: @escaping @MainActor @Sendable () -> Date = Date.init,
            waitForExecutionDeadline: (@MainActor @Sendable (Date) async -> Void)? = nil,
            waitForBroadcastTimeout: @escaping @Sendable (UInt64) async -> Void = {
                try? await Task.sleep(nanoseconds: $0)
            }
        ) {
            self.requestProcessor = requestProcessor ?? DappRequestProcessor()
            self.makeBroadcastSender = makeBroadcastSender
            self.broadcastTimeoutNanoseconds = broadcastTimeoutNanoseconds
            self.clock = clock
            self.waitForExecutionDeadline = waitForExecutionDeadline
            self.waitForBroadcastTimeout = waitForBroadcastTimeout
        }
    }

    private let store: PopupRequestStore
    private let requestProcessor: DappRequestProcessing
    private let makeBroadcastSender: BroadcastSenderFactory
    private let broadcastTimeoutNanoseconds: UInt64
    private let clock: @MainActor @Sendable () -> Date
    private let waitForExecutionDeadline: (@MainActor @Sendable (Date) async -> Void)?
    private let waitForBroadcastTimeout: @Sendable (UInt64) async -> Void

    init(
        store: PopupRequestStore,
        environment: Environment = .live
    ) {
        self.store = store
        requestProcessor = environment.requestProcessor
        makeBroadcastSender = environment.makeBroadcastSender
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
        let signing: WalletSigningSession?
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
        guard signingSessionMatches(signing, consent: consent, claim: claim),
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

    private func signingSessionMatches(
        _ session: WalletSigningSession?,
        consent: ReviewConsent,
        claim: ExtensionBridge.ApprovalClaim
    ) -> Bool {
        guard let account = consent.intent.action.signingAccount else { return session == nil }
        let expected = WalletSigningAuthorization(
            handle: claim.handle, approvedAccount: account,
            signingDeadline: claim.authority.signingDeadline(for: claim.request)
        )
        guard let session, session.authorization == expected else { return false }
        if case .ordinary = claim.authority {
            guard case .vault = session.commit else { return false }
        }
        return true
    }

    private func executeApproved(
        claim: ExtensionBridge.ApprovalClaim,
        approval: ResolvedDappApproval,
        signing: WalletSigningSession?,
        context: ClaimContext
    ) async -> Result {
#if BW_SAFARI_VM_TESTING
        let operation = SafariVMFixtures.shared.capture(handle: claim.handle)
        return await SafariVMFixtures.$operation.withValue(operation) {
            await performApproved(claim: claim, approval: approval, signing: signing, context: context)
        }
#else
        return await performApproved(claim: claim, approval: approval, signing: signing, context: context)
#endif
    }

    private func performApproved(
        claim: ExtensionBridge.ApprovalClaim,
        approval: ResolvedDappApproval,
        signing: WalletSigningSession?,
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
#if BW_SAFARI_VM_TESTING
        SafariVMFixtures.shared.event("authorization", requestID: permit.handle.id,
            metadata: ["executionID": permit.executionID.uuidString.lowercased(), "consentID": approval.fixtureConsentID,
                       "requestToken": permit.handle.requestToken,
                       "configurationKey": permit.request.configurationKey,
                       "profileIdentifier": permit.handle.profileIdentifier.map { $0.uuidString.lowercased() as Any } ?? NSNull()])
#endif
        guard signing?.attach(permit: permit) ?? (approval.signingAccount == nil) else {
            return await abandon(permit: permit)
        }
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
#if BW_SAFARI_VM_TESTING
            do { try await SafariVMFixtures.shared.checkpoint("beforeBroadcastCheckpoint", requestID: permit.handle.id) }
            catch { return await abandon(permit: permit) }
#endif
            switch await store.prepareBroadcast(permit: permit, broadcast: prepared) {
            case .prepared(let value):
                dispatch = value
            case .ownershipLost:
                return await abandon(permit: permit)
            case .retryablePersistenceFailure:
                return .retryablePersistenceFailure
            }
#if BW_SAFARI_VM_TESTING
            SafariVMFixtures.shared.event("broadcastCheckpoint", requestID: permit.handle.id,
                metadata: ["executionID": permit.executionID.uuidString.lowercased()])
            do { try await SafariVMFixtures.shared.checkpoint("afterBroadcastCheckpoint", requestID: permit.handle.id) }
            catch { return .retryablePersistenceFailure }
#endif
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
#if BW_SAFARI_VM_TESTING
        do { try await SafariVMFixtures.shared.checkpoint("beforeCompletion", requestID: permit.handle.id) }
        catch { return .retryablePersistenceFailure }
#endif
        switch await store.complete(permit: permit, result: result) {
        case .persisted:
#if BW_SAFARI_VM_TESTING
            SafariVMFixtures.shared.event("completion", requestID: permit.handle.id,
                metadata: ["executionID": permit.executionID.uuidString.lowercased()])
#endif
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
        let sender = makeBroadcastSender(dispatch.approvedPermit)
#if BW_SAFARI_VM_TESTING
        do { try await SafariVMFixtures.shared.checkpoint("beforeDispatch", requestID: dispatch.approvedPermit.handle.id) }
        catch { return recovery }
#endif
        return await bounded(
            timeoutNanoseconds: broadcastTimeoutNanoseconds,
            timeoutValue: recovery
        ) {
            await dispatch.broadcast.dispatch(using: dispatch, sender: sender) ?? recovery
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
